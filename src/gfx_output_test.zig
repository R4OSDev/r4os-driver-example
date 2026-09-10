// Explicit virtual-connector fixture. No HPD/I2C/GPU or HDMI transmitter use.
const r4os = @import("r4os");
const gfx = @import("r4gfx_outputs");
const a = r4os.abi;
pub const adapter: u32 = 0xffff0007;
var api: *const a.DriverApi = undefined;
var queues: r4os.driver_queue.Context = undefined;
var outputs: r4os.driver_outputs.Context = undefined;
var binding: a.GfxBackendBinding = .{};
var identity: a.GfxOutputId = .{};
var ordinal: u32 = 0;
// Caller-owned large storage stays off the driver's bounded task stack.
var publication: a.GfxOutputPublication = .{};
var parsed: gfx.edid.Report = .{};
const qemu = @embedFile("fixtures/qemu.edid");
const hisense = @embedFile("fixtures/ossipc-hisense-base.bin");
pub fn init(ctx: *const r4os.r4dev.DriverContext) bool {
    api = ctx.api;
    queues = ctx.graphicsQueue() orelse return false;
    outputs = ctx.graphicsOutputs() orelse return false;
    const request = a.GfxBackendRegistration{ .adapter_id = adapter, .milestone = a.gfx_queue_milestone_device_execution, .notify_callback = @intFromPtr(&notify) };
    if (queues.register(&request, &binding) != a.gfx_queue_ok or !publish(qemu)) return false;
    ctx.logInfo("EXAMPLE.R4D outputs: registered virtual fixture hardware-writes=none");
    return true;
}
fn publish(bytes: []const u8) bool {
    gfx.edid.parse(bytes, &parsed) catch return false;
    publication = .{ .backend = binding, .info = .{
        .identity = .{ .adapter_id = adapter, .connector_id = 17, .device_generation = binding.device_generation },
        .flags = a.gfx_output_flag_connected, .connector_kind = a.gfx_output_kind_virtual, .edid_bytes = @intCast(bytes.len),
        .possible_heads = 1, .possible_planes = 1, .possible_plls = 1,
        .limits = .{ .head_mask = 1, .plane_mask = 1, .pll_mask = 1, .max_width = 8192, .max_height = 8192 },
    } };
    for (parsed.modes[0..parsed.mode_count]) |value| {
        if (publication.info.mode_count == publication.modes.len) return false;
        const mode = gfx.modeFromTiming(value, publication.info.mode_count + 1) orelse continue;
        if (mode.flags & a.gfx_output_mode_interlaced != 0) continue;
        publication.modes[publication.info.mode_count] = mode;
        publication.info.mode_count += 1;
        if (publication.info.preferred_mode_id == 0 and mode.flags & a.gfx_output_mode_preferred != 0) publication.info.preferred_mode_id = mode.mode_id;
    }
    @memcpy(publication.edid[0..bytes.len], bytes);
    return publication.info.mode_count > 0 and outputs.publish(&publication, &identity) == a.gfx_output_ok;
}
fn notify(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    var job: a.GfxDriverJob = .{};
    const rc = queues.take(&binding, &job);
    if (rc == a.gfx_queue_error_busy or rc == a.gfx_queue_error_device_lost) return 0;
    if (rc != a.gfx_queue_ok) return -1;
    if (job.operation != a.gfx_queue_operation_barrier) {
        _ = queues.complete(&job.fence, a.gfx_queue_result_failed, 1);
        return 0;
    }
    ordinal += 1;
    var success = false;
    switch (ordinal) {
        1 => success = outputs.withdraw(&identity) == a.gfx_output_ok,
        2 => success = publish(hisense),
        3 => {
            var next: a.GfxBackendBinding = .{};
            success = queues.reset(&binding, 1, &next) == a.gfx_queue_ok;
            if (success) { binding = next; success = publish(qemu); }
            ctx.logInfo(if (success) "EXAMPLE.R4D outputs reset: OK old-receiver=invalidated" else "EXAMPLE.R4D outputs reset: FAILED");
            return if (success) 0 else -1; // Reset already terminated this fence.
        },
        else => success = true,
    }
    ctx.logInfo(if (success) "EXAMPLE.R4D outputs publication: OK desktop-event=signaled" else "EXAMPLE.R4D outputs publication: FAILED");
    const result = if (success) a.gfx_queue_result_complete else a.gfx_queue_result_failed;
    return if (queues.complete(&job.fence, result, 1) == a.gfx_queue_ok) 0 else -1;
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) i32 {
    if (binding.device_generation == 0) return 0;
    const deadline = ctx.tickCount() + ctx.timerFrequency();
    while (true) {
        const rc = queues.unregister(&binding, 1);
        if (rc == a.gfx_queue_ok) { binding = .{}; return 0; }
        if (rc != a.gfx_queue_error_busy or ctx.tickCount() >= deadline) return -1;
        ctx.waitTicks(1);
    }
}
