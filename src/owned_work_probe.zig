// Optional extension of the existing gfx-memory acceptance, using real R4D
// threads and Work callbacks. No device MMIO, scanout or DMA is performed.
const r4os = @import("r4os");
const a = r4os.abi;
var api: *const a.DriverApi = undefined;
var threads: r4os.r4dev.DriverThreadContext = undefined;
var thread: u64 = 0;
var completion: u32 = 0;
var busy_observed: u32 = 0;
var init_done: u32 = 0;
var owned_hits: u32 = 0;
var result: i32 = -1;
var joined = false;

pub fn start(ctx: *const r4os.r4dev.DriverContext) bool {
    if (!ctx.supportsDriverApi(a.driver_api_owned_work_version, @offsetOf(a.DriverApi, "driver_work_submit_owned") + 8)) return false;
    api = ctx.api; threads = ctx.threads() orelse return false;
    busy_observed = 0; init_done = 0; owned_hits = 0; joined = false;
    if (threads.start(worker, 0, a.driver_thread_flag_parallel, &thread) != 0 or thread == 0) return false;
    // Init owns the lifecycle guard. The shared Work lane must return BUSY
    // without parking, invoking the callback or borrowing this Init's guard.
    const deadline = ctx.tickCount() + 3 * ctx.timerFrequency();
    while (@atomicLoad(u32, &busy_observed, .acquire) == 0 and ctx.tickCount() < deadline) ctx.waitTicks(1);
    const passed = @atomicLoad(u32, &busy_observed, .acquire) == 1 and @atomicLoad(u32, &owned_hits, .acquire) == 0;
    @atomicStore(u32, &init_done, 1, .release);
    return passed;
}
fn finish(ctx: *const r4os.r4dev.DriverContext) ?i32 {
    for (0..3000) |_| {
        var status: a.DriverCompletionStatus = .{};
        if (ctx.completionStatus(completion, &status) != 0) return null;
        if (status.state == a.driver_work_state_completed or status.state == a.driver_work_state_cancelled) {
            if (ctx.completionRelease(completion) != 0) return null;
            completion = 0;
            return if (status.state == a.driver_work_state_completed) status.result else null;
        }
        if (threads.sleepTicks(1) != 0) return null;
    }
    return null;
}
fn worker(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    defer if (result != 0) ctx.logError("EXAMPLE.R4D owned-work: FAILED");
    if (ctx.memory() != null or ctx.graphicsDisplay() != null) return -1;
    if (ctx.workSubmit(normal, 0, 0, &completion) != 0 or (finish(&ctx) orelse return -1) != 0) return -1;
    if (ctx.workSubmitOwned(owned, 0, &completion) != 0 or (finish(&ctx) orelse return -1) != a.driver_work_owner_busy) return -1;
    @atomicStore(u32, &busy_observed, 1, .release);
    for (0..3000) |_| {
        if (@atomicLoad(u32, &init_done, .acquire) != 0) {
            if (ctx.workSubmitOwned(owned, 0, &completion) != 0) return -1;
            const code = finish(&ctx) orelse return -1;
            if (code != a.driver_work_owner_busy) {
                if (code != 0 or @atomicLoad(u32, &owned_hits, .acquire) != 1) return -1;
                result = 0;
                ctx.logInfo("EXAMPLE.R4D owned-work: OK dedicated=denied normal-mmio=denied init-owner=busy owned-memory-display=admitted BO=balanced");
                return 0;
            }
        }
        if (threads.sleepTicks(1) != 0) return -1;
    }
    return -1;
}
fn normal(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    const memory = ctx.memory() orelse return -1;
    return if (memory.table.mmio_map == 0 and memory.table.mmio_unmap == 0 and ctx.graphicsDisplay() == null) 0 else -1;
}
fn owned(_: usize) callconv(.c) i32 {
    _ = @atomicRmw(u32, &owned_hits, .Add, 1, .acq_rel);
    const ctx = r4os.r4dev.DriverContext.init(api);
    const memory = ctx.memory() orelse return -1;
    if (memory.table.mmio_map == 0 or memory.table.mmio_unmap == 0 or ctx.graphicsDisplay() == null or ctx.graphicsOutputs() == null) return -1;
    var before: a.GfxBufferStats = .{}; var after: a.GfxBufferStats = .{};
    if (memory.bufferStats(&before) != a.gfx_buffer_result_ok) return -1;
    var reference: a.GfxBufferReference = .{};
    if (memory.bufferCreate(&.{ .byte_length = 4096, .alignment = 4096, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &reference) != a.gfx_buffer_result_ok) return -1;
    const released = memory.bufferRelease(&reference.reference) == a.gfx_buffer_result_ok;
    if (!released or memory.collect() != a.gfx_buffer_result_ok or memory.bufferStats(&after) != a.gfx_buffer_result_ok) return -1;
    return if (before.objects == after.objects and before.references == after.references and before.leases == after.leases and before.committed_bytes == after.committed_bytes) 0 else -1;
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) i32 {
    const active = thread != 0 or completion != 0;
    if (thread != 0) {
        var code: i32 = -1;
        if (!joined) {
            if (threads.join(thread, 0, &code) != 0) return -1;
            joined = true;
        }
        if (threads.release(thread) != 0) return -1;
        thread = 0;
    }
    if (completion != 0) {
        var status: a.DriverCompletionStatus = .{};
        if (ctx.completionStatus(completion, &status) != 0 or
            (status.state != a.driver_work_state_completed and status.state != a.driver_work_state_cancelled) or ctx.completionRelease(completion) != 0) return -1;
        completion = 0;
    }
    if (active) ctx.logInfo("EXAMPLE.R4D owned-work shutdown: joined and completions released");
    return 0;
}
