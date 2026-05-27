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

// zepo-4d6: fiber handles are their own GC kind (.fiber), not foreign objects.
// The handle carries the terminal status+result so the FiberState can be freed
// (reaped) the instant the fiber completes; see runtime/objects.zig.

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
    const fs = vm.fibers.items[fiber_idx].?;

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

    // zepo-4d6: wrap the state in a .fiber handle and back-link it so the
    // scheduler can write the terminal result into the handle on completion.
    const handle = objects.makeFiber(vm.gc, fs) catch return error.OutOfMemory;
    fs.handle = handle;
    return handle;
}

// ── helpers ────────────────────────────────────────────────────────────────────
// zepo-4d6: resolve the live FiberState behind a handle (valid only while the
// fiber is still running; null once it has completed and been reaped).
fn getFiber(v: Value) LispError!*FiberState {
    if (!objects.isFiber(v)) return error.TypeError;
    const ptr = objects.fiberFsPtr(v) orelse return error.ContractViolation;
    return @ptrCast(@alignCast(ptr));
}

// ── (fiber? v) → bool ─────────────────────────────────────────────────────────
pub fn primFiberQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return if (objects.isFiber(args[0])) value_mod.TRUE else value_mod.FALSE;
}

// ── (fiber-done? handle) → bool ───────────────────────────────────────────────
pub fn primFiberDoneQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isFiber(args[0])) return error.TypeError;
    return if (objects.fiberStatus(args[0]) == objects.FIBER_DONE) value_mod.TRUE else value_mod.FALSE;
}

// ── (fiber-errored? handle) → bool ────────────────────────────────────────────
pub fn primFiberErroredQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isFiber(args[0])) return error.TypeError;
    return if (objects.fiberStatus(args[0]) == objects.FIBER_ERRORED) value_mod.TRUE else value_mod.FALSE;
}

// ── (fiber-result handle) → value ─────────────────────────────────────────────
pub fn primFiberResult(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isFiber(args[0])) return error.TypeError;
    return switch (objects.fiberStatus(args[0])) {
        objects.FIBER_DONE, objects.FIBER_ERRORED => objects.fiberResult(args[0]),
        else => error.ContractViolation, // still running
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
    if (!objects.isFiber(args[0])) return error.TypeError;

    switch (objects.fiberStatus(args[0])) {
        objects.FIBER_DONE => return objects.fiberResult(args[0]),
        objects.FIBER_ERRORED => return error.UserError,
        else => { // still running — register as a waiter and park
            const fs = try getFiber(args[0]);
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
