// zepo-0bo: fiber-related primitives
// zepo-i19: spawn thunk, fiber-join, fiber query primitives
const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const LispError = runtime.LispError;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const frame_mod = @import("../vm/frame.zig");
const sched_mod = @import("../vm/sched.zig");
const fiber_mod = @import("../vm/fiber.zig");
const FiberState = fiber_mod.FiberState;

// zepo-i19: type tag for fiber foreign handles.
// Payload is *FiberState (system-allocated, not GC-managed).
pub const TAG_FIBER: u64 = 0xF1BE_0000_0001;

// ── (yield) → #void ───────────────────────────────────────────────────────────
pub fn primYield(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    vm.yield_requested = true;
    return value_mod.NIL;
}

// ── (spawn thunk) → fiber-handle ──────────────────────────────────────────────
pub fn primSpawn(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const thunk = args[0];
    if (!objects.isClosure(thunk)) return error.TypeError;
    if (objects.closureArity(thunk) != 0) return error.ArityMismatch;

    const fn_id = objects.closureCodePtr(thunk);
    if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
    const func = vm.compiled_fns[@intCast(fn_id)]; // zepo-nhl

    const fiber_idx = try vm.addFiber();
    const fs = vm.fibers.items[fiber_idx];

    // Temporarily swap fiber's (empty) call_stack into vm to push the entry frame.
    const saved_cs = vm.call_stack;
    vm.call_stack = fs.call_stack;
    try vm.call_stack.pushFast(.{
        .func = func,
        .pc = 0,
        .base = 0,
        .caller_base = 0,
        .closure_val = thunk,
        .dst_reg = frame_mod.outermost_sentinel,
    }, func.num_regs);
    // Thunk has no args; no setupCallArgs needed.
    fs.call_stack = vm.call_stack;
    vm.call_stack = saved_cs;

    const sched = vm.scheduler orelse return error.ContractViolation;
    try sched.enqueue(fiber_idx);

    return try objects.makeForeign(vm.gc, fs, null, TAG_FIBER);
}

// ── helpers ────────────────────────────────────────────────────────────────────
fn getFiber(v: Value) LispError!*FiberState {
    if (!objects.isForeign(v)) return error.TypeError;
    if (objects.foreignTypeTag(v) != TAG_FIBER) return error.TypeError;
    const ptr = objects.foreignPayload(v) orelse return error.ContractViolation;
    return @ptrCast(@alignCast(ptr));
}

// ── (fiber? v) → bool ─────────────────────────────────────────────────────────
pub fn primFiberQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const is = objects.isForeign(args[0]) and objects.foreignTypeTag(args[0]) == TAG_FIBER;
    return if (is) value_mod.TRUE else value_mod.FALSE;
}

// ── (fiber-done? handle) → bool ───────────────────────────────────────────────
pub fn primFiberDoneQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const fs = try getFiber(args[0]);
    return if (fs.status == .done) value_mod.TRUE else value_mod.FALSE;
}

// ── (fiber-errored? handle) → bool ────────────────────────────────────────────
pub fn primFiberErroredQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const fs = try getFiber(args[0]);
    return if (fs.status == .errored) value_mod.TRUE else value_mod.FALSE;
}

// ── (fiber-result handle) → value ─────────────────────────────────────────────
pub fn primFiberResult(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const fs = try getFiber(args[0]);
    return switch (fs.status) {
        .done => fs.result,
        .errored => fs.error_val,
        else => error.ContractViolation,
    };
}

// ── (sleep seconds) → #void ───────────────────────────────────────────────────
// zepo-8pc: Parks the current fiber for the given duration (fractional seconds
// allowed). Uses park_on_yield so pc advances — no re-execution on resume.
pub fn primSleep(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const sched = vm.scheduler orelse return error.ContractViolation;

    const ms: i64 = if (value_mod.isFixnum(args[0]))
        @as(i64, value_mod.fixnumVal(args[0])) * 1000
    else if (objects.isFloat(args[0]))
        @intFromFloat(@max(0.0, objects.floatVal(args[0])) * 1000.0)
    else
        return error.TypeError;

    const my_idx: usize = if (vm.current_fiber_idx == 0)
        sched_mod.MAIN_FIBER
    else
        vm.current_fiber_idx - 1;

    const wake_ms = sched_mod.nowMs() + ms;
    try sched.sleepFiber(my_idx, wake_ms);
    vm.yield_requested = true;
    vm.block_on_yield = true;
    vm.park_on_yield = true;
    return value_mod.NIL;
}

// ── (fiber-join handle) → value ───────────────────────────────────────────────
// Suspends the current fiber until target completes; returns target's result.
// On resume (woken by scheduler after target finishes), re-checks status.
pub fn primFiberJoin(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const fs = try getFiber(args[0]);

    switch (fs.status) {
        .done => return fs.result,
        .errored => return error.UserError,
        .runnable, .blocked => {
            const my_sched_idx: usize = if (vm.current_fiber_idx == 0)
                sched_mod.MAIN_FIBER
            else
                vm.current_fiber_idx - 1;
            try fs.waiters.append(fs.allocator, my_sched_idx);
            // Blocking yield: scheduler saves but does NOT re-enqueue us.
            vm.yield_requested = true;
            vm.block_on_yield = true;
            return value_mod.NIL;
        },
    }
}
