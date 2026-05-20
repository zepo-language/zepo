// zepo-0bo: fiber-related primitives
const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const LispError = runtime.LispError;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

// ── (yield) → #void ───────────────────────────────────────────────────────────
// Cooperatively yield the current fiber's time slice back to the scheduler.
// The fiber is re-enqueued as runnable; execution resumes from the next opcode.
pub fn primYield(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    vm.yield_requested = true;
    return value_mod.NIL;
}
