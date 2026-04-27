//! Macro-system operations on EvalContext: defmacro registration and
//! recursive macro expansion (including quasiquote walk).

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_mod = @import("../gc/collector.zig");
const HandleScope = gc_mod.HandleScope;

const runtime_objects = @import("objects.zig");
const eval = @import("eval.zig");
const EvalContext = eval.EvalContext;

pub fn evalDefmacro(ctx: *EvalContext, form: Value) !Value {
    const objs = runtime_objects;
    // form = (defmacro name params body...)
    const rest = objs.pairCdr(form).*;
    if (!objs.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objs.pairCar(rest).*;
    if (!objs.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = objs.symbolName(name_v);

    // Build (lambda params body...) from the cdr of rest.
    const lambda_tail = objs.pairCdr(rest).*;
    const lambda_sym = try ctx.symbols.intern("lambda");
    const lambda_form = try objs.makePair(ctx.gc, lambda_sym, lambda_tail);

    // Evaluate the lambda to obtain a closure Value.
    const closure = try ctx.evalNonModuleForm(lambda_form);

    // Store closure in globals so the GC can reach it.
    const sym = try ctx.symbols.intern(name);
    try ctx.currentEnv().define(sym, closure);

    // Register the name as a macro.
    const name_copy = try ctx.allocator.dupe(u8, name);
    try ctx.macro_names.put(name_copy, {});

    return value_mod.NIL;
}

/// Walk `form`, expanding macro calls and quasiquotes.
pub fn macroExpand(ctx: *EvalContext, form: Value) anyerror!Value {
    const objs = runtime_objects;
    if (!value_mod.isPtr(form)) return form;
    if (!objs.isPair(form)) return form;

    const head = objs.pairCar(form).*;

    // Don't expand inside quoted forms.
    if (objs.isSymbol(head) and std.mem.eql(u8, objs.symbolName(head), "quote"))
        return form;

    if (objs.isSymbol(head)) {
        const name = objs.symbolName(head);
        if (ctx.macro_names.contains(name)) {
            // Collect unevaluated argument forms.
            var args = std.ArrayListUnmanaged(Value){};
            defer args.deinit(ctx.allocator);
            var cur = objs.pairCdr(form).*;
            while (!value_mod.isNil(cur)) {
                if (!objs.isPair(cur)) break;
                try args.append(ctx.allocator, objs.pairCar(cur).*);
                cur = objs.pairCdr(cur).*;
            }
            // Look up the transformer from the active env.
            const sym = try ctx.symbols.intern(name);
            const transformer = ctx.currentEnv().lookup(sym) orelse
                ctx.globals.lookup(sym) orelse
                return error.UnboundVariable;
            // Call the transformer with unevaluated args.
            const result = try ctx.vm.?.callValue(transformer, args.items);
            // Re-expand: macros may expand to other macro calls.
            return macroExpand(ctx, result);
        }
    }

    // Recurse into all subforms.
    return macroExpandList(ctx, form);
}

pub fn macroExpandList(ctx: *EvalContext, form: Value) anyerror!Value {
    const objs = runtime_objects;
    if (!objs.isPair(form)) return form;
    const orig_car = objs.pairCar(form).*;
    const orig_cdr = objs.pairCdr(form).*;

    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    const exp_car = try macroExpand(ctx, orig_car);
    const car_slot = scope.push(exp_car);
    const exp_cdr = try macroExpandList(ctx, orig_cdr);
    const cdr_slot = scope.push(exp_cdr);

    // Return original if nothing changed (avoids allocation when no macros present).
    if (exp_car == orig_car and exp_cdr == orig_cdr) return form;

    return objs.makePair(ctx.gc, car_slot.*, cdr_slot.*);
}
