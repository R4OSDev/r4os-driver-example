// Opt-in memory acceptance. No device receives commands or DMA addresses.
const r4os = @import("r4os");
const a = r4os.abi;
const ok = a.gfx_buffer_result_ok;
const std = @import("std");
var driver_api: *const a.DriverApi = undefined;
var cached: r4os.driver_memory.Context = undefined;
var handoff: a.GfxBufferReference = .{};
var worker: u32 = 0;
var thread: u64 = 0;
var closing: a.GfxBufferReference = .{};
var closing_cpu: a.GfxBufferMap = .{};
var closing_dma: a.GfxDeviceLease = .{};
var closing_gpu: a.GfxDeviceLease = .{};
var closing_before: a.GfxBufferStats = .{};
var closing_armed = false;
var closing_owned: a.GfxOwnedBufferReservation = .{};
var closing_owned_live: a.GfxBufferReference = .{};
const owned_descriptor: a.GfxBufferDescriptor = .{ .byte_length = 4091, .alignment = 65536, .usage = 12,
    .modifier = 0x0300000000606010, .width = 5, .height = 3, .format = 0x3231564e, .plane_count = 2,
    .plane_offsets = .{0,2048,0,0}, .plane_pitches = .{64,64,0,0},
    .location = a.gfx_buffer_location_device_local, .adapter_id = 0xFFFF, .device_generation = 0x300000007 };
const small_bytes = 3 * 4096;
const small_descriptor: a.GfxBufferDescriptor = .{
    .byte_length = small_bytes,
    .alignment = 4096,
    .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write |
        a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_transfer_target,
};

pub fn run(ctx: *r4os.r4dev.DriverContext) bool {
    const memory = ctx.memory() orelse return failure(ctx, @src().line);
    driver_api = ctx.api;
    cached = memory;
    var before: a.GfxBufferStats = .{};
    if (memory.bufferStats(&before) != ok) return failure(ctx, @src().line);
    const Prefix = extern struct { bytes: [112]u8 align(8), canary: [16]u8 };
    var prefix: Prefix = undefined; @memset(std.mem.asBytes(&prefix), 0xA5);
    const old: *a.GfxDriverMemoryApi = @ptrCast(&prefix);
    old.version = 1; old.size = 113;
    if (ctx.api.gfx_memory_query.?(old) != ok or old.size != 112 or !std.mem.allEqual(u8, &prefix.canary, 0xA5)) return failure(ctx, @src().line);
    if (!exerciseOwned(&memory, ctx)) return failure(ctx, @src().line);
    ctx.logInfo("EXAMPLE.R4D gfx-owned init: OK prefix=112 canary=preserved exact-tickets=balanced opaque-layout=preserved");
    if (!bootHold(&memory, ctx)) return failure(ctx, @src().line);
    if (!workHandoff(ctx)) return failure(ctx, @src().line);
    var after: a.GfxBufferStats = .{};
    return memory.collect() == ok and memory.bufferStats(&after) == ok and
        before.objects == after.objects and before.references == after.references and
        before.leases == after.leases and before.committed_bytes == after.committed_bytes and
        before.retained_bytes == after.retained_bytes;
}

fn workHandoff(ctx: *r4os.r4dev.DriverContext) bool {
    if (cached.bufferCreate(&small_descriptor, &handoff) != ok) return failure(ctx, @src().line);
    if (ctx.workSubmit(memoryWork, 0, 0, &worker) != 0) return failure(ctx, @src().line);
    var result: i32 = -1;
    // Stable module state survives a timeout; Shutdown drains it before free.
    if (ctx.completionWait(worker, 5 * ctx.timerFrequency(), &result) != 0 or result != 0 or
        ctx.completionRelease(worker) != 0) return failure(ctx, @src().line);
    worker = 0;
    var read: a.GfxBufferMap = .{};
    if (cached.bufferMap(&handoff.reference, 0, 0, small_bytes, &read) != ok) return failure(ctx, @src().line);
    const bytes: [*]const u8 = @ptrFromInt(read.cpu_address);
    const same = bytes[0] == 0x71 and bytes[small_bytes - 1] == 0xE4;
    if (cached.bufferUnmap(&read.lease) != ok or !same) return failure(ctx, @src().line);
    const threads = ctx.threads() orelse return failure(ctx, @src().line);
    if (threads.start(dedicatedDenied, 0, a.driver_thread_flag_parallel, &thread) != 0 or
        threads.join(thread, ctx.timerFrequency(), &result) != 0 or result != 0) return failure(ctx, @src().line);
    const deadline = ctx.tickCount() + ctx.timerFrequency();
    while (threads.release(thread) != 0) {
        if (ctx.tickCount() >= deadline) return failure(ctx, @src().line);
        ctx.waitTicks(1);
    }
    thread = 0;
    if (cached.bufferRelease(&handoff.reference) != ok) return failure(ctx, @src().line);
    handoff = .{};
    ctx.logInfo("EXAMPLE.R4D gfx-memory work: OK init-import=same-BO query=worker mmio=denied dedicated=denied release=balanced");
    return true;
}

fn memoryWork(_: usize) callconv(.c) i32 {
    var ctx = r4os.r4dev.DriverContext.init(driver_api);
    const memory = ctx.memory() orelse return failureCode(&ctx, @src().line);
    if (memory.table.mmio_map != 0 or memory.table.mmio_unmap != 0) return failureCode(&ctx, @src().line);
    var window: a.GfxMmioWindow = .{};
    // WB is unsupported for an MMIO window. An incorrectly admitted cached
    // call would return UNSUPPORTED, without mapping or touching hardware.
    if (cached.mmioMap(&.{ .cache_policy = a.gfx_buffer_cache_write_back }, &window) != a.gfx_buffer_error_invalid) return failureCode(&ctx, @src().line);
    var imported: a.GfxBufferReference = .{};
    if (memory.bufferImport(&handoff.reference, &imported) != ok or !std.meta.eql(handoff.buffer, imported.buffer)) return failureCode(&ctx, @src().line);
    defer _ = memory.bufferRelease(&imported.reference);
    var map: a.GfxBufferMap = .{};
    if (cached.bufferMap(&imported.reference, 1, 0, small_bytes, &map) != ok) return failureCode(&ctx, @src().line);
    const data: [*]u8 = @ptrFromInt(map.cpu_address);
    data[0] = 0x71;
    data[small_bytes - 1] = 0xE4;
    if (memory.bufferUnmap(&map.lease) != ok or !exercise(&memory, &ctx)) return failureCode(&ctx, @src().line);
    if (!exerciseOwned(&memory, &ctx)) return failureCode(&ctx, @src().line);
    ctx.logInfo("EXAMPLE.R4D gfx-owned work: OK imported-and-GPU=retained system-collect=independent");
    return 0;
}

fn dedicatedDenied(_: usize) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(driver_api);
    var output: a.GfxBufferDescriptor = .{};
    var stats: a.GfxBufferStats = .{};
    return if (ctx.memory() == null and cached.bufferDescribe(&handoff.reference, &output) == a.gfx_buffer_error_invalid and
        cached.bufferStats(&stats) == a.gfx_buffer_error_invalid) 0 else -1;
}

pub fn prepareClose() bool {
    if (cached.bufferStats(&closing_before) != ok or cached.bufferCreate(&small_descriptor, &closing) != ok) return false;
    if (cached.bufferMap(&closing.reference, 0, 0, small_bytes, &closing_cpu) != ok) return false;
    if (cached.deviceAcquire(&closing.reference, &.{ .adapter_id = 0xFFFF, .device_generation = 1, .byte_length = small_bytes, .access = 4 }, &closing_dma) != ok) return false;
    if (cached.deviceAcquire(&closing.reference, &.{ .adapter_id = 0xFFFF, .device_generation = 1, .byte_length = small_bytes, .gpu_virtual_address = 0x2000000000, .access = 3, .address_space = 1 }, &closing_gpu) != ok) return false;
    var owned: a.GfxOwnedBufferReservation = .{};
    if (cached.bufferReserve(&owned_descriptor, 42, &closing_owned) != ok or cached.bufferReserve(&owned_descriptor, 43, &owned) != ok or
        cached.bufferCommit(&owned, &closing_owned_live) != ok) return false;
    closing_armed = true;
    return true;
}

pub fn shutdown(ctx: *r4os.r4dev.DriverContext) i32 {
    if (worker != 0) {
        var result: i32 = -1;
        if (ctx.completionWait(worker, ctx.timerFrequency(), &result) != 0 or ctx.completionRelease(worker) != 0) return -1;
        worker = 0;
    }
    if (thread != 0) {
        const threads = ctx.threads() orelse return -1;
        var result: i32 = -1;
        if (threads.join(thread, ctx.timerFrequency(), &result) != 0 or threads.release(thread) != 0) return -1;
        thread = 0;
    }
    if (handoff.reference.id != 0) {
        if (cached.bufferRelease(&handoff.reference) != ok) return -1;
        handoff = .{};
    }
    if (closing_armed) {
        var table: a.GfxDriverMemoryApi = .{};
        var reference: a.GfxBufferReference = .{};
        var map: a.GfxBufferMap = .{};
        var piece: a.GfxDmaSegment = .{};
        if (ctx.api.gfx_memory_query.?(&table) != a.gfx_buffer_error_closed or
            cached.bufferCreate(&small_descriptor, &reference) != a.gfx_buffer_error_closed or
            cached.bufferImport(&closing.reference, &reference) != a.gfx_buffer_error_closed or
            cached.bufferMap(&closing.reference, 0, 0, 1, &map) != a.gfx_buffer_error_closed or
            cached.deviceSegment(&closing_dma, 0, &piece) != ok or piece.byte_length != 4096 or
            cached.deviceRelease(&closing_dma, 0) != a.gfx_buffer_error_busy) return -1;
    }
    if (closing.reference.id != 0) {
        if (cached.bufferRelease(&closing.reference) != ok) return -1;
        closing = .{};
    }
    if (closing_cpu.lease.id != 0) {
        const data: [*]const u8 = @ptrFromInt(closing_cpu.cpu_address);
        if (data[0] != 0 or data[small_bytes - 1] != 0 or cached.bufferUnmap(&closing_cpu.lease) != ok) return -1;
        closing_cpu = .{};
    }
    // Diagnostic residency leases never reached hardware; quiescence is real.
    if (closing_gpu.lease.id != 0) {
        if (cached.deviceRelease(&closing_gpu, 1) != ok) return -1;
        closing_gpu = .{};
    }
    if (closing_dma.lease.id != 0) {
        if (cached.deviceRelease(&closing_dma, 1) != ok) return -1;
        closing_dma = .{};
    }
    if (closing_armed) {
        var denied: a.GfxOwnedBufferReservation = .{};
        var reference: a.GfxBufferReference = .{};
        var release: a.GfxOwnedBufferRelease = .{};
        if (cached.bufferReserve(&owned_descriptor, 44, &denied) != a.gfx_buffer_error_closed or
            cached.bufferCommit(&closing_owned, &reference) != a.gfx_buffer_error_closed or
            cached.bufferAbort(&closing_owned, 0) != a.gfx_buffer_error_busy or cached.bufferAbort(&closing_owned, 1) != ok or
            cached.bufferRelease(&closing_owned_live.reference) != ok or
            cached.bufferTakeRelease(owned_descriptor.adapter_id, owned_descriptor.device_generation, &release) != ok or
            cached.bufferFinishRelease(&release, 0) != a.gfx_buffer_error_busy or cached.bufferFinishRelease(&release, 1) != ok) return -1;
        closing_owned = .{}; closing_owned_live = .{};
        ctx.logInfo("EXAMPLE.R4D gfx-owned close: OK admission=closed abort-and-retire=balanced");
        var after: a.GfxBufferStats = .{};
        if (cached.collect() != ok or cached.bufferStats(&after) != ok or after.objects != closing_before.objects or
            after.references != closing_before.references or after.leases != closing_before.leases or
            after.committed_bytes != closing_before.committed_bytes or after.retained_bytes != closing_before.retained_bytes) return -1;
        ctx.logInfo("EXAMPLE.R4D gfx-memory close: OK admission=closed cached-release=allowed DMA-GPU-CPU=balanced");
        closing_armed = false;
    }
    return 0;
}

// Synthetic opaque backing only: no native allocation is sent to hardware.
// Both Init and ordinary Work traverse the real kernel ownership API.
fn exerciseOwned(memory: *const r4os.driver_memory.Context, ctx: *r4os.r4dev.DriverContext) bool {
    var ticket: a.GfxOwnedBufferReservation = .{};
    var reference: a.GfxBufferReference = .{};
    var imported: a.GfxBufferReference = .{};
    var cpu: a.GfxBufferMap = .{};
    var gpu: a.GfxDeviceLease = .{};
    var release: a.GfxOwnedBufferRelease = .{};
    var described: a.GfxBufferDescriptor = .{};
    if (memory.bufferCreate(&owned_descriptor, &reference) != a.gfx_buffer_error_unsupported) return failure(ctx, @src().line);
    if (memory.bufferReserve(&owned_descriptor, 0x100000079, &ticket) != ok or ticket.allocation_bytes != 65536 or ticket.driver_generation == 0) return failure(ctx, @src().line);
    if (memory.bufferImport(&ticket.reference, &imported) != a.gfx_buffer_error_closed or memory.bufferAbort(&ticket, 0) != a.gfx_buffer_error_busy) return failure(ctx, @src().line);
    var forged = ticket; forged.cookie += 1;
    if (memory.bufferCommit(&forged, &reference) != a.gfx_buffer_error_stale or memory.bufferCommit(&ticket, &reference) != ok or
        memory.bufferImport(&reference.reference, &imported) != ok or memory.bufferMap(&reference.reference, 0, 0, 1, &cpu) != a.gfx_buffer_error_unsupported) return failure(ctx, @src().line);
    if (memory.bufferDescribe(&imported.reference, &described) != ok or described.modifier != owned_descriptor.modifier or
        described.byte_length != 4091 or described.plane_count != 2 or described.plane_offsets[1] != 2048 or described.plane_pitches[1] != 64 or
        described.driver_owner != ticket.driver_owner or described.device_generation != owned_descriptor.device_generation) return failure(ctx, @src().line);
    if (memory.deviceAcquire(&reference.reference, &.{ .byte_length = 4091, .adapter_id = owned_descriptor.adapter_id,
        .device_generation = owned_descriptor.device_generation, .gpu_virtual_address = 0x3000000000, .access = 1, .address_space = 1 }, &gpu) != ok) return failure(ctx, @src().line);
    if (memory.bufferRelease(&reference.reference) != ok or memory.bufferTakeRelease(owned_descriptor.adapter_id, owned_descriptor.device_generation, &release) != a.gfx_buffer_error_busy or
        memory.bufferRelease(&imported.reference) != ok or memory.bufferTakeRelease(owned_descriptor.adapter_id, owned_descriptor.device_generation, &release) != a.gfx_buffer_error_busy or
        memory.deviceRelease(&gpu, 0) != a.gfx_buffer_error_busy or memory.deviceRelease(&gpu, 1) != ok) return failure(ctx, @src().line);
    var before: a.GfxBufferStats = .{}; var after: a.GfxBufferStats = .{};
    if (memory.bufferStats(&before) != ok or memory.bufferCreate(&small_descriptor, &reference) != ok or memory.bufferRelease(&reference.reference) != ok or
        memory.bufferStats(&after) != ok or after.committed_bytes != before.committed_bytes or after.objects != before.objects) return failure(ctx, @src().line);
    if (memory.bufferTakeRelease(owned_descriptor.adapter_id, owned_descriptor.device_generation + 1, &release) != a.gfx_buffer_error_busy or
        memory.bufferTakeRelease(owned_descriptor.adapter_id, owned_descriptor.device_generation, &release) != ok or memory.bufferFinishRelease(&release, 0) != a.gfx_buffer_error_busy) return failure(ctx, @src().line);
    var wrong = release; wrong.byte_length -= 1;
    if (memory.bufferFinishRelease(&wrong, 1) != a.gfx_buffer_error_stale or memory.bufferFinishRelease(&release, 1) != ok or
        memory.bufferFinishRelease(&release, 1) != a.gfx_buffer_error_stale) return failure(ctx, @src().line);
    return true;
}

fn noRecovery(_: u64, _: u64, _: *const a.GfxNativeBootInfo) callconv(.c) i32 {
    return 0;
}

fn bootHold(memory: anytype, ctx: *r4os.r4dev.DriverContext) bool {
    const display = ctx.graphicsDisplay() orelse return failure(ctx, @src().line);
    // Exercise the actual kernel query with an old caller allocation. A new
    // provider must neither overwrite its canary nor demand the new tail.
    const Legacy = extern struct { version: u32 = 1, size: u32 = 40, slots: [4]u64 = .{0} ** 4, canary: u64 = 0x0791079107910791 };
    var legacy: Legacy = .{};
    if (ctx.api.gfx_display_query.?(@ptrCast(&legacy)) != a.gfx_output_ok or legacy.size != 40 or
        legacy.canary != 0x0791079107910791 or legacy.slots[0] == 0 or legacy.slots[3] == 0) return failure(ctx, @src().line);
    const Previous = extern struct { version: u32 = 1, size: u32 = 63, slots: [6]u64 = .{0} ** 6, canary: u64 = 0x0791307913079130 };
    var previous: Previous = .{};
    if (ctx.api.gfx_display_query.?(@ptrCast(&previous)) != a.gfx_output_ok or previous.size != 56 or
        previous.canary != 0x0791307913079130 or previous.slots[5] == 0 or display.table.size != 64 or display.table.prepare_held == 0) return failure(ctx, @src().line);
    var boot: a.GfxNativeBootInfo = .{};
    if (display.bootInfo(&boot) != a.gfx_output_ok or boot.state != 1 or boot.policy != 0) return failure(ctx, @src().line);
    var adapter: u32 = 0;
    for (0..ctx.api.pci_device_count()) |index| {
        var pci: a.PciDeviceInfo = .{};
        if (ctx.api.pci_device_at(@intCast(index), &pci) < 0) return failure(ctx, @src().line);
        if (pci.class_code == 3) {
            adapter = 0x01000000 | (@as(u32, pci.bus) << 8) | (@as(u32, pci.device) << 3) | pci.function;
            break;
        }
    }
    if (adapter == 0) return failure(ctx, @src().line);
    const bytes = @as(u64, boot.pitch) * boot.height;
    var reference: a.GfxBufferReference = .{};
    if (memory.bufferCreate(&.{ .byte_length = bytes, .alignment = 4096, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &reference) != ok) return failure(ctx, @src().line);
    defer if (reference.reference.id != 0) {
        _ = memory.bufferRelease(&reference.reference);
    };
    var held: a.GfxNativeState = .{};
    const short_header: extern struct { version: u32 = 1, size: u32 = 8 } align(8) = .{};
    if (display.bootHold(@ptrCast(&short_header), &held) != a.gfx_output_error_invalid or held.retained != 0) return failure(ctx, @src().line);
    if (display.bootHold(&.{ .adapter_id = adapter, .generation = boot.generation, .reference = reference.reference, .restore_callback = @intFromPtr(&noRecovery) }, &held) != a.gfx_output_ok) return failure(ctx, @src().line);
    defer if (held.retained != 0) {
        var cleanup: a.GfxNativeState = .{};
        _ = display.bootFinish(held.generation, 0, &cleanup);
    };
    if (held.retained != 1 or held.outcome != a.gfx_output_outcome_validated or held.state != 2) return failure(ctx, @src().line);
    var write: a.GfxBufferMap = .{};
    if (memory.bufferMap(&reference.reference, a.gfx_buffer_map_write, 0, bytes, &write) != a.gfx_buffer_error_busy) {
        if (write.lease.id != 0) _ = memory.bufferUnmap(&write.lease);
        return failure(ctx, @src().line);
    }
    var read: a.GfxBufferMap = .{};
    if (memory.bufferMap(&reference.reference, a.gfx_buffer_map_read, 0, bytes, &read) != ok) return failure(ctx, @src().line);
    defer if (read.lease.id != 0) {
        _ = memory.bufferUnmap(&read.lease);
    };
    var hash: [32]u8 = undefined;
    const data: [*]const u8 = @ptrFromInt(read.cpu_address);
    @import("std").crypto.hash.sha2.Sha256.hash(data[0..bytes], &hash, .{});
    // Drop the original reference early. Kernel reference + both immutable
    // read leases must keep the actual pixels alive until ordered cleanup.
    if (memory.bufferRelease(&reference.reference) != ok) return failure(ctx, @src().line);
    reference = .{};
    var state: a.GfxNativeState = .{};
    if (display.bootFinish(held.generation - 1, 0, &state) != a.gfx_output_error_stale) return failure(ctx, @src().line);
    if (display.bootFinish(held.generation, 0, &state) != a.gfx_output_ok or state.retained != 0 or
        state.outcome != a.gfx_output_outcome_old_preserved or state.state != 1) return failure(ctx, @src().line);
    held.retained = 0;
    var after_hash: [32]u8 = undefined;
    @import("std").crypto.hash.sha2.Sha256.hash(data[0..bytes], &after_hash, .{});
    if (!@import("std").mem.eql(u8, &hash, &after_hash)) return failure(ctx, @src().line);
    if (memory.bufferUnmap(&read.lease) != ok) return failure(ctx, @src().line);
    read = .{};
    var after: a.GfxNativeBootInfo = .{};
    if (display.bootInfo(&after) != a.gfx_output_ok or after.generation != boot.generation or
        after.physical_address != boot.physical_address or after.state != 1) return failure(ctx, @src().line);
    ctx.logInfo("EXAMPLE.R4D boot-display result: OK prefix=40 immutable=yes stale=rejected early-reference-release=held pixels=stable writers=restored effects=none");
    return heldNative(memory, ctx, &display, &after, adapter);
}

// The existing opt-in fixture exercises real kernel BO/queue/display bridges.
// These callbacks send no device commands; they temporarily model confirmation
// and immediately restore the unchanged boot output before any app can draw.
var held_native_probe: struct {
    shadow: a.GfxBufferHandle = .{},
    source: u64 = 0,
    boot: a.GfxNativeBootInfo = .{},
    commits: u32 = 0,
    old_restores: u32 = 0,
    native_restores: u32 = 0,
    commit_result: i32 = 2,
} = .{};
fn heldNativeNotify(_: usize) callconv(.c) i32 { return 0; }
fn heldNativeRestore(context: u64, _: u64, _: *const a.GfxNativeBootInfo) callconv(.c) i32 {
    if (context == 1) held_native_probe.old_restores += 1 else held_native_probe.native_restores += 1;
    return 1; // This fixture never changes scanout or admits GPU DMA.
}
fn heldNativeCommit(_: u64, _: u64, boot: *const a.GfxNativeBootInfo) callconv(.c) i32 {
    held_native_probe.commits += 1;
    if (boot.width != held_native_probe.boot.width or boot.height != held_native_probe.boot.height) return 0;
    const bytes = @as(u64, boot.width) * boot.height * 4;
    var mapped: a.GfxBufferMap = .{};
    if (cached.bufferMap(&held_native_probe.shadow, a.gfx_buffer_map_read, 0, bytes, &mapped) != ok) return 0;
    defer _ = cached.bufferUnmap(&mapped.lease);
    const source: [*]const u8 = @ptrFromInt(held_native_probe.source);
    const target: [*]const u8 = @ptrFromInt(mapped.cpu_address);
    const row = @as(usize, boot.width) * 4;
    for (0..boot.height) |y| {
        if (!std.mem.eql(u8, source[y * boot.pitch ..][0..row], target[y * row ..][0..row])) return 0;
    }
    return held_native_probe.commit_result;
}
fn heldNative(memory: anytype, ctx: *r4os.r4dev.DriverContext, display: *const r4os.driver_display.Context, boot: *const a.GfxNativeBootInfo, adapter: u32) bool {
    const queues = ctx.graphicsQueue() orelse return failure(ctx, @src().line);
    const outputs = ctx.graphicsOutputs() orelse return failure(ctx, @src().line);
    var binding: a.GfxBackendBinding = .{};
    if (queues.register(&.{ .adapter_id = adapter, .milestone = a.gfx_queue_milestone_device_execution, .notify_callback = @intFromPtr(&heldNativeNotify) }, &binding) != a.gfx_queue_ok) return failure(ctx, @src().line);
    defer _ = queues.unregister(&binding, 1);
    var publication = a.GfxOutputPublication{ .backend = binding, .info = .{
        .identity = .{ .adapter_id = adapter, .connector_id = 1, .device_generation = binding.device_generation },
        .connector_kind = a.gfx_output_kind_virtual, .flags = a.gfx_output_flag_connected,
        .mode_count = 1, .preferred_mode_id = 1, .possible_heads = 1, .possible_planes = 1, .possible_plls = 1,
        .limits = .{ .head_mask = 1, .plane_mask = 1, .pll_mask = 1, .max_width = boot.width, .max_height = boot.height } } };
    publication.modes[0] = .{ .mode_id = 1, .width = boot.width, .height = boot.height, .flags = a.gfx_output_mode_geometry_only | a.gfx_output_mode_preferred };
    var output: a.GfxOutputId = .{};
    if (outputs.publish(&publication, &output) != a.gfx_output_ok) return failure(ctx, @src().line);
    const bytes = @as(u64, boot.pitch) * boot.height;
    var snapshot: a.GfxBufferReference = .{};
    if (memory.bufferCreate(&.{ .byte_length = bytes, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &snapshot) != ok) return failure(ctx, @src().line);
    defer if (snapshot.reference.id != 0) { _ = memory.bufferRelease(&snapshot.reference); };
    var shadow: a.GfxBufferReference = .{};
    if (memory.bufferCreate(&.{ .byte_length = @as(u64, boot.width) * boot.height * 4, .width = boot.width, .height = boot.height,
        .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{ @as(u64, boot.width) * 4, 0, 0, 0 },
        .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source }, &shadow) != ok) return failure(ctx, @src().line);
    defer if (shadow.reference.id != 0) { _ = memory.bufferRelease(&shadow.reference); };
    var held: a.GfxNativeState = .{};
    if (display.bootHold(&.{ .adapter_id = adapter, .generation = boot.generation, .reference = snapshot.reference,
        .context = 1, .restore_callback = @intFromPtr(&heldNativeRestore) }, &held) != a.gfx_output_ok or held.retained != 1) return failure(ctx, @src().line);
    defer if (held.retained != 0) { var cleanup: a.GfxNativeState = .{}; _ = display.bootFinish(held.generation, 2, &cleanup); };
    var read: a.GfxBufferMap = .{};
    if (memory.bufferMap(&snapshot.reference, a.gfx_buffer_map_read, 0, bytes, &read) != ok) return failure(ctx, @src().line);
    defer _ = memory.bufferUnmap(&read.lease);
    held_native_probe = .{ .shadow = shadow.reference, .source = read.cpu_address, .boot = boot.* };
    if (memory.bufferRelease(&snapshot.reference) != ok) return failure(ctx, @src().line);
    snapshot = .{};
    var candidate = a.GfxNativeRegistration{ .backend = binding, .output = output, .reference = shadow.reference,
        .context = 2, .commit_callback = @intFromPtr(&heldNativeCommit), .restore_callback = @intFromPtr(&heldNativeRestore) };
    @memcpy(candidate.name[0..7], "EXAMPLE");
    var state: a.GfxNativeState = .{};
    const short_native: extern struct { version: u32 = 1, size: u32 = 8 } align(8) = .{};
    if (display.prepareHeld(@ptrCast(&short_native), held.generation, &state) != a.gfx_output_error_invalid or
        display.prepare(@ptrCast(&short_native), &state) != a.gfx_output_error_invalid) return failure(ctx, @src().line);
    if (display.prepareHeld(&candidate, held.generation, &state) != a.gfx_output_error_invalid or
        display.bootFinish(held.generation, 1, &state) != a.gfx_output_ok) return failure(ctx, @src().line);
    if (display.prepare(&candidate, &state) != a.gfx_output_error_busy or
        display.prepareHeld(&candidate, held.generation + 1, &state) != a.gfx_output_error_stale) return failure(ctx, @src().line);
    var native_pending = false;
    defer if (native_pending) {
        var current: a.GfxNativeBootInfo = .{};
        if (display.bootInfo(&current) == a.gfx_output_ok) _ = display.transition(if (current.state == 2) held.generation else current.generation, if (current.state == 2) 1 else 2, &state);
    };
    if (display.prepareHeld(&candidate, held.generation, &state) != a.gfx_output_ok or state.generation != held.generation) return failure(ctx, @src().line);
    native_pending = true;
    if (display.bootFinish(held.generation, 2, &state) != a.gfx_output_error_busy or
        display.transition(held.generation, 1, &state) != a.gfx_output_ok or state.outcome != a.gfx_output_outcome_old_preserved or state.retained != 1 or state.state != 2) return failure(ctx, @src().line);
    native_pending = false;
    if (display.prepareHeld(&candidate, held.generation, &state) != a.gfx_output_ok) return failure(ctx, @src().line);
    native_pending = true;
    if (display.transition(held.generation, 0, &state) != a.gfx_output_ok or state.outcome != a.gfx_output_outcome_old_preserved or state.retained != 1 or state.state != 2) return failure(ctx, @src().line);
    native_pending = false;
    if (display.prepareHeld(&candidate, held.generation, &state) != a.gfx_output_ok) return failure(ctx, @src().line);
    native_pending = true;
    held_native_probe.commit_result = 1;
    if (display.transition(held.generation, 0, &state) != a.gfx_output_ok or state.outcome != a.gfx_output_outcome_applied or state.state != a.display_state_software_native) return failure(ctx, @src().line);
    if (memory.bufferRelease(&shadow.reference) != ok) return failure(ctx, @src().line);
    shadow = .{};
    if (display.transition(state.generation, 2, &state) != a.gfx_output_ok or state.retained != 0 or state.state != a.display_state_bootfb or
        held_native_probe.commits != 2 or held_native_probe.native_restores != 1 or held_native_probe.old_restores != 0) return failure(ctx, @src().line);
    native_pending = false;
    held.retained = 0;
    ctx.logInfo("EXAMPLE.R4D held-native result: OK prefix=56 tail=64 stale=rejected abort=held old-preserved=held RAM-shadow=exact recovery=native references=balanced GPU-commands=none");
    return true;
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
    return memory.mmioMap(&invalid, &window) == a.err_no_fn and window.handle.id == 0 and memory.collect() == ok;
}

fn failure(ctx: *const r4os.r4dev.DriverContext, line: u32) bool {
    var buffer: [96]u8 = undefined;
    const text = @import("std").fmt.bufPrintZ(&buffer, "EXAMPLE.R4D gfx-memory failed line={d}", .{line}) catch unreachable;
    ctx.logError(text);
    return false;
}

fn failureCode(ctx: *const r4os.r4dev.DriverContext, line: u32) i32 {
    _ = failure(ctx, line);
    return -1;
}
