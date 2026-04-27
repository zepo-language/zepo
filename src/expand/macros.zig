//! Macro expansion: quasiquote desugaring.
//! Macro transformer calls are handled in eval.zig (needs VM context).

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const HandleScope = gc_mod.HandleScope;

const runtime = @import("../runtime/mod.zig");
const SymbolTable = runtime.SymbolTable;
const objects = runtime.objects;

pub fn expand(v: Value, symbols: *SymbolTable, gc: *GC) anyerror!Value {
    return expandForm(v, symbols, gc);
}

fn expandForm(v: Value, symbols: *SymbolTable, gc: *GC) anyerror!Value {
    if (!value_mod.isPtr(v)) return v;
    if (!objects.isPair(v)) return v;

    const head = objects.pairCar(v).*;
    if (objects.isSymbol(head)) {
        const name = objects.symbolName(head);
        // Stop at quote — don't expand inside quoted data.
        if (std.mem.eql(u8, name, "quote")) return v;
        if (std.mem.eql(u8, name, "quasiquote")) {
            const rest = objects.pairCdr(v).*;
            if (!objects.isPair(rest)) return error.InvalidSpecialForm;
            const template = objects.pairCar(rest).*;
            return expandQQ(template, symbols, gc);
        }
    }

    return expandList(v, symbols, gc);
}

fn expandList(v: Value, symbols: *SymbolTable, gc: *GC) anyerror!Value {
    if (!objects.isPair(v)) return v;

    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const car = objects.pairCar(v).*;
    const cdr = objects.pairCdr(v).*;
    const exp_car = try expandForm(car, symbols, gc);
    const car_slot = scope.push(exp_car);
    const exp_cdr = try expandList(cdr, symbols, gc);
    const cdr_slot = scope.push(exp_cdr);
    return objects.makePair(gc, car_slot.*, cdr_slot.*);
}

// Expand a quasiquote template (one level).
fn expandQQ(template: Value, symbols: *SymbolTable, gc: *GC) anyerror!Value {
    if (!objects.isPair(template)) {
        return makeQuote(template, symbols, gc);
    }

    const head = objects.pairCar(template).*;
    const tail = objects.pairCdr(template).*;

    // (unquote expr) → expr  (evaluated at call site)
    if (objects.isSymbol(head) and std.mem.eql(u8, objects.symbolName(head), "unquote")) {
        if (!objects.isPair(tail)) return error.InvalidSpecialForm;
        return objects.pairCar(tail).*;
    }

    // ((unquote-splicing expr) . rest) → (append expr (expandQQ rest))
    if (objects.isPair(head)) {
        const hcar = objects.pairCar(head).*;
        if (objects.isSymbol(hcar) and
            std.mem.eql(u8, objects.symbolName(hcar), "unquote-splicing"))
        {
            const splice_tail = objects.pairCdr(head).*;
            if (!objects.isPair(splice_tail)) return error.InvalidSpecialForm;
            const splice_expr = objects.pairCar(splice_tail).*;
            var scope = HandleScope{};
            gc.roots.pushHandleScope(&scope);
            defer gc.roots.popHandleScope();
            const splice_slot = scope.push(splice_expr);
            const rest_exp = try expandQQ(tail, symbols, gc);
            const rest_slot = scope.push(rest_exp);
            return makeCall2(symbols, gc, "append", splice_slot.*, rest_slot.*);
        }
    }

    // (head . tail) → (cons (expandQQ head) (expandQQ tail))
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const exp_head = try expandQQ(head, symbols, gc);
    const h_slot = scope.push(exp_head);
    const exp_tail = try expandQQ(tail, symbols, gc);
    const t_slot = scope.push(exp_tail);
    return makeCall2(symbols, gc, "cons", h_slot.*, t_slot.*);
}

fn makeQuote(val: Value, symbols: *SymbolTable, gc: *GC) !Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const q = try symbols.intern("quote");
    const q_slot = scope.push(q);
    const v_slot = scope.push(val);
    const inner = try objects.makePair(gc, v_slot.*, value_mod.NIL);
    const inner_slot = scope.push(inner);
    return objects.makePair(gc, q_slot.*, inner_slot.*);
}

fn makeCall2(symbols: *SymbolTable, gc: *GC, sym_name: []const u8, a: Value, b: Value) !Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const fn_sym = try symbols.intern(sym_name);
    const fn_slot = scope.push(fn_sym);
    const a_slot = scope.push(a);
    const b_slot = scope.push(b);
    const b_cons = try objects.makePair(gc, b_slot.*, value_mod.NIL);
    const b_slot2 = scope.push(b_cons);
    const a_cons = try objects.makePair(gc, a_slot.*, b_slot2.*);
    const a_slot2 = scope.push(a_cons);
    return objects.makePair(gc, fn_slot.*, a_slot2.*);
}
