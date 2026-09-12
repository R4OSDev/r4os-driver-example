// Explicit diagnostic mode only. No GPU registers or DMA engine are used.
// A real timer IRQ provides a delayed completion of retained test backing;
// copy jobs fail deliberately, so this fixture never claims copied pixels.
const r4os = @import("r4os");
const std = @import("std");
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
var mapping_work: u32 = 0;
var cached_memory: r4os.driver_memory.Context = undefined;
var closing: u32 = 0;
var require_producer_exit = false;
const Mapping = struct { reference: a.GfxBufferReference = .{}, dma: a.GfxDeviceLease = .{}, gpu: a.GfxDeviceLease = .{} };
var mappings: [2]Mapping = .{Mapping{}} ** 2;

pub fn init(ctx: *const r4os.r4dev.DriverContext) bool {
    api = ctx.api;
    queues = ctx.graphicsQueue() orelse return false;
    cached_memory = ctx.memory() orelse return false;
    // A genuinely old caller allocates only 56 bytes. The next eight bytes
    // are a canary, not spare capacity for the optional retain callback.
    const Prefix = extern struct { version: u32 = 1, size: u32 = 56, slots: [6]u64 = .{0} ** 6, canary: u64 = 0x7193A5C7E9BDF024 };
    var prefix: Prefix = .{};
    if ((ctx.api.gfx_queue_query orelse return false)(@ptrCast(&prefix)) != a.gfx_queue_ok or
        prefix.size != 56 or prefix.canary != 0x7193A5C7E9BDF024 or prefix.slots[5] == 0) return false;
    ctx.logInfo("EXAMPLE.R4D gfx-queue prefix: OK bytes=56 canary=preserved");
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
    if (mapping_work != 0) {
        var result: i32 = -1;
        if (ctx.completionWait(mapping_work, ctx.timerFrequency(), &result) != 0 or
            ctx.completionRelease(mapping_work) != 0 or result != 0)
        {
            ctx.logError("EXAMPLE.R4D gfx-queue mapping work: FAILED");
            return -1;
        }
        mapping_work = 0;
    }
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
        require_producer_exit = ordinal > 1;
        due = ctx.tickCount() + @as(u64, ctx.timerFrequency()) * 3;
        @atomicStore(u32, &armed, 1, .release);
        if (ctx.workSubmit(mappingWork, 0, 0, &mapping_work) != 0) {
            @atomicStore(u32, &armed, 0, .release);
            _ = queues.complete(&job.fence, a.gfx_queue_result_failed, 1);
            return -1;
        }
        return 0;
    }
    if (ordinal == 2) {
        var next: a.GfxBackendBinding = .{};
        var absent: a.GfxBufferReference = .{};
        const no_resource = queues.retainResource(&job.fence, 0, &absent) == a.gfx_queue_error_invalid;
        const refused = queues.reset(&binding, 0, &next) == a.gfx_queue_error_busy;
        const closed = queues.retainResource(&job.fence, 0, &absent) == a.gfx_queue_error_device_lost;
        const retained = queues.complete(&job.fence, a.gfx_queue_result_complete, 0) == a.gfx_queue_error_busy;
        const reset = queues.reset(&binding, 1, &next) == a.gfx_queue_ok and next.device_generation == binding.device_generation and next.reset_generation == binding.reset_generation + 1;
        if (reset) binding = next;
        const late = queues.complete(&job.fence, a.gfx_queue_result_complete, 1);
        const old_mapping = queues.retainResource(&job.fence, 0, &absent) == a.gfx_queue_error_stale;
        const passed = no_resource and closed and old_mapping and refused and retained and reset and (late == a.gfx_queue_error_already_completed or late == a.gfx_queue_error_stale);
        ctx.logInfo(if (passed) "EXAMPLE.R4D gfx-queue reset: OK lost=published old-generation=retained quiescence=required" else "EXAMPLE.R4D gfx-queue reset: FAILED");
        return if (passed) 0 else -1;
    }
    return if (queues.complete(&job.fence, if (job.operation == a.gfx_queue_operation_barrier) a.gfx_queue_result_complete else a.gfx_queue_result_failed, 1) == a.gfx_queue_ok) 0 else -1;
}
fn cleanupMappings(memory: *const r4os.driver_memory.Context) bool {
    for (&mappings) |*mapping| {
        // Diagnostic addresses were never sent to an engine; fixture stop
        // proves quiescence. Production drivers need their real RM/TLB ACKs.
        if (mapping.gpu.lease.id != 0) {
            if (memory.deviceRelease(&mapping.gpu, 1) != a.gfx_buffer_result_ok) return false;
            mapping.gpu = .{};
        }
        if (mapping.dma.lease.id != 0) {
            if (memory.deviceRelease(&mapping.dma, 1) != a.gfx_buffer_result_ok) return false;
            mapping.dma = .{};
        }
        if (mapping.reference.reference.id != 0) {
            if (memory.bufferRelease(&mapping.reference.reference) != a.gfx_buffer_result_ok) return false;
            mapping.reference = .{};
        }
    }
    return memory.collect() == a.gfx_buffer_result_ok;
}
fn retainMappings(ctx: *const r4os.r4dev.DriverContext, memory: *const r4os.driver_memory.Context) bool {
    const current_queue = ctx.graphicsQueue() orelse return false;
    var rejected: a.GfxBufferReference = .{};
    var stale = held.fence;
    stale.reset_generation += 1;
    if (current_queue.retainResource(&stale, 0, &rejected) != a.gfx_queue_error_stale or
        current_queue.retainResource(&held.fence, 2, &rejected) != a.gfx_queue_error_invalid) return false;
    for (&mappings, 0..) |*mapping, index| {
        if (current_queue.retainResource(&held.fence, @intCast(index), &mapping.reference) != a.gfx_queue_ok or
            mapping.reference.flags != a.gfx_buffer_reference_mapping_only or
            !std.meta.eql(mapping.reference.buffer, if (index == 0) held.source_buffer else held.target_buffer)) return false;
        var descriptor: a.GfxBufferDescriptor = .{};
        if (memory.bufferDescribe(&mapping.reference.reference, &descriptor) != a.gfx_buffer_result_ok or descriptor.byte_length != 4091) return false;
        var denied: a.GfxBufferMap = .{};
        if (memory.bufferMap(&mapping.reference.reference, 0, 0, 4096, &denied) != a.gfx_buffer_error_unsupported or
            memory.bufferMap(&mapping.reference.reference, 1, 0, 4096, &denied) != a.gfx_buffer_error_unsupported or
            memory.bufferImport(&mapping.reference.reference, &rejected) != a.gfx_buffer_error_unsupported) return false;
        const request: a.GfxDeviceRequest = .{ .adapter_id = adapter, .device_generation = binding.device_generation, .access = 4, .byte_length = 4096 };
        if (memory.deviceAcquire(&mapping.reference.reference, &request, &mapping.dma) != a.gfx_buffer_result_ok) return false;
        var whole: a.GfxDmaSegment = .{};
        var extent: a.GfxDmaSegment = .{};
        if (memory.deviceSegment(&mapping.dma, 0, &whole) != a.gfx_buffer_result_ok or
            current_queue.segment(&held.fence, @intCast(index), 0, ~@as(u64, 0), &extent) != a.gfx_queue_ok or
            whole.byte_length != 4096 or extent.dma_address != whole.dma_address + (if (index == 0) held.source_offset else held.target_offset)) return false;
        var gpu = request;
        gpu.access = 3;
        gpu.address_space = 1;
        gpu.gpu_virtual_address = 0x100000000 + index * 4096;
        if (memory.deviceAcquire(&mapping.reference.reference, &gpu, &mapping.gpu) != a.gfx_buffer_result_ok or
            memory.deviceRelease(&mapping.gpu, 0) != a.gfx_buffer_error_busy or
            memory.deviceRelease(&mapping.dma, 0) != a.gfx_buffer_error_busy) return false;
    }
    ctx.logInfo(if (require_producer_exit)
        "EXAMPLE.R4D gfx-queue retained: OK producer=closed work=ordinary same-BO=2 extents=exact maps=4 logical=4091 mapped=4096"
    else
        "EXAMPLE.R4D gfx-queue retained: OK work=ordinary same-BO=2 extents=exact maps=4 logical=4091 mapped=4096");
    return true;
}
fn mappingWork(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    const memory = ctx.memory() orelse return -1;
    // The existing DISPLAYD fixture cancels/releases the first producer and
    // kills/reaps the second. Wait for its retained backing before handing it
    // off, so the probe cannot accidentally rely on still-live app handles.
    var ready = true;
    if (require_producer_exit) {
        const deadline = ctx.tickCount() + 2 * @as(u64, ctx.timerFrequency());
        while (true) {
            var stats: a.GfxBufferStats = .{};
            if (memory.bufferStats(&stats) != a.gfx_buffer_result_ok) {
                ready = false;
                break;
            }
            if (stats.retained_bytes >= 8192) break;
            if (ctx.tickCount() >= deadline or @atomicLoad(u32, &closing, .acquire) != 0) {
                ready = false;
                break;
            }
            ctx.waitTicks(1);
        }
    } else ctx.waitTicks(ctx.timerFrequency());
    if (@atomicLoad(u32, &closing, .acquire) != 0) return if (cleanupMappings(&memory)) 0 else -1;
    const passed = ready and retainMappings(&ctx, &memory);
    @atomicStore(u32, &armed, 2, .release);
    const deadline = due + ctx.timerFrequency();
    while (@atomicLoad(u32, &armed, .acquire) != 0 and @atomicLoad(u32, &closing, .acquire) == 0 and ctx.tickCount() < deadline) ctx.waitTicks(1);
    const stopped = @atomicLoad(u32, &armed, .acquire) == 0;
    const released = cleanupMappings(&memory);
    if (!passed or !stopped or !released) return -1;
    ctx.logInfo("EXAMPLE.R4D gfx-queue mapping release: OK IRQ=observed DMA-GPU-reference=balanced");
    return 0;
}
fn onIrq(_: u8, _: usize) callconv(.c) u32 {
    if (@atomicLoad(u32, &armed, .acquire) != 2 or api.tick_count() < due) return 0;
    var denied: a.GfxBufferReference = .{};
    const denied_irq = queues.retainResource(&held.fence, 0, &denied) == a.gfx_queue_error_invalid;
    var forged = held.fence;
    forged.reset_generation += 1;
    const stale = queues.complete(&forged, a.gfx_queue_result_failed, 1) == a.gfx_queue_error_stale;
    const retained = queues.complete(&held.fence, a.gfx_queue_result_failed, 0) == a.gfx_queue_error_busy;
    const accepted = queues.complete(&held.fence, a.gfx_queue_result_failed, 1) == a.gfx_queue_ok;
    const duplicate = queues.complete(&held.fence, a.gfx_queue_result_failed, 1) == a.gfx_queue_error_already_completed;
    @atomicStore(u32, &proof, if (denied_irq and stale and retained and accepted and duplicate) 1 else 2, .release);
    @atomicStore(u32, &armed, 0, .release);
    return 0; // Observes the shared timer; never owns it.
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) i32 {
    if (binding.device_generation == 0) return 0;
    @atomicStore(u32, &closing, 1, .release);
    @atomicStore(u32, &armed, 0, .release);
    if (irq_registered) {
        if (ctx.irqUnregister(0, onIrq, 0) != 0) return -1;
        irq_registered = false;
    }
    if (mapping_work != 0) {
        var result: i32 = -1;
        if (ctx.completionWait(mapping_work, 4 * ctx.timerFrequency(), &result) != 0 or ctx.completionRelease(mapping_work) != 0) return -1;
        mapping_work = 0;
    }
    if (!cleanupMappings(&cached_memory)) return -1;
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
