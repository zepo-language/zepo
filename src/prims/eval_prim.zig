// zepo-ksw
//! (eval form) — compile and run an s-expr Value in the current VM's
//! top-level global environment. Synchronous only (see evalFormNested).
const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const runtime = @import("../runtime/mod.zig");
const LispError = runtime.LispError;
const EvalContext = runtime.EvalContext;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

pub fn primEval(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    // The VM carries a back-pointer to its EvalContext as do_import_ctx
    // (set in eval.zig). Cast it back to reach the compile pipeline.
    const ctx_opaque = vm.do_import_ctx orelse return error.ContractViolation;
    const ctx: *EvalContext = @ptrCast(@alignCast(ctx_opaque));
    return ctx.evalFormNested(args[0]) catch |e| switch (e) {
        // Normalize the internal control-flow error into a user-facing one.
        error.FiberYielded => error.ContractViolation,
        // evalFormNested has an inferred (global) error set; every error it
        // actually produces is a LispError member, so narrow it explicitly.
        else => |narrow| @as(LispError, @errorCast(narrow)),
    };
}
