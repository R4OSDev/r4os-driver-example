//! Existing test-only EXAMPLE driver: immutable explicit mode, real IRQ0 only.
//! A timer subscriber is not an external-device IRQ. The kernel's normal IRQ
//! FPU owner must restore interrupted data after this valid alternate context.
const r4os = @import("r4os");
var registered = false;
var hits: u32 = 0;
var failures: u32 = 0;
const Seen = extern struct { mxcsr: u32 = 0, cw: u16 = 0, reserved: u16 = 0 };
extern fn r4os_example_fp_scribble(*Seen) callconv(.c) void;
fn irq(number: u8, _: usize) callconv(.c) u32 {
    if (number != 0) return 0;
    var seen: Seen = .{};
    r4os_example_fp_scribble(&seen);
    if (seen.cw != 0x0b7f or seen.mxcsr != 0x5f80) {
        _ = @atomicRmw(u32, &failures, .Add, 1, .monotonic);
    }
    _ = @atomicRmw(u32, &hits, .Add, 1, .release);
    return r4os.abi.irq_result_handled;
}
pub fn start(ctx: *const r4os.r4dev.DriverContext) i32 {
    hits = 0;
    failures = 0;
    if (ctx.irqRegister(0, irq, 0, r4os.abi.irq_flag_shared) != 0) return -1;
    registered = true;
    const begin = ctx.tickCount();
    while (@atomicLoad(u32, &hits, .acquire) == 0 and ctx.tickCount() -% begin < 10) ctx.waitTicks(1);
    if (@atomicLoad(u32, &hits, .acquire) == 0 or @atomicLoad(u32, &failures, .acquire) != 0) {
        _ = stop(ctx);
        return -2;
    }
    ctx.logInfo("EXAMPLE FPU IRQ armed=1 irq=0 alternateCW=0B7F alternateMXCSR=5F80 vectors=16 mmx=8 mode=x87 immutable=yes");
    return 0;
}
pub fn stop(ctx: *const r4os.r4dev.DriverContext) i32 {
    if (registered) {
        const rc = ctx.irqUnregister(0, irq, 0);
        if (rc != 0) return rc;
        registered = false;
    }
    const bad = @atomicLoad(u32, &failures, .acquire);
    if (bad == 0) ctx.logInfo("EXAMPLE FPU IRQ stop: all alternate environments valid; unregister acknowledged");
    return if (bad == 0) 0 else -2;
}

comptime {
    asm (
        \\.text
        \\.p2align 4
        \\.global r4os_example_fp_scribble
        \\.hidden r4os_example_fp_scribble
        \\.type r4os_example_fp_scribble,@function
        \\r4os_example_fp_scribble:
        \\    sub $24,%rsp
        \\    fnstcw 0(%rsp)
        \\    stmxcsr 4(%rsp)
        \\    movw $0x0b7f,8(%rsp)
        \\    movl $0x5f80,12(%rsp)
        \\    fninit
        \\    fldcw 8(%rsp)
        \\    ldmxcsr 12(%rsp)
        \\    fld1
        \\    fld1
        \\    vpcmpeqd %ymm0,%ymm0,%ymm0
        \\    vpcmpeqd %ymm1,%ymm1,%ymm1
        \\    vpcmpeqd %ymm2,%ymm2,%ymm2
        \\    vpcmpeqd %ymm3,%ymm3,%ymm3
        \\    vpcmpeqd %ymm4,%ymm4,%ymm4
        \\    vpcmpeqd %ymm5,%ymm5,%ymm5
        \\    vpcmpeqd %ymm6,%ymm6,%ymm6
        \\    vpcmpeqd %ymm7,%ymm7,%ymm7
        \\    vpcmpeqd %ymm8,%ymm8,%ymm8
        \\    vpcmpeqd %ymm9,%ymm9,%ymm9
        \\    vpcmpeqd %ymm10,%ymm10,%ymm10
        \\    vpcmpeqd %ymm11,%ymm11,%ymm11
        \\    vpcmpeqd %ymm12,%ymm12,%ymm12
        \\    vpcmpeqd %ymm13,%ymm13,%ymm13
        \\    vpcmpeqd %ymm14,%ymm14,%ymm14
        \\    vpcmpeqd %ymm15,%ymm15,%ymm15
        \\    pcmpeqd %mm0,%mm0
        \\    pcmpeqd %mm1,%mm1
        \\    pcmpeqd %mm2,%mm2
        \\    pcmpeqd %mm3,%mm3
        \\    pcmpeqd %mm4,%mm4
        \\    pcmpeqd %mm5,%mm5
        \\    pcmpeqd %mm6,%mm6
        \\    pcmpeqd %mm7,%mm7
        \\    fnstcw 4(%rdi)
        \\    stmxcsr 0(%rdi)
        \\    emms
        \\    fninit
        \\    fldcw 0(%rsp)
        \\    ldmxcsr 4(%rsp)
        \\    vzeroupper
        \\    add $24,%rsp
        \\    ret
        \\.size r4os_example_fp_scribble,.-r4os_example_fp_scribble
        \\.section .note.GNU-stack,"",@progbits
    );
}
