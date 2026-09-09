// Opt-in memory acceptance. No device receives commands or DMA addresses.
const r4os = @import("r4os");
const a = r4os.abi;
const ok = a.gfx_buffer_result_ok;

pub fn run(ctx: *r4os.r4dev.DriverContext) bool {
    const memory = ctx.memory() orelse return failure(ctx, @src().line);
    var before: a.GfxBufferStats = .{};
    if (memory.bufferStats(&before) != ok) return failure(ctx, @src().line);
    if (!exercise(&memory, ctx)) return failure(ctx, @src().line);
    var after: a.GfxBufferStats = .{};
    return memory.collect() == ok and memory.bufferStats(&after) == ok and
        before.objects == after.objects and before.references == after.references and
        before.leases == after.leases and before.committed_bytes == after.committed_bytes and
        before.retained_bytes == after.retained_bytes;
}

fn exercise(memory: anytype, ctx: *r4os.r4dev.DriverContext) bool {
    const bytes: u64 = 80 * 1024 * 1024;
    const descriptor: a.GfxBufferDescriptor = .{
        .byte_length = bytes,
        .alignment = 4096,
        .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write |
            a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_transfer_target,
    };
    var first: a.GfxBufferReference = .{};
    const create_result = memory.bufferCreate(&descriptor, &first);
    if (create_result != ok) {
        var message: [96]u8 = undefined;
        ctx.logError(@import("std").fmt.bufPrintZ(&message, "EXAMPLE.R4D gfx-memory create status={d}", .{create_result}) catch unreachable);
        return failure(ctx, @src().line);
    }
    defer if (first.reference.id != 0) {
        _ = memory.bufferRelease(&first.reference);
    };
    var write: a.GfxBufferMap = .{};
    if (memory.bufferMap(&first.reference, 1, 0, bytes, &write) != ok) return failure(ctx, @src().line);
    defer if (write.lease.id != 0) {
        _ = memory.bufferUnmap(&write.lease);
    };
    const data: [*]u8 = @ptrFromInt(write.cpu_address);
    data[0] = 0x37;
    data[bytes - 1] = 0xA9;
    if (memory.bufferUnmap(&write.lease) != ok) return failure(ctx, @src().line);
    write.lease = .{};
    var imported: a.GfxBufferReference = .{};
    if (memory.bufferImport(&first.reference, &imported) != ok or
        first.buffer.id != imported.buffer.id or first.buffer.generation != imported.buffer.generation) return failure(ctx, @src().line);
    defer if (imported.reference.id != 0) {
        _ = memory.bufferRelease(&imported.reference);
    };
    var read: a.GfxBufferMap = .{};
    var second: a.GfxBufferMap = .{};
    if (memory.bufferMap(&first.reference, 0, 0, bytes, &read) != ok) return failure(ctx, @src().line);
    defer if (read.lease.id != 0) {
        _ = memory.bufferUnmap(&read.lease);
    };
    if (memory.bufferMap(&imported.reference, 0, 0, bytes, &second) != ok or second.cpu_address != read.cpu_address) return failure(ctx, @src().line);
    defer if (second.lease.id != 0) {
        _ = memory.bufferUnmap(&second.lease);
    };
    var gpu: a.GfxDeviceLease = .{};
    const virtual_request: a.GfxDeviceRequest = .{ .byte_length = 4096, .gpu_virtual_address = 0x2000000000, .device_generation = 1, .adapter_id = 0xFFFF, .access = 3, .address_space = 1 };
    if (memory.deviceAcquire(&first.reference, &virtual_request, &gpu) != ok) return failure(ctx, @src().line);
    defer if (gpu.lease.id != 0) {
        _ = memory.deviceRelease(&gpu, 1);
    };
    var no_dma: a.GfxDmaSegment = .{};
    if (gpu.gpu_virtual_address != virtual_request.gpu_virtual_address or gpu.gpu_virtual_address == read.cpu_address or
        memory.deviceSegment(&gpu, 0, &no_dma) != a.gfx_buffer_error_unsupported or
        memory.deviceRelease(&gpu, 0) != a.gfx_buffer_error_busy or memory.deviceRelease(&gpu, 1) != ok) return failure(ctx, @src().line);
    gpu.lease = .{};
    var device: a.GfxDeviceLease = .{};
    // Synthetic identity labels this never-submitted diagnostic lease only.
    const request: a.GfxDeviceRequest = .{ .byte_offset = 3, .byte_length = bytes - 3, .adapter_id = 0xFFFF, .device_generation = 1 };
    if (memory.deviceAcquire(&first.reference, &request, &device) != ok) return failure(ctx, @src().line);
    defer if (device.lease.id != 0) {
        _ = memory.deviceRelease(&device, 1);
    };
    var offset: u64 = 0;
    var segments: u32 = 0;
    while (offset < request.byte_length) {
        var part: a.GfxDmaSegment = .{};
        if (memory.deviceSegment(&device, offset, &part) != ok or part.byte_length == 0 or
            part.byte_length > 4096 or part.next_offset != offset + part.byte_length or
            part.next_offset > request.byte_length or part.dma_address == read.cpu_address + offset + 3) return failure(ctx, @src().line);
        offset = part.next_offset;
        segments += 1;
    }
    if (segments != 20480 or memory.deviceRelease(&device, 0) != a.gfx_buffer_error_busy) return failure(ctx, @src().line);
    var stale = device;
    stale.device_generation += 1;
    if (memory.deviceRelease(&stale, 1) != a.gfx_buffer_error_stale) return failure(ctx, @src().line);
    if (memory.bufferRelease(&first.reference) != ok) return failure(ctx, @src().line);
    first.reference = .{};
    if (memory.bufferRelease(&imported.reference) != ok) return failure(ctx, @src().line);
    imported.reference = .{};
    const retained: [*]const u8 = @ptrFromInt(read.cpu_address);
    if (retained[0] != 0x37 or retained[bytes - 1] != 0xA9) return failure(ctx, @src().line);
    if (memory.bufferUnmap(&read.lease) != ok) return failure(ctx, @src().line);
    read.lease = .{};
    if (memory.bufferUnmap(&second.lease) != ok) return failure(ctx, @src().line);
    second.lease = .{};
    // Proof is valid because this diagnostic never submitted hardware work.
    if (memory.deviceRelease(&device, 1) != ok or memory.deviceRelease(&device, 1) != a.gfx_buffer_error_stale) return failure(ctx, @src().line);
    device.lease = .{};
    var window: a.GfxMmioWindow = .{};
    const invalid: a.GfxMmioRequest = .{ .resource_base = 4096, .resource_bytes = 4096, .byte_offset = 8192, .byte_length = 4096, .cache_policy = a.gfx_buffer_cache_uncached };
    return memory.mmioMap(&invalid, &window) == a.gfx_buffer_error_invalid and window.handle.id == 0;
}

fn failure(ctx: *r4os.r4dev.DriverContext, line: u32) bool {
    var buffer: [96]u8 = undefined;
    const text = @import("std").fmt.bufPrintZ(&buffer, "EXAMPLE.R4D gfx-memory failed line={d}", .{line}) catch unreachable;
    ctx.logError(text);
    return false;
}
