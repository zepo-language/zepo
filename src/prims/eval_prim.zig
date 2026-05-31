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
const reader = @import("../reader/mod.zig");
const objects = runtime.objects;

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

// zepo-dheb: (read-from-string STR) — parses ONE s-expr out of STR and
// returns the resulting Value. Used by load-doctests to lift harvested
// EXPRESSION/EXPECTED strings into evaluable forms.
// zepo-uney: (%set-binding-doc! SYMBOL STRING) — attach a docstring to a
// top-level binding in the current env. Implements the storage side of the
// :documentation keyword on define / define-syntax / define-module. The
// parser desugars
//
//   (define foo :documentation "..." VAL)
//   =>
//   (begin (define foo VAL) (%set-binding-doc! 'foo "..."))
//
// so this primitive runs after the define has placed the binding.
pub fn primSetBindingDoc(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    if (!objects.isString(args[1])) return error.TypeError;
    const doc = objects.stringBytes(args[1]);
    vm.globals.setDocstring(args[0], doc) catch return error.OutOfMemory;
    return abi.value.NIL;
}

pub fn primReadFromString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const src = objects.stringBytes(args[0]);

    const ctx_opaque = vm.do_import_ctx orelse return error.ContractViolation;
    const ctx: *EvalContext = @ptrCast(@alignCast(ctx_opaque));

    var spans = reader.SpanTable.init(ctx.allocator);
    defer spans.deinit();
    var parser = reader.Parser.init(vm.gc, ctx.symbols, &spans, src, "<read-from-string>", ctx.allocator);
    defer parser.deinit();
    return parser.readOne() catch |e| switch (e) {
        error.Eof => return error.ContractViolation,
        else => return error.ContractViolation,
    };
}
