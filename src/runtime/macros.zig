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
const syntax_rules = @import("syntax_rules.zig"); // zepo-ajf

pub fn evalDefmacro(ctx: *EvalContext, form: Value) !Value {
    const objs = runtime_objects;
    // form = (defmacro name params body...)
    const rest = objs.pairCdr(form).*;
    if (!objs.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objs.pairCar(rest).*;
    if (!objs.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = objs.symbolName(name_v);

    // Build (lambda params body...) from the cdr of rest.
    // Root lambda_tail before intern/makePair which can trigger GC.
    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();
    const tail_slot = scope.push(objs.pairCdr(rest).*);
    const lambda_sym = try ctx.symbols.intern("lambda");
    const sym_slot = scope.push(lambda_sym);
    const form_slot = scope.push(try objs.makePairFromSlots(ctx.gc, sym_slot, tail_slot));

    // Evaluate the lambda to obtain a closure Value.
    const closure_slot = scope.push(try ctx.evalNonModuleForm(form_slot.*));

    // Store closure in globals so the GC can reach it.
    // intern can GC, so use rooted closure_slot.
    const sym = try ctx.symbols.intern(name);
    try ctx.currentEnv().define(sym, closure_slot.*);

    // Register the name as a macro.
    const name_copy = try ctx.allocator.dupe(u8, name);
    try ctx.macro_names.put(name_copy, {});

    return value_mod.NIL;
}

// zepo-ajf ─────────────────────────────────────────────────────────────────

/// Handle (define-syntax name transformer-expr).
/// The transformer-expr is NOT evaluated; it must be a (syntax-rules ...) form.
/// The form is stored directly in the global env so the GC roots it.
pub fn evalDefineSyntax(ctx: *EvalContext, form: Value) !Value {
    const objs = runtime_objects;
    // form = (define-syntax name (syntax-rules ...))
    const rest = objs.pairCdr(form).*;
    if (!objs.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objs.pairCar(rest).*;
    if (!objs.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = objs.symbolName(name_v);
    const sr_rest = objs.pairCdr(rest).*;
    if (!objs.isPair(sr_rest)) return error.InvalidSpecialForm;
    const sr_form = objs.pairCar(sr_rest).*;
    // Validate: must be (syntax-rules ...).
    if (!objs.isPair(sr_form)) return error.InvalidSpecialForm;
    if (!objs.isSymbol(objs.pairCar(sr_form).*)) return error.InvalidSpecialForm;
    if (!std.mem.eql(u8, objs.symbolName(objs.pairCar(sr_form).*), "syntax-rules"))
        return error.InvalidSpecialForm;

    // Store the (syntax-rules ...) form in globals under the macro name.
    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();
    const sr_slot = scope.push(sr_form);
    const sym = try ctx.symbols.intern(name);
    try ctx.currentEnv().define(sym, sr_slot.*);

    // Mark as a macro.
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
            // Collect unevaluated argument forms into a Zig-heap array.
            var args = std.ArrayListUnmanaged(Value).empty;
            defer args.deinit(ctx.allocator);
            var cur = objs.pairCdr(form).*;
            while (!value_mod.isNil(cur)) {
                if (!objs.isPair(cur)) break;
                try args.append(ctx.allocator, objs.pairCar(cur).*);
                cur = objs.pairCdr(cur).*;
            }
            // Root all arg Values before callValue runs the VM (which can GC).
            // extra_roots stores *Value pointers; args.items[i] addresses are
            // stable for the lifetime of this frame since we do no further
            // appends to `args` after this point.
            const prev_extra = ctx.gc.roots.extra.items.len;
            try ctx.gc.roots.extra.ensureUnusedCapacity(ctx.gc.allocator, args.items.len);
            for (args.items) |*arg| ctx.gc.roots.extra.appendAssumeCapacity(arg);
            defer ctx.gc.roots.extra.shrinkRetainingCapacity(prev_extra);

            // Look up the transformer from the active env.
            const sym = try ctx.symbols.intern(name);
            const transformer = ctx.currentEnv().lookup(sym) orelse
                ctx.globals.lookup(sym) orelse
                return error.UnboundVariable;

            // zepo-ajf: if the transformer is a (syntax-rules ...) form,
            // use pattern matching instead of calling a closure.
            if (isSyntaxRulesForm(transformer)) {
                const result = try syntax_rules.applySyntaxRules(
                    transformer, form, ctx.symbols, ctx.gc, ctx.allocator,
                );
                return macroExpand(ctx, result);
            }

            // Call the transformer with unevaluated args (GC-safe: args rooted above).
            const result = try ctx.vm.?.callValue(transformer, args.items);
            // Re-expand: macros may expand to other macro calls.
            return macroExpand(ctx, result);
        }
    }

    // Recurse into all subforms.
    return macroExpandList(ctx, form);
}

/// Returns true if `v` is a (syntax-rules ...) transformer form.
fn isSyntaxRulesForm(v: Value) bool {
    if (!runtime_objects.isPair(v)) return false;
    const hd = runtime_objects.pairCar(v).*;
    if (!runtime_objects.isSymbol(hd)) return false;
    return std.mem.eql(u8, runtime_objects.symbolName(hd), "syntax-rules");
}

pub fn macroExpandList(ctx: *EvalContext, form: Value) anyerror!Value {
    const objs = runtime_objects;
    if (!objs.isPair(form)) return form;

    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    // Root both car and cdr before any recursive call that can trigger GC.
    const car_slot = scope.push(objs.pairCar(form).*);
    const cdr_slot = scope.push(objs.pairCdr(form).*);
    const orig_car = car_slot.*;
    const orig_cdr = cdr_slot.*;
    car_slot.* = try macroExpand(ctx, car_slot.*);
    cdr_slot.* = try macroExpandList(ctx, cdr_slot.*);

    // Return original if nothing changed (avoids allocation when no macros present).
    if (car_slot.* == orig_car and cdr_slot.* == orig_cdr) return form;

    return objs.makePairFromSlots(ctx.gc, car_slot, cdr_slot);
}
