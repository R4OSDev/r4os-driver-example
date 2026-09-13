// Explicit common-owner fixture, selected only by EXAMPLE mode=gfx-mode-test.
// It models device receipts without changing physical scanout or issuing DMA.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
var api: *const a.DriverApi = undefined;
var binding: a.GfxBackendBinding = .{};
var shadow: a.GfxBufferReference = .{};
var active: a.GfxNativeState = .{};
var identity: a.GfxOutputId = .{};
var publication: a.GfxOutputPublication = .{};
var deliveries: u32 = 0;
pub fn init(ctx: *const r4os.r4dev.DriverContext) bool {
    api = ctx.api;
    const memory = ctx.memory() orelse return false;
    const outputs = ctx.graphicsOutputs() orelse return false;
    const queues = ctx.graphicsQueue() orelse return false;
    const display = ctx.graphicsDisplay() orelse return false;
    if (!outputs.supportsModes()) return false;
    var boot: a.GfxNativeBootInfo = .{};
    if (display.bootInfo(&boot) != a.gfx_output_ok or boot.state != a.display_state_bootfb) return false;
    var adapter: u32 = 0;
    for (0..api.pci_device_count()) |index| {
        var pci: a.PciDeviceInfo = .{};
        if (api.pci_device_at(@intCast(index), &pci) < 0) return false;
        if (pci.class_code == 3) { adapter = 0x01000000 | (@as(u32, pci.bus) << 8) | (@as(u32, pci.device) << 3) | pci.function; break; }
    }
    if (adapter == 0 or queues.register(&.{ .adapter_id = adapter, .milestone = a.gfx_queue_milestone_device_execution,
        .notify_callback = @intFromPtr(&notify) }, &binding) != a.gfx_queue_ok) return false;
    if (outputs.enableModes(&binding) != a.gfx_output_error_stale) return false;
    publication = .{ .backend = binding, .info = .{ .identity = .{ .adapter_id = adapter, .connector_id = 0x7913, .device_generation = binding.device_generation },
        .flags = a.gfx_output_flag_connected, .connector_kind = a.gfx_output_kind_virtual, .mode_count = 1, .preferred_mode_id = 1,
        .possible_heads = 1, .possible_planes = 1, .possible_plls = 1,
        .limits = .{ .head_mask = 1, .plane_mask = 1, .pll_mask = 1, .max_width = boot.width, .max_height = boot.height } } };
    publication.modes[0] = .{ .mode_id = 1, .width = boot.width, .height = boot.height, .flags = a.gfx_output_mode_geometry_only };
    if (outputs.publish(&publication, &identity) != a.gfx_output_ok) return false;
    const pitch = @as(u64, boot.width) * 4;
    if (memory.bufferCreate(&.{ .byte_length = pitch * boot.height, .width = boot.width, .height = boot.height,
        .plane_count = 1, .plane_pitches = .{ pitch, 0, 0, 0 }, .format = a.gfx_buffer_format_xrgb8888,
        .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source }, &shadow) != a.gfx_buffer_result_ok) return false;
    var candidate: a.GfxNativeRegistration = .{ .backend = binding, .output = identity, .reference = shadow.reference,
        .commit_callback = @intFromPtr(&commit), .restore_callback = @intFromPtr(&restore) };
    @memcpy(candidate.name[0..7], "EXAMPLE");
    if (display.prepare(&candidate, &active) != a.gfx_output_ok or display.transition(active.generation, 0, &active) != a.gfx_output_ok or
        active.outcome != a.gfx_output_outcome_applied or outputs.enableModes(&binding) != a.gfx_output_ok) return false;
    publication.info.mode_count = 3;
    publication.info.limits = .{ .head_mask = 1, .plane_mask = 1, .pll_mask = 1, .max_width = 8192, .max_height = 8192,
        .flags = a.gfx_output_limit_modeset, .max_pixel_clock_hz = 1_000_000_000, .total_pixel_clock_hz = 1_000_000_000,
        .bandwidth_bytes_per_second = 4_000_000_000 };
    for ([_][2]u32{ .{320,200}, .{640,480}, .{800,600} }, 0..) |size, i| {
        const total_x = size[0] + 80; const total_y = size[1] + 25;
        publication.modes[i] = .{ .mode_id = @intCast(i + 1), .width = size[0], .height = size[1], .h_total = total_x, .v_total = total_y,
            .h_sync_start = size[0] + 16, .h_sync_end = size[0] + 48, .v_sync_start = size[1] + 4, .v_sync_end = size[1] + 8,
            .pixel_clock_hz = @as(u64, total_x) * total_y * 60, .refresh_millihz = 60000 };
    }
    if (outputs.publish(&publication, &identity) != a.gfx_output_ok) return false;
    ctx.logInfo("EXAMPLE.R4D mode fixture: ready primary=virtual geometry=variable GPU-commands=none");
    return true;
}
fn commit(_: u64, _: u64, _: *const a.GfxNativeBootInfo) callconv(.c) i32 { return 1; }
fn restore(_: u64, _: u64, _: *const a.GfxNativeBootInfo) callconv(.c) i32 { return 1; }
fn notify(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    const outputs = ctx.graphicsOutputs() orelse return -1;
    const queues = ctx.graphicsQueue() orelse return -1;
    var job: a.GfxDriverModeJob = .{};
    const taken = outputs.takeMode(&binding, &job);
    if (taken < 0) return -2;
    if (taken == a.gfx_output_ok) {
        deliveries += 1;
        var duplicate: a.GfxDriverModeJob = .{};
        if (outputs.takeMode(&binding, &duplicate) != 0) return -3;
        if (!std.meta.eql(binding, job.backend) or job.reference.reference.id == 0 or job.mode.mode_id != job.assignment.mode_id) return -4;
        if (job.operation == a.gfx_mode_operation_apply) {
            const memory = ctx.memory() orelse return -8;
            var mapped: a.GfxBufferMap = .{};
            if (memory.bufferMap(&job.reference.reference, a.gfx_buffer_map_read, 0, 4, &mapped) != a.gfx_buffer_result_ok) return -9;
            const pixel = @as(*const u32, @ptrFromInt(mapped.cpu_address)).*;
            if (memory.bufferUnmap(&mapped.lease) != a.gfx_buffer_result_ok or pixel != 0x0013579b) return -10;
        }
        var receipt: a.GfxDriverModeCompletion = .{ .ticket = job.ticket, .sequence = job.sequence, .operation = job.operation,
            .outcome = a.gfx_output_outcome_applied, .quiesced = 1 };
        if (job.operation == a.gfx_mode_operation_rollback or (job.operation == a.gfx_mode_operation_apply and job.mode.mode_id == 3)) {
            receipt.outcome = a.gfx_output_outcome_old_preserved; receipt.quiesced = 2;
            if (job.mode.mode_id == 3) receipt.error_code = a.gfx_output_error_unsupported;
        }
        var forged = receipt; forged.sequence += 1;
        if (outputs.completeMode(&forged) != a.gfx_output_error_stale or outputs.completeMode(&receipt) != a.gfx_output_ok or
            outputs.completeMode(&receipt) != a.gfx_output_error_stale) return -5;
    }
    var present: a.GfxDriverJob = .{};
    const rc = queues.take(&binding, &present);
    if (rc == a.gfx_queue_error_busy or rc == a.gfx_queue_error_device_lost) return 0;
    if (rc != a.gfx_queue_ok) return -6;
    return if (queues.complete(&present.fence, a.gfx_queue_result_complete, 1) == a.gfx_queue_ok) 0 else -7;
}
pub fn shutdown(ctx: *const r4os.r4dev.DriverContext) i32 {
    if (active.retained != 0) {
        const display = ctx.graphicsDisplay() orelse return -1;
        var current: a.GfxNativeBootInfo = .{};
        if (display.bootInfo(&current) != a.gfx_output_ok or display.transition(current.generation, 2, &active) != a.gfx_output_ok or active.retained != 0) return -2;
    }
    if (shadow.reference.id != 0) {
        if (ctx.memory().?.bufferRelease(&shadow.reference) != a.gfx_buffer_result_ok) return -3;
        shadow = .{};
    }
    ctx.logInfo("EXAMPLE.R4D mode fixture: restored boot backing released GPU-commands=none");
    return 0;
}
