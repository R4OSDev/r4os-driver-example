//! Opt-in common render transport. Synthetic BOs never reach a GPU; every
//! accepted command deliberately returns a failed execution receipt.
const std = @import("std");
const r4os = @import("r4os");
const nv = @import("r4nv_binding");
const a = r4os.abi;
var queue: r4os.driver_queue.Context = undefined;
var memory: r4os.driver_memory.Context = undefined;
var context: r4os.r4dev.DriverContext = undefined;
var binding: a.GfxBackendBinding = .{};

pub fn init(ctx: *const r4os.r4dev.DriverContext, adapter: u32, epoch: u64) bool {
    if (binding.device_generation != 0) return true;
    context = ctx.*;
    queue = ctx.graphicsQueue() orelse return false;
    memory = ctx.memory() orelse return false;
    const details: nv.R4NvDriverProfile = .{ .version = 1, .size = @sizeOf(nv.R4NvDriverProfile), .vendor_id = 0x10de,
        .copy_class = 0xc6b5, .rm_release = nv.rm_release, .command_abi = nv.command_abi, .reserved0 = 0, .reserved1 = 0 };
    var profile: a.GfxBackendProfile = .{ .interface_id_lo = nv.backend_v1_header.interface_id_lo,
        .interface_id_hi = nv.backend_v1_header.interface_id_hi, .revision = 1, .data_bytes = @sizeOf(nv.R4NvDriverProfile) };
    @memcpy(profile.data[0..@sizeOf(nv.R4NvDriverProfile)], std.mem.asBytes(&details));
    if (queue.registerProfile(&.{ .adapter_id = adapter, .memory_generation = epoch, .operations = 13,
        .milestone = a.gfx_queue_milestone_device_execution, .notify_callback = @intFromPtr(&work) }, &profile, &binding) != a.gfx_queue_ok or
        queue.updateOperations(&binding, 29) != a.gfx_queue_ok) return false;
    ctx.logInfo("EXAMPLE.R4D gfx-render: ready synthetic-profile no-GPU");
    return true;
}
fn work(_: usize) callconv(.c) i32 {
    // Removing a capability must not truncate a previously admitted job.
    if (queue.updateOperations(&binding, 13) != a.gfx_queue_ok) return -1;
    const Short = extern struct { version: u32 = 1, size: u32 = 136, payload: [128]u8 = @splat(0), canary: u64 = 0xF192A365C784E0B6 };
    var short: Short = .{};
    // Current SDK take initializes current capacity. An actual legacy caller
    // invokes the wire callback with its own smaller allocation instead.
    const legacy_take: *const fn (*const a.GfxBackendBinding, *Short) callconv(.c) i32 = @ptrFromInt(queue.table.take);
    if (legacy_take(&binding, &short) != a.gfx_queue_error_invalid or short.size != 136 or
        short.canary != 0xF192A365C784E0B6) return -1;
    for (short.payload) |byte| if (byte != 0) return -1;
    if (queue.updateOperations(&binding, 29) != a.gfx_queue_ok) return -1;
    var job: a.GfxDriverJob = .{};
    const rc = queue.take(&binding, &job);
    if (rc == a.gfx_queue_error_busy) return 0;
    if (rc != a.gfx_queue_ok) return -1;
    const okay = inspect(job);
    if (queue.complete(&job.fence, a.gfx_queue_result_failed, 1) != a.gfx_queue_ok) return -1;
    context.logInfo(if (okay) "EXAMPLE.R4D gfx-render: OK immutable-state held-BOs short-take=denied receipt=failed no-GPU" else "EXAMPLE.R4D gfx-render: FAILED");
    return if (okay) 0 else -1;
}
fn inspect(job: a.GfxDriverJob) bool {
    const command = job.render;
    if (job.size != @sizeOf(a.GfxDriverJob) or job.operation != a.gfx_queue_operation_render or job.deadline_ns == 0 or
        job.source_offset != 0 or job.target_offset != 0 or job.byte_length != 0 or job.row_count != 0 or job.source_pitch != 0 or job.target_pitch != 0 or
        command.target_rect.x != -1 or command.target_rect.y != 0 or command.target_rect.width != 5 or command.target_rect.height != 3 or
        command.scissor.x != 0 or command.scissor.y != 1 or command.scissor.width != 3 or command.scissor.height != 2 or command.opacity != 127) return false;
    const sampled = command.kind == a.gfx_render_kind_sample;
    if (sampled) {
        if (command.filter != a.gfx_render_filter_bilinear or command.blend != a.gfx_render_blend_over or
            command.transfer != a.gfx_render_transfer_srgb_decode or command.color != 0 or command.source_rect.x != 0 or command.source_rect.y != 0 or
            command.source_rect.width != 5 or command.source_rect.height != 3) return false;
    } else if (command.kind != a.gfx_render_kind_fill or command.color != 0x80402010 or command.filter != 0 or command.blend != 0 or
        command.transfer != 0 or !std.meta.eql(command.source_rect, a.GfxRenderRect{}) or job.source_buffer.id != 0) return false;
    for ((if (sampled) @as(usize, 0) else 1)..2) |index| {
        var reference: a.GfxBufferReference = .{};
        if (queue.retainResource(&job.fence, @intCast(index), &reference) != a.gfx_queue_ok) return false;
        defer _ = memory.bufferRelease(&reference.reference);
        var descriptor: a.GfxBufferDescriptor = .{};
        if (reference.flags != a.gfx_buffer_reference_mapping_only or
            !std.meta.eql(reference.buffer, if (index == 0) job.source_buffer else job.target_buffer) or
            memory.bufferDescribe(&reference.reference, &descriptor) != a.gfx_buffer_result_ok or descriptor.width != 5 or descriptor.height != 3 or
            descriptor.location != a.gfx_buffer_location_device_local or descriptor.plane_pitches[0] != 256) return false;
        var cpu: a.GfxBufferMap = .{};
        if (memory.bufferMap(&reference.reference, 0, 0, 1, &cpu) != a.gfx_buffer_error_unsupported) return false;
    }
    return true;
}
pub fn shutdown() bool {
    if (binding.device_generation == 0) return true;
    if (queue.unregister(&binding, 1) != a.gfx_queue_ok) return false;
    binding = .{};
    return true;
}
