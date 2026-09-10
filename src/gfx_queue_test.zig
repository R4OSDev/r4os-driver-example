// Explicit diagnostic mode only. No GPU registers or DMA engine are used.
// A real timer IRQ provides a delayed completion of retained test backing;
// copy jobs fail deliberately, so this fixture never claims copied pixels.
const r4os = @import("r4os");
const a = r4os.abi;
pub const adapter: u32 = 0xFFFF0006;
var api: *const a.DriverApi = undefined;
var queues: r4os.driver_queue.Context = undefined;
var binding: a.GfxBackendBinding = .{};
var held: a.GfxDriverJob = .{};
var due: u64 = 0;
var armed: u32 = 0;
var proof: u32 = 0;
var ordinal: u32 = 0;
var irq_registered = false;

pub fn init(ctx: *const r4os.r4dev.DriverContext) bool {
    api = ctx.api;
    queues = ctx.graphicsQueue() orelse return false;
    const request = a.GfxBackendRegistration{ .adapter_id = adapter, .milestone = a.gfx_queue_milestone_device_execution, .notify_callback = @intFromPtr(&notify) };
    if (queues.register(&request, &binding) != a.gfx_queue_ok) return false;
    if (ctx.irqRegister(0, onIrq, 0, a.irq_flag_shared) != 0) return false;
    irq_registered = true;
    ctx.logInfo("EXAMPLE.R4D gfx-queue fixture: registered timer-IRQ delay=3s hardware-DMA=none");
    return true;
}
fn notify(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (@atomicLoad(u32, &armed, .acquire) != 0) return 0;
    const report = @atomicRmw(u32, &proof, .Xchg, 0, .acq_rel);
    if (report != 0) ctx.logInfo(if (report == 1) "EXAMPLE.R4D gfx-queue IRQ: OK late=exact duplicate=rejected unproven=retained" else "EXAMPLE.R4D gfx-queue IRQ: FAILED");
    var job: a.GfxDriverJob = .{};
    const rc = queues.take(&binding, &job);
    if (rc == a.gfx_queue_error_busy or rc == a.gfx_queue_error_device_lost) return 0;
    if (rc != a.gfx_queue_ok) return -1;
    ordinal += 1;
    if (job.operation == a.gfx_queue_operation_copy) {
        var first: a.GfxDmaSegment = .{};
        var last: a.GfxDmaSegment = .{};
        if (job.operation != a.gfx_queue_operation_copy or job.byte_length == 0 or
            queues.segment(&job.fence, 0, 0, ~@as(u64, 0), &first) != a.gfx_queue_ok or
            queues.segment(&job.fence, 1, job.byte_length - 1, ~@as(u64, 0), &last) != a.gfx_queue_ok or
            first.dma_address == 0 or last.next_offset != job.byte_length)
        {
            _ = queues.complete(&job.fence, a.gfx_queue_result_failed, 1);
            ctx.logError("EXAMPLE.R4D gfx-queue segments: FAILED");
            return -1;
        }
        held = job;
        due = ctx.tickCount() + @as(u64, ctx.timerFrequency()) * 3;
        @atomicStore(u32, &armed, 1, .release);
        return 0;
    }
    if (ordinal == 2) {
        var next: a.GfxBackendBinding = .{};
        const refused = queues.reset(&binding, 0, &next) == a.gfx_queue_error_busy;
        const retained = queues.complete(&job.fence, a.gfx_queue_result_complete, 0) == a.gfx_queue_error_busy;
        const reset = queues.reset(&binding, 1, &next) == a.gfx_queue_ok and next.device_generation == binding.device_generation and next.reset_generation == binding.reset_generation + 1;
        if (reset) binding = next;
        const late = queues.complete(&job.fence, a.gfx_queue_result_complete, 1);
        const passed = refused and retained and reset and (late == a.gfx_queue_error_already_completed or late == a.gfx_queue_error_stale);
        ctx.logInfo(if (passed) "EXAMPLE.R4D gfx-queue reset: OK lost=published old-generation=retained quiescence=required" else "EXAMPLE.R4D gfx-queue reset: FAILED");
        return if (passed) 0 else -1;
    }
    return if (queues.complete(&job.fence, if (job.operation == a.gfx_queue_operation_barrier) a.gfx_queue_result_complete else a.gfx_queue_result_failed, 1) == a.gfx_queue_ok) 0 else -1;
}
fn onIrq(_: u8, _: usize) callconv(.c) u32 {
    if (@atomicLoad(u32, &armed, .acquire) == 0 or api.tick_count() < due) return 0;
    var forged = held.fence;
    forged.reset_generation += 1;
    const stale = queues.complete(&forged, a.gfx_queue_result_failed, 1) == a.gfx_queue_error_stale;
    const retained = queues.complete(&held.fence, a.gfx_queue_result_failed, 0) == a.gfx_queue_error_busy;
    const accepted = queues.complete(&held.fence, a.gfx_queue_result_failed, 1) == a.gfx_queue_ok;
    const duplicate = queues.complete(&held.fence, a.gfx_queue_result_failed, 1) == a.gfx_queue_error_already_completed;
    @atomicStore(u32, &proof, if (stale and retained and accepted and duplicate) 1 else 2, .release);
    @atomicStore(u32, &armed, 0, .release);
    return 0; // Observes the shared timer; never owns it.
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) i32 {
    if (binding.device_generation == 0) return 0;
    @atomicStore(u32, &armed, 0, .release);
    if (irq_registered) {
        if (ctx.irqUnregister(0, onIrq, 0) != 0) return -1;
        irq_registered = false;
    }
    const deadline = ctx.tickCount() + ctx.timerFrequency();
    while (true) {
        const rc = queues.unregister(&binding, 1); // Fixture has no DMA engine.
        if (rc == a.gfx_queue_ok) {
            binding = .{};
            return 0;
        }
        if (rc != a.gfx_queue_error_busy or ctx.tickCount() >= deadline) return -1;
        ctx.waitTicks(1);
    }
}
