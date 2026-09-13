//! Opt-in request/BO lifetime fixture. Synthetic backing, no GPU or DMA.
const r4os = @import("r4os");
const a = r4os.abi;
const adapter = 0xffff;
const epoch = 0x079190001;
var memory: r4os.driver_memory.Context = undefined;
var provider: a.GfxBufferHandle = .{};
var cookie: u64 = 0;
pub fn init(ctx: *const r4os.r4dev.DriverContext) bool {
    memory = ctx.memory() orelse return false;
    if (memory.nativeRegister(&.{ .adapter_id = adapter, .memory_generation = epoch, .notify = @intFromPtr(&work) }, &provider) != 1) return false;
    ctx.logInfo("EXAMPLE.R4D gfx-allocation: ready synthetic-backing no-GPU");
    return true;
}
fn collect() bool {
    for (0..16) |_| {
        var release: a.GfxOwnedBufferRelease = .{};
        const rc = memory.bufferTakeRelease(adapter, epoch, &release);
        if (rc == a.gfx_buffer_error_busy) return true;
        if (rc != 1 or release.cookie == 0 or release.cookie > cookie or memory.bufferFinishRelease(&release, 1) != 1) return false;
    }
    return false;
}
fn work(_: usize) callconv(.c) i32 {
    if (!collect()) return -1;
    for (0..16) |_| {
        var job: a.GfxNativeJob = .{};
        const rc = memory.nativeTake(&provider, &job);
        if (rc == a.gfx_buffer_error_busy) return 0;
        if (rc != 1) return -1;
        const input = job.allocation;
        if (input.kind != 1 or input.format != a.gfx_buffer_format_xrgb8888 or input.width != 5 or input.height != 3 or input.layout != 0) {
            if (memory.nativeComplete(&provider, &job.request, a.gfx_buffer_error_unsupported, &.{}) != 1) return -1;
            continue;
        }
        const descriptor: a.GfxBufferDescriptor = .{ .byte_length = 65536, .alignment = 65536, .width = 5, .height = 3, .format = input.format, .plane_count = 1, .plane_pitches = .{ 256, 0, 0, 0 }, .usage = input.usage, .location = a.gfx_buffer_location_device_local, .adapter_id = adapter, .device_generation = epoch };
        cookie += 1;
        var ticket: a.GfxOwnedBufferReservation = .{};
        var reference: a.GfxBufferReference = .{};
        if (memory.bufferReserve(&descriptor, cookie, &ticket) != 1 or memory.bufferCommit(&ticket, &reference) != 1) return -1;
        if (memory.nativeComplete(&provider, &job.request, 1, &reference.reference) != 1 or memory.bufferRelease(&reference.reference) != 1) return -1;
    }
    return 0;
}
pub fn shutdown() i32 {
    if (!collect()) return -1;
    if (provider.id != 0) {
        const rc = memory.nativeUnregister(&provider);
        // Kernel driver-close can have drained the exact retired provider.
        if (rc != 1 and rc != a.gfx_buffer_error_stale) return -1;
        provider = .{};
    }
    return 0;
}
