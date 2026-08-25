const r4os = @import("r4os");

var irq_hits: u32 = 0;
var driver_api: ?*const r4os.r4dev.DriverApi = null;
var irq_work_armed: bool = false;
var irq_work_handle: u32 = 0;
var deferred_work_hits: u32 = 0;
var deferred_work_context: usize = 0;
var work_stress_gate_open: bool = false;
var work_stress_started: bool = false;
var work_stress_mode: bool = false;
var cleanup_stress_started: bool = false;
var storage_state: ExampleStorageState = .{};
var usb_host_state: ExampleUsbHostState = .{};
var storage_bytes: [4096]u8 = .{0} ** 4096;
var storage_backend: r4os.abi.StorageBackend = .{
    .flags = r4os.abi.storage_backend_flag_removable | r4os.abi.storage_backend_flag_writable,
    .source = r4os.abi.storage_backend_source_disk,
    .bus = r4os.abi.storage_backend_bus_ram,
    .sector_size = 512,
    .max_sectors_per_request = 2,
    .queue_depth = 1,
    .timeout_ticks = 50,
    .sector_count = 8,
    .context = &storage_state,
    .read = storageRead,
    .write = storageWrite,
    .flush = storageFlush,
    .shutdown = storageShutdown,
    .status = storageStatus,
};
var usb_host_backend: r4os.abi.UsbHostController = .{
    .flags = r4os.abi.usb_host_flag_port_scan |
        r4os.abi.usb_host_flag_control |
        r4os.abi.usb_host_flag_bulk |
        r4os.abi.usb_host_flag_interrupt |
        r4os.abi.usb_host_flag_poll_fallback,
    .source = r4os.abi.usb_host_source_disk,
    .context = &usb_host_state,
    .port_scan = usbHostPortScan,
    .address_device = usbHostAddressDevice,
    .configure_device = usbHostConfigureDevice,
    .control_transfer = usbHostControlTransfer,
    .bulk_transfer = usbHostBulkTransfer,
    .interrupt_transfer = usbHostInterruptTransfer,
    .reset_port = usbHostResetPort,
    .clear_halt = usbHostEndpointOperation,
    .reset_endpoint = usbHostEndpointOperation,
    .poll = usbHostPoll,
    .shutdown = usbHostShutdown,
    .status = usbHostStatus,
};

const ExampleStorageState = extern struct {
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,
    shutdowns: u64 = 0,
    last_error: u32 = 0,
    last_lba: u64 = 0,
    last_sectors: u32 = 0,
};

const ExampleUsbHostState = extern struct {
    scans: u64 = 0,
    addresses: u64 = 0,
    configurations: u64 = 0,
    controls: u64 = 0,
    bulk_transfers: u64 = 0,
    interrupt_transfers: u64 = 0,
    resets: u64 = 0,
    polls: u64 = 0,
    shutdowns: u64 = 0,
};

comptime {
    asm (r4os.r4dev.driverEntriesAsm("example_init", "example_shutdown"));
}

export fn example_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.DriverContext.init(api);
    driver_api = api;

    ctx.logInfo("EXAMPLE.R4D init");
    ctx.logWarn("EXAMPLE.R4D warning path example");
    ctx.logError("EXAMPLE.R4D error path example");
    if (!ctx.apiCompatible()) {
        ctx.logError("EXAMPLE.R4D driver api mismatch");
        return -3;
    }
    if (ctx.timerFrequency() == 0) {
        ctx.logError("EXAMPLE.R4D timer unavailable");
        return -3;
    }
    const tick_before = ctx.tickCount();
    ctx.waitTicks(1);
    if (ctx.tickCount() - tick_before == 0) {
        ctx.logError("EXAMPLE.R4D wait tick failed");
        return -3;
    }

    const mode = ctx.getOption("EXAMPLE", "mode");
    const workqueue_stress = optionEquals(mode, "workqueue-stress");
    const cleanup_stress = optionEquals(mode, "workqueue-cleanup-stress");
    if (mode[0] != 0) {
        ctx.logInfo("EXAMPLE.R4D option mode is set");
    }

    var dma: r4os.abi.DmaBuffer = .{};
    const dma_result = ctx.allocDmaRegion(8192, 4096, &dma);
    if (dma_result != 0 or dma.phys_addr == 0 or dma.virt_addr == 0 or dma.bytes < 8192) {
        ctx.logError("EXAMPLE.R4D dma region failed");
        return -1;
    }
    ctx.logInfo("EXAMPLE.R4D dma region ok");
    ctx.freeDmaRegion(&dma);

    // Controlled v19 consumer: keep this example backend on the synchronous
    // depth-one adapter, but exercise the complete owner-bound segment-DMA
    // lifetime over its existing module buffer.
    var dma_pin: r4os.abi.DmaPinnedBuffer = .{};
    if (ctx.pinDmaBuffer(storage_bytes[0..], &dma_pin) != 0) {
        ctx.logError("EXAMPLE.R4D dma pin failed");
        return -1;
    }
    var dma_mapping: r4os.abi.DmaMapping = .{};
    const dma_constraints = r4os.abi.DmaConstraints{
        .dma_mask = 0xFFFF_FFFF,
        .boundary = 4096,
        .max_segment_bytes = 4096,
        .alignment = 16,
        .max_segments = 4,
        .flags = r4os.abi.dma_flag_coherent | r4os.abi.dma_flag_allow_bounce,
    };
    if (ctx.mapDmaPinned(&dma_pin, &dma_constraints, r4os.abi.dma_direction_bidirectional, &dma_mapping) != 0 or
        dma_mapping.segment_count == 0 or dma_mapping.segment_count > dma_constraints.max_segments)
    {
        _ = ctx.unpinDmaBuffer(&dma_pin);
        ctx.logError("EXAMPLE.R4D dma segment map failed");
        return -1;
    }
    var segment_index: usize = 0;
    while (segment_index < dma_mapping.segment_count) : (segment_index += 1) {
        const segment = dma_mapping.segments[segment_index];
        if (segment.bytes == 0 or segment.phys_addr > dma_constraints.dma_mask or
            @as(u64, segment.bytes - 1) > dma_constraints.dma_mask - segment.phys_addr)
        {
            _ = ctx.unmapDma(&dma_mapping);
            _ = ctx.unpinDmaBuffer(&dma_pin);
            ctx.logError("EXAMPLE.R4D dma segment bounds failed");
            return -1;
        }
    }
    if (ctx.syncDmaForCpu(&dma_mapping) != 0 or
        ctx.syncDmaForDevice(&dma_mapping) != 0 or
        ctx.unmapDma(&dma_mapping) != 0 or
        ctx.unmapDma(&dma_mapping) == 0 or
        ctx.unpinDmaBuffer(&dma_pin) != 0)
    {
        ctx.logError("EXAMPLE.R4D dma teardown failed");
        return -1;
    }
    ctx.logInfo("EXAMPLE.R4D dma segment lifetime ok");

    var cleanup_dma: r4os.abi.DmaBuffer = .{};
    if (ctx.allocDmaRegion(4096, 4096, &cleanup_dma) == 0) {
        ctx.logInfo("EXAMPLE.R4D dma cleanup owner armed");
    }

    if (!storageContractSmoke(&ctx)) return -4;
    if (!usbHostContractSmoke(&ctx)) return -5;

    var pci_info: r4os.abi.PciDeviceInfo = .{};
    if (ctx.pciFindByClass(0x02, 0x00, 0, &pci_info) >= 0) {
        ctx.logInfo("EXAMPLE.R4D pci net class found");
        _ = ctx.pciReadBar(pci_info, 0);
        var mmio: r4os.abi.MmioRegion = .{};
        if (ctx.pciMapBar(pci_info, 1, 256, 0, &mmio) == 0 and mmio.virt_addr != 0) {
            ctx.logInfo("EXAMPLE.R4D pci mmio map ok");
        }
    }

    irq_hits = 0;
    irq_work_armed = true;
    irq_work_handle = 0;
    deferred_work_hits = 0;
    deferred_work_context = 0;
    if (ctx.irqRegister(0, example_irq, 0, r4os.abi.irq_flag_shared) == 0) {
        const wait_start = ctx.tickCount();
        while (irqHitCount() == 0 and ctx.tickCount() - wait_start < 5) {
            ctx.waitTicks(1);
        }
        var irq_stats: r4os.abi.IrqStats = .{};
        _ = ctx.irqStats(0, &irq_stats);
        if (irqHitCount() == 0 or irq_stats.dispatch_count == 0) {
            ctx.logError("EXAMPLE.R4D irq smoke failed");
            return -2;
        }
        ctx.logInfo("EXAMPLE.R4D irq smoke ok; cleanup owner armed");
    } else {
        ctx.logError("EXAMPLE.R4D irq register failed");
        return -2;
    }
    if (!deferredWorkSmoke(&ctx)) return -6;
    if (workqueue_stress or cleanup_stress) {
        if (!workqueueStressSmoke(&ctx)) return -7;
        work_stress_mode = true;
        if (cleanup_stress) return -8;
    }

    return 0;
}

export fn example_shutdown() callconv(.c) i32 {
    if (work_stress_mode and !armCleanupStress()) return -7;
    driver_api = null;
    return 0;
}

fn example_irq(irq: u8, context: usize) callconv(.c) u32 {
    _ = irq;
    _ = context;
    const hits: *volatile u32 = &irq_hits;
    hits.* +%= 1;
    if (irq_work_armed) {
        irq_work_armed = false;
        if (driver_api) |api| {
            var handle: u32 = 0;
            if (api.driver_work_submit(example_deferred_work, 0x4457_5155, 0, &handle) == 0) {
                const target: *volatile u32 = &irq_work_handle;
                target.* = handle;
            }
        }
    }
    return r4os.abi.irq_result_handled;
}

fn irqHitCount() u32 {
    const hits: *volatile u32 = &irq_hits;
    return hits.*;
}

fn deferredWorkSmoke(ctx: *const r4os.r4dev.DriverContext) bool {
    const wait_start = ctx.tickCount();
    while (workHandle() == 0 and ctx.tickCount() - wait_start < 10) {
        ctx.waitTicks(1);
    }
    const handle = workHandle();
    if (handle == 0) {
        ctx.logError("EXAMPLE.R4D deferred work was not queued from IRQ");
        return false;
    }
    var result: i32 = -99;
    if (ctx.completionWait(handle, 50, &result) != 0 or result != 0) {
        ctx.logError("EXAMPLE.R4D deferred work completion wait failed");
        return false;
    }
    if (deferredWorkHitCount() == 0 or deferred_work_context != 0x4457_5155) {
        ctx.logError("EXAMPLE.R4D deferred work handler failed");
        return false;
    }
    var status: r4os.abi.DriverCompletionStatus = .{};
    if (ctx.completionStatus(handle, &status) != 0 or status.state != r4os.abi.driver_work_state_completed or
        (status.flags & r4os.abi.driver_work_flag_from_irq) == 0)
    {
        ctx.logError("EXAMPLE.R4D deferred work status failed");
        return false;
    }
    if (ctx.completionRelease(handle) != 0) {
        ctx.logError("EXAMPLE.R4D deferred work release failed");
        return false;
    }
    var summary: r4os.abi.DriverWorkSummary = .{};
    if (ctx.workSummary(&summary) != 0 or summary.worker_started == 0 or summary.submitted_from_irq == 0 or
        summary.completed == 0 or summary.waits == 0 or summary.wait_timeouts != 0 or summary.dropped != 0)
    {
        ctx.logError("EXAMPLE.R4D deferred work summary failed");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D deferred work ok");
    return true;
}

fn example_deferred_work(context: usize) callconv(.c) i32 {
    const hits: *volatile u32 = &deferred_work_hits;
    hits.* +%= 1;
    deferred_work_context = context;
    return 0;
}

fn workHandle() u32 {
    const handle: *volatile u32 = &irq_work_handle;
    return handle.*;
}

fn deferredWorkHitCount() u32 {
    const hits: *volatile u32 = &deferred_work_hits;
    return hits.*;
}

fn workqueueStressSmoke(ctx: *const r4os.r4dev.DriverContext) bool {
    @atomicStore(bool, &work_stress_gate_open, false, .release);
    @atomicStore(bool, &work_stress_started, false, .release);

    var handles: [r4os.abi.driver_work_queue_capacity]u32 =
        .{0} ** r4os.abi.driver_work_queue_capacity;
    var handle_count: usize = 0;
    if (ctx.workSubmit(stressBlockingWork, 0, r4os.abi.driver_work_flag_none, &handles[0]) != 0 or handles[0] == 0) {
        ctx.logError("EXAMPLE.R4D work stress blocker submit failed");
        return false;
    }
    handle_count = 1;

    const start_deadline = ctx.tickCount() + 100;
    while (!@atomicLoad(bool, &work_stress_started, .acquire) and ctx.tickCount() < start_deadline) {
        ctx.waitTicks(1);
    }
    if (!@atomicLoad(bool, &work_stress_started, .acquire)) {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D work stress blocker did not start");
        return false;
    }

    var observed_full = false;
    while (handle_count < handles.len) {
        var handle: u32 = 0;
        const rc = ctx.workSubmit(stressSuccessWork, handle_count, r4os.abi.driver_work_flag_none, &handle);
        if (rc == -2) {
            observed_full = true;
            break;
        }
        if (rc != 0 or handle == 0) {
            @atomicStore(bool, &work_stress_gate_open, true, .release);
            ctx.logError("EXAMPLE.R4D work stress fill failed");
            return false;
        }
        handles[handle_count] = handle;
        handle_count += 1;
    }
    if (!observed_full) {
        var rejected_handle: u32 = 0;
        observed_full = ctx.workSubmit(stressSuccessWork, 0, r4os.abi.driver_work_flag_none, &rejected_handle) == -2 and
            rejected_handle == 0;
    }
    if (!observed_full or handle_count < 2) {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D work stress full semantics failed");
        return false;
    }

    const stale_handle = handles[1];
    if (ctx.workCancel(stale_handle) != 0) {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D work stress cancel failed");
        return false;
    }
    var cancelled_result: i32 = 0;
    if (ctx.completionWait(stale_handle, 100, &cancelled_result) != r4os.abi.driver_work_result_cancelled or
        cancelled_result != r4os.abi.driver_work_result_cancelled)
    {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D work stress cancelled wait failed");
        return false;
    }
    var cancelled_status: r4os.abi.DriverCompletionStatus = .{};
    if (ctx.completionStatus(stale_handle, &cancelled_status) != 0 or
        cancelled_status.state != r4os.abi.driver_work_state_cancelled)
    {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D work stress cancelled status failed");
        return false;
    }

    var retained_probe: u32 = 0;
    if (ctx.workSubmit(stressSuccessWork, 0, r4os.abi.driver_work_flag_none, &retained_probe) != -2 or retained_probe != 0) {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D retained completion capacity failed");
        return false;
    }
    if (ctx.completionRelease(stale_handle) != 0) {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D work stress cancelled release failed");
        return false;
    }
    handles[1] = 0;

    var error_handle: u32 = 0;
    if (ctx.workSubmit(stressErrorWork, 0, r4os.abi.driver_work_flag_none, &error_handle) != 0 or error_handle == 0) {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D work stress error submit failed");
        return false;
    }
    var stale_status: r4os.abi.DriverCompletionStatus = .{};
    if (ctx.completionStatus(stale_handle, &stale_status) == 0) {
        @atomicStore(bool, &work_stress_gate_open, true, .release);
        ctx.logError("EXAMPLE.R4D stale work handle accepted");
        return false;
    }

    @atomicStore(bool, &work_stress_gate_open, true, .release);
    var index: usize = 0;
    while (index < handle_count) : (index += 1) {
        const handle = handles[index];
        if (handle == 0) continue;
        var result: i32 = -99;
        if (ctx.completionWait(handle, 500, &result) != 0 or result != 0) {
            ctx.logError("EXAMPLE.R4D work stress completion failed");
            return false;
        }
        var status: r4os.abi.DriverCompletionStatus = .{};
        if (ctx.completionStatus(handle, &status) != 0 or status.state != r4os.abi.driver_work_state_completed or
            ctx.completionRelease(handle) != 0)
        {
            ctx.logError("EXAMPLE.R4D work stress status/release failed");
            return false;
        }
    }

    var error_result: i32 = 0;
    if (ctx.completionWait(error_handle, 500, &error_result) != 0 or error_result != -42) {
        ctx.logError("EXAMPLE.R4D work stress handler error failed");
        return false;
    }
    var error_status: r4os.abi.DriverCompletionStatus = .{};
    if (ctx.completionStatus(error_handle, &error_status) != 0 or
        error_status.state != r4os.abi.driver_work_state_completed or error_status.result != -42 or
        ctx.completionRelease(error_handle) != 0)
    {
        ctx.logError("EXAMPLE.R4D work stress error release failed");
        return false;
    }

    var summary: r4os.abi.DriverWorkSummary = .{};
    if (ctx.workSummary(&summary) != 0 or summary.queue_depth != 0 or summary.active_workers != 0 or
        summary.failed == 0 or summary.cancelled == 0 or summary.dropped < 2)
    {
        ctx.logError("EXAMPLE.R4D work stress summary failed");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D workqueue stress ok");
    return true;
}

fn stressBlockingWork(context: usize) callconv(.c) i32 {
    _ = context;
    @atomicStore(bool, &work_stress_started, true, .release);
    while (!@atomicLoad(bool, &work_stress_gate_open, .acquire)) {
        const api = driver_api orelse return -41;
        const ctx = r4os.r4dev.DriverContext.init(api);
        ctx.waitTicks(1);
    }
    return 0;
}

fn stressSuccessWork(context: usize) callconv(.c) i32 {
    _ = context;
    return 0;
}

fn stressErrorWork(context: usize) callconv(.c) i32 {
    _ = context;
    return -42;
}

fn armCleanupStress() bool {
    const api = driver_api orelse return false;
    const ctx = r4os.r4dev.DriverContext.init(api);
    @atomicStore(bool, &cleanup_stress_started, false, .release);
    var running_handle: u32 = 0;
    if (ctx.workSubmit(cleanupBlockingWork, @intFromPtr(api), r4os.abi.driver_work_flag_none, &running_handle) != 0 or
        running_handle == 0)
    {
        ctx.logError("EXAMPLE.R4D cleanup stress running submit failed");
        return false;
    }
    const start_deadline = ctx.tickCount() + 100;
    while (!@atomicLoad(bool, &cleanup_stress_started, .acquire) and ctx.tickCount() < start_deadline) {
        ctx.waitTicks(1);
    }
    if (!@atomicLoad(bool, &cleanup_stress_started, .acquire)) {
        ctx.logError("EXAMPLE.R4D cleanup stress running work did not start");
        return false;
    }
    var queued_handle: u32 = 0;
    if (ctx.workSubmit(stressSuccessWork, 0, r4os.abi.driver_work_flag_none, &queued_handle) != 0 or queued_handle == 0) {
        ctx.logError("EXAMPLE.R4D cleanup stress queued submit failed");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D cleanup stress armed");
    return true;
}

fn cleanupBlockingWork(raw_api: usize) callconv(.c) i32 {
    const api: *const r4os.r4dev.DriverApi = @ptrFromInt(raw_api);
    const ctx = r4os.r4dev.DriverContext.init(api);
    @atomicStore(bool, &cleanup_stress_started, true, .release);
    ctx.waitTicks(@max(@as(u64, ctx.timerFrequency()) / 10, 1));
    return 0;
}

fn optionEquals(value: [*:0]const u8, expected: []const u8) bool {
    var index: usize = 0;
    while (index < expected.len) : (index += 1) {
        if (value[index] == 0 or optionUpper(value[index]) != optionUpper(expected[index])) return false;
    }
    return value[expected.len] == 0;
}

fn optionUpper(value: u8) u8 {
    if (value >= 'a' and value <= 'z') return value - ('a' - 'A');
    return value;
}

fn storageContractSmoke(ctx: *const r4os.r4dev.DriverContext) bool {
    var invalid_version = storage_backend;
    invalid_version.version = 0;
    if (ctx.registerStorageBackend("EXAMPLE-STOR-BAD", &invalid_version) >= 0) {
        ctx.logError("EXAMPLE.R4D storage invalid descriptor accepted");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D storage invalid descriptor rejected");

    var missing_read = storage_backend;
    missing_read.read = null;
    if (ctx.registerStorageBackend("EXAMPLE-STOR-NOREAD", &missing_read) >= 0) {
        ctx.logError("EXAMPLE.R4D storage missing read accepted");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D storage missing read rejected");

    copyController("EXAMPLE");
    if (ctx.registerStorageBackend("EXAMPLE-STOR", &storage_backend) < 0) {
        ctx.logError("EXAMPLE.R4D storage backend register failed");
        return false;
    }
    if (ctx.registerStorageBackend("EXAMPLE-STOR", &storage_backend) >= 0) {
        ctx.logError("EXAMPLE.R4D storage duplicate accepted");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D storage duplicate rejected");

    if (ctx.storageBackendRecoveryBegin("EXAMPLE-STOR") != 0 or ctx.storageBackendRecoveryFinish("EXAMPLE-STOR", true) != 0) {
        ctx.logError("EXAMPLE.R4D storage recovery contract failed");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D storage backend ok");
    return true;
}

fn usbHostContractSmoke(ctx: *const r4os.r4dev.DriverContext) bool {
    var invalid_version = usb_host_backend;
    invalid_version.version = 0;
    if (ctx.registerUsbHostController("EXAMPLE-USB-BAD", &invalid_version) >= 0) {
        ctx.logError("EXAMPLE.R4D usb host invalid descriptor accepted");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D usb host invalid descriptor rejected");

    var missing_scan = usb_host_backend;
    missing_scan.port_scan = null;
    if (ctx.registerUsbHostController("EXAMPLE-USB-NOSCAN", &missing_scan) >= 0) {
        ctx.logError("EXAMPLE.R4D usb host missing scan accepted");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D usb host missing scan rejected");

    if (ctx.registerUsbHostController("EXAMPLE-USB", &usb_host_backend) < 0) {
        ctx.logError("EXAMPLE.R4D usb host register failed");
        return false;
    }
    if (ctx.registerUsbHostController("EXAMPLE-USB", &usb_host_backend) >= 0) {
        ctx.logError("EXAMPLE.R4D usb host duplicate accepted");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D usb host duplicate rejected");
    if (ctx.unregisterUsbHostController("EXAMPLE-USB") != 0) {
        ctx.logError("EXAMPLE.R4D usb host unregister failed");
        return false;
    }
    if (usb_host_state.shutdowns != 1) {
        ctx.logError("EXAMPLE.R4D usb host shutdown contract failed");
        return false;
    }
    ctx.logInfo("EXAMPLE.R4D usb host backend ok");
    return true;
}

fn copyController(text: []const u8) void {
    @memset(storage_backend.controller[0..], 0);
    const n = if (text.len < storage_backend.controller.len) text.len else storage_backend.controller.len - 1;
    if (n > 0) @memcpy(storage_backend.controller[0..n], text[0..n]);
}

fn storageRead(context: ?*anyopaque, lba: u64, sectors: u32, out: [*]u8, len: u32) callconv(.c) i32 {
    const state = storageState(context) orelse return -1;
    const offset = lba * 512;
    const bytes = @as(u64, sectors) * 512;
    if (offset + bytes > storage_bytes.len or len < bytes) {
        state.last_error = 1;
        return -1;
    }
    @memcpy(out[0..@intCast(bytes)], storage_bytes[@intCast(offset)..@intCast(offset + bytes)]);
    state.reads += 1;
    state.last_error = 0;
    state.last_lba = lba;
    state.last_sectors = sectors;
    return r4os.abi.storage_backend_status_ok;
}

fn storageWrite(context: ?*anyopaque, lba: u64, sectors: u32, data: [*]const u8, len: u32) callconv(.c) i32 {
    const state = storageState(context) orelse return -1;
    const offset = lba * 512;
    const bytes = @as(u64, sectors) * 512;
    if (offset + bytes > storage_bytes.len or len < bytes) {
        state.last_error = 2;
        return -1;
    }
    @memcpy(storage_bytes[@intCast(offset)..@intCast(offset + bytes)], data[0..@intCast(bytes)]);
    state.writes += 1;
    state.last_error = 0;
    state.last_lba = lba;
    state.last_sectors = sectors;
    return r4os.abi.storage_backend_status_ok;
}

fn storageFlush(context: ?*anyopaque) callconv(.c) i32 {
    const state = storageState(context) orelse return -1;
    state.flushes += 1;
    return r4os.abi.storage_backend_status_ok;
}

fn storageShutdown(context: ?*anyopaque) callconv(.c) i32 {
    const state = storageState(context) orelse return -1;
    state.shutdowns += 1;
    return r4os.abi.storage_backend_status_ok;
}

fn storageStatus(context: ?*anyopaque, out: *r4os.abi.StorageBackendStatus) callconv(.c) i32 {
    const state = storageState(context) orelse return -1;
    out.* = .{
        .state = 1,
        .last_error = state.last_error,
        .last_lba = state.last_lba,
        .last_sectors = state.last_sectors,
        .recoveries = 0,
        .recovery_failures = 0,
    };
    return r4os.abi.storage_backend_status_ok;
}

fn storageState(context: ?*anyopaque) ?*ExampleStorageState {
    const raw = context orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn usbHostPortScan(context: ?*anyopaque) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.scans += 1;
    return 0;
}

fn usbHostAddressDevice(context: ?*anyopaque, port: u8, out: *r4os.abi.UsbDeviceHandle) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.addresses += 1;
    out.* = .{ .port = port, .slot_id = 1, .speed = 3 };
    return 0;
}

fn usbHostConfigureDevice(context: ?*anyopaque, _: *const r4os.abi.UsbDeviceHandle, _: u8) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.configurations += 1;
    return 0;
}

fn usbHostControlTransfer(context: ?*anyopaque, device: *const r4os.abi.UsbDeviceHandle, request: *const r4os.abi.UsbControlRequest, buffer: [*]u8, len: u32) callconv(.c) i32 {
    _ = device;
    _ = request;
    _ = buffer;
    _ = len;
    const state = usbHostState(context) orelse return -1;
    state.controls += 1;
    return 0;
}

fn usbHostBulkTransfer(context: ?*anyopaque, _: *const r4os.abi.UsbEndpointHandle, _: [*]u8, len: u32, _: u32) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.bulk_transfers += 1;
    return @intCast(len);
}

fn usbHostInterruptTransfer(context: ?*anyopaque, _: *const r4os.abi.UsbEndpointHandle, _: [*]u8, _: u32, actual: *u32) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.interrupt_transfers += 1;
    actual.* = 0;
    return 0;
}

fn usbHostResetPort(context: ?*anyopaque, _: u8) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.resets += 1;
    return 0;
}

fn usbHostEndpointOperation(context: ?*anyopaque, _: *const r4os.abi.UsbEndpointHandle) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.resets += 1;
    return 0;
}

fn usbHostPoll(context: ?*anyopaque) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.polls += 1;
    return 0;
}

fn usbHostShutdown(context: ?*anyopaque) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    state.shutdowns += 1;
    return 0;
}

fn usbHostStatus(context: ?*anyopaque, out: *r4os.abi.UsbHostStatus) callconv(.c) i32 {
    const state = usbHostState(context) orelse return -1;
    out.* = .{
        .state = 1,
        .source = r4os.abi.usb_host_source_disk,
        .ports = 0,
        .devices = 0,
        .transfers = state.controls + state.bulk_transfers + state.interrupt_transfers,
        .failures = 0,
        .flags = usb_host_backend.flags,
        .queue_depth = 4,
        .max_transfer_bytes = 65_536,
        .completions = state.controls + state.bulk_transfers + state.interrupt_transfers,
        .polls = state.polls,
    };
    return 0;
}

fn usbHostState(context: ?*anyopaque) ?*ExampleUsbHostState {
    const raw = context orelse return null;
    return @ptrCast(@alignCast(raw));
}
