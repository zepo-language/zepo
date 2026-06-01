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

// zepo-acu0: (documentation SYMBOL) — return the docstring attached to a
// top-level binding via :documentation, or #f if none is attached.
//
// Looks the symbol up in the current module env first (where vm.globals
// points), then in fallback_globals (the top-level env) if the binding
// lives outside the current module.
pub fn primDocumentation(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    if (vm.globals.getDocstring(args[0])) |doc| {
        return objects.makeString(vm.gc, doc) catch return error.OutOfMemory;
    }
    if (vm.fallback_globals) |fb| {
        if (fb.getDocstring(args[0])) |doc| {
            return objects.makeString(vm.gc, doc) catch return error.OutOfMemory;
        }
    }
    return abi.value.FALSE;
}

// zepo-rdan: (%global-ref SYMBOL) — current value of the global binding for
// SYMBOL, searching the current module env then the top-level fallback.
// Raises UnboundVariable if no binding exists. Backs the advise/unadvise
// helpers, which must read/write a global named by a runtime symbol (something
// (set! ...) can't do — it resolves names at compile time).
pub fn primGlobalRef(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    if (vm.globals.lookup(args[0])) |v| return v;
    if (vm.fallback_globals) |fb| {
        if (fb.lookup(args[0])) |v| return v;
    }
    return error.UnboundVariable;
}

// zepo-rdan: (%global-set! SYMBOL VALUE) — mutate the EXISTING global binding
// for SYMBOL (current module env, else top-level fallback). Raises
// UnboundVariable if no binding exists — it never creates one (use define for
// that). Global value slots are GC roots, so no write barrier is needed.
pub fn primGlobalSet(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    vm.globals.set(args[0], args[1]) catch {
        if (vm.fallback_globals) |fb| {
            fb.set(args[0], args[1]) catch return error.UnboundVariable;
            return abi.value.NIL;
        }
        return error.UnboundVariable;
    };
    return abi.value.NIL;
}

// zepo-g120: (invoke-restart 'NAME arg...) — transfer control into the most
// recent restart named NAME, applying its clause to the args. Sets up
// vm.pending_restart and returns the internal RestartInvoked signal; the
// dispatch trampoline performs the actual stack transfer.
pub fn primInvokeRestart(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    const want = objects.symbolName(args[0]);
    var i = vm.restart_stack.items.len;
    while (i > 0) {
        i -= 1;
        const rf = vm.restart_stack.items[i];
        if (objects.isSymbol(rf.name) and std.mem.eql(u8, objects.symbolName(rf.name), want)) {
            vm.pending_restart = rf;
            vm.pending_restart_args.clearRetainingCapacity();
            vm.pending_restart_args.appendSlice(vm.allocator, args[1..]) catch return error.OutOfMemory;
            return error.RestartInvoked;
        }
    }
    return error.ContractViolation; // no restart with that name is active
}

// zepo-g120: (compute-restarts) — list of active restart name symbols,
// most-recent first.
pub fn primComputeRestarts(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    var result: Value = abi.value.NIL;
    var i: usize = 0;
    while (i < vm.restart_stack.items.len) : (i += 1) {
        // prepend each from the bottom up → most-recent ends at the head.
        result = objects.makePair(vm.gc, vm.restart_stack.items[i].name, result) catch return error.OutOfMemory;
    }
    return result;
}

// zepo-g120: (find-restart 'NAME) — the name symbol if a restart named NAME is
// active, else #f.
pub fn primFindRestart(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    const want = objects.symbolName(args[0]);
    var i = vm.restart_stack.items.len;
    while (i > 0) {
        i -= 1;
        const rf = vm.restart_stack.items[i];
        if (objects.isSymbol(rf.name) and std.mem.eql(u8, objects.symbolName(rf.name), want)) {
            return args[0];
        }
    }
    return abi.value.FALSE;
}

// zepo-g120: (restart-report 'NAME) — the :report string of the most recent
// restart named NAME, or #f (no such restart / no report).
pub fn primRestartReport(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    const want = objects.symbolName(args[0]);
    var i = vm.restart_stack.items.len;
    while (i > 0) {
        i -= 1;
        const rf = vm.restart_stack.items[i];
        if (objects.isSymbol(rf.name) and std.mem.eql(u8, objects.symbolName(rf.name), want)) {
            return rf.report; // string Value, or NIL if no :report
        }
    }
    return abi.value.FALSE;
}

// zepo-g120: (%set-debugger-hook! FN) — install FN as the last-resort debugger
// invoked at the signal site when a condition has no handler. FN is called as
// (FN condition); it may invoke-restart or return to decline. The REPL sets
// this; non-interactive runs leave it NIL.
pub fn primSetDebuggerHook(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    vm.debugger_hook = args[0];
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
