// sched.mc — two cooperative tasks and the context switch (M39,
// docs/specs/M39.md § 4).
//
// THE SWITCH IS TWO INSTRUCTIONS. That is not a shortcut; it is what the RISC-V
// machine's frame contract buys, and it is worth writing down because the spec
// priced this at "~25 #opcode words swapping ra/sp/s0..s11":
//
//   * `s1..s11`, `gp` and `tp` are never written by generated code
//     (examples/kernel/README.md § The ABI, asserted by test.sh over the whole
//     kernel's `--dump-asm`), so a switch does not have to save them;
//   * every function opens with an UNCONDITIONAL `sd ra,8(sp); sd s0,0(sp)`, so
//     the return address and the caller's frame base of a suspended task are
//     already on that task's own stack;
//   * the epilogue starts with `mv sp, s0`, so sp is DERIVED from s0.
//
// Swapping s0 therefore swaps the whole machine state that matters: the
// epilogue of `ctx_switch` releases the other task's frame, reloads the other
// task's ra and s0 from the other task's stack, and returns onto it.
//
//     ctx_switch:
//       addi sp, sp, -16      \
//       sd   ra, 8(sp)         |  the compiler's prologue: it saves exactly the
//       sd   s0, 0(sp)         |  two registers a switch would have had to save
//       mv   s0, sp            |
//       addi sp, sp, -16      /   (the frame for two parameters)
//       sd   a0, -8(s0)           MTASK_PARAM, a0/a1 untouched by the prologue
//       sd   a1, -16(s0)
//       sd   s0, 0(a0)        <-  the two #opcode words: park this task
//       ld   s0, 0(a1)        <-  and adopt the other
//       mv   sp, s0           \
//       ld   ra, 8(sp)         |  the compiler's epilogue, now running on the
//       ld   s0, 0(sp)         |  OTHER task's stack
//       addi sp, sp, 16        |
//       ret                   /
//
// A task that has never run is started by fabricating that record by hand
// (`task_start`): a two-word frame at the top of its stack holding its entry
// point where the epilogue expects a return address.

#define RV_S0_R  8                       // s0 / fp
#define RV_A0_R 10
#define RV_A1_R 11

#define TASK_STACK 4096

// One saved frame base per task, and which one is running. Two tasks is the
// whole scheduler: the point is the switch, not the policy.
i64 task_frame_a = 0;
i64 task_frame_b = 0;
i64 task_cur = 0;                        // 0 = a (kmain), 1 = b
u8  task_stack_b[TASK_STACK];

// sd s0, 0(a0) / ld s0, 0(a1) -- the register numbers are fixed because the
// parameters arrive in a0 and a1 and the prologue does not touch them.
#opcode op_sd_s0_a0() 0x00003023 | (RV_S0_R << 20) | (RV_A0_R << 15)
#opcode op_ld_s0_a1() 0x00003003 | (RV_A1_R << 15) | (RV_S0_R << 7)

void ctx_switch(uptr save_here, uptr load_here) {
    op_sd_s0_a0();
    op_ld_s0_a1();
}

// Fabricate the frame `ctx_switch`'s epilogue will pop: the entry point where a
// return address would be, a zero where the caller's s0 would be, and the slot
// pointing at the pair. The stack top has to be 16-byte aligned, which a
// zerofill global is (glob_place rounds every one to 16).
void task_start(uptr slot, uptr stack_top, uptr entry) {
    uptr f = stack_top - 16;
    st64(f + 8, entry);
    st64(f, 0);
    st64(slot, f);
}

void task_init_b(uptr entry) {
    task_start(&task_frame_b, task_stack_b + TASK_STACK, entry);
}

// The `yield;` statement examples/kernel/kernel_syntax.mc teaches expands to
// this call. It is an ordinary function: the switch happens inside ctx_switch's
// epilogue, so this frame stays on the stack of the task being suspended and is
// still there when it is resumed.
void yield_now() {
    if (task_cur == 0) {
        task_cur = 1;
        ctx_switch(&task_frame_a, &task_frame_b);
        return;
    }
    task_cur = 0;
    ctx_switch(&task_frame_b, &task_frame_a);
}
