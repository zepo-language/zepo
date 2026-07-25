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
            return expandQQ(template, symbols, gc, 1);
        }
    }

    return expandList(v, symbols, gc);
}

fn expandList(v: Value, symbols: *SymbolTable, gc: *GC) anyerror!Value {
    if (!objects.isPair(v)) return v;

    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Root both car and cdr before any recursive call that can trigger GC.
    const car_slot = scope.push(objects.pairCar(v).*);
    const cdr_slot = scope.push(objects.pairCdr(v).*);
    car_slot.* = try expandForm(car_slot.*, symbols, gc);
    cdr_slot.* = try expandList(cdr_slot.*, symbols, gc);
    return objects.makePairFromSlots(gc, car_slot, cdr_slot);
}

// Expand a quasiquote template. `level` is the quasiquote nesting depth (1 =
// outermost). zepo-y2br: R7RS level tracking — a nested (quasiquote X) raises
// the level and is preserved as data; (unquote X)/(unquote-splicing X) lower it
// and only SUBSTITUTE at level 1, otherwise they too are preserved as data.
fn expandQQ(template: Value, symbols: *SymbolTable, gc: *GC, level: u32) anyerror!Value {
    // zepo-aqwc: a vector template #(...) — expand its elements as if they were
    // a list (so `unquote` and `unquote-splicing` work), then rebuild a vector:
    //   `#(a ,b ,@c)  →  (list->vector `(a ,b ,@c))
    if (objects.isVector(template)) {
        var scope = HandleScope{};
        gc.roots.pushHandleScope(&scope);
        defer gc.roots.popHandleScope();
        const as_list = scope.push(try vectorToList(template, gc));
        const expanded = scope.push(try expandQQ(as_list.*, symbols, gc, level));
        return makeCall1(symbols, gc, "list->vector", expanded.*);
    }
    if (!objects.isPair(template)) {
        return makeQuote(template, symbols, gc);
    }

    const head = objects.pairCar(template).*;
    const tail = objects.pairCdr(template).*;

    if (objects.isSymbol(head)) {
        const hn = objects.symbolName(head);
        // (unquote expr)
        if (std.mem.eql(u8, hn, "unquote")) {
            if (!objects.isPair(tail)) return error.InvalidSpecialForm;
            const operand = objects.pairCar(tail).*;
            if (level == 1) {
                // Substitute: evaluate at the call site. zepo-vmol: desugar
                // inside it too so a nested quasiquote there is expanded.
                return try expandForm(operand, symbols, gc);
            }
            // level > 1: preserve as data → (list 'unquote <expandQQ operand level-1>)
            var scope = HandleScope{};
            gc.roots.pushHandleScope(&scope);
            defer gc.roots.popHandleScope();
            const inner = scope.push(try expandQQ(operand, symbols, gc, level - 1));
            return makeQQTag(symbols, gc, "unquote", inner.*);
        }
        // (quasiquote expr) → raise level, preserve as data
        if (std.mem.eql(u8, hn, "quasiquote")) {
            if (!objects.isPair(tail)) return error.InvalidSpecialForm;
            const operand = objects.pairCar(tail).*;
            var scope = HandleScope{};
            gc.roots.pushHandleScope(&scope);
            defer gc.roots.popHandleScope();
            const inner = scope.push(try expandQQ(operand, symbols, gc, level + 1));
            return makeQQTag(symbols, gc, "quasiquote", inner.*);
        }
    }

    // ((unquote-splicing expr) . rest)
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
            const tail_slot = scope.push(tail);
            if (level == 1) {
                // (append <expandForm splice_expr> <expandQQ rest level>)
                splice_slot.* = try expandForm(splice_slot.*, symbols, gc); // zepo-vmol
                tail_slot.* = try expandQQ(tail_slot.*, symbols, gc, level);
                return makeCall2(symbols, gc, "append", splice_slot.*, tail_slot.*);
            }
            // level > 1: preserve as data →
            //   (cons (list 'unquote-splicing <expandQQ splice level-1>) <expandQQ rest level>)
            splice_slot.* = try expandQQ(splice_slot.*, symbols, gc, level - 1);
            splice_slot.* = try makeQQTag(symbols, gc, "unquote-splicing", splice_slot.*);
            tail_slot.* = try expandQQ(tail_slot.*, symbols, gc, level);
            return makeCall2(symbols, gc, "cons", splice_slot.*, tail_slot.*);
        }
    }

    // (head . tail) → (cons (expandQQ head) (expandQQ tail))
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const h_slot = scope.push(head);
    const t_slot = scope.push(tail);
    h_slot.* = try expandQQ(h_slot.*, symbols, gc, level);
    t_slot.* = try expandQQ(t_slot.*, symbols, gc, level);
    return makeCall2(symbols, gc, "cons", h_slot.*, t_slot.*);
}

// zepo-y2br: build code producing the 2-element data list (TAG INNER), i.e.
//   (cons (quote TAG) (cons INNER (quote ())))
// Used to preserve unquote/unquote-splicing/quasiquote forms as DATA at
// nesting levels > 1.
fn makeQQTag(symbols: *SymbolTable, gc: *GC, tag_name: []const u8, inner: Value) !Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const inner_slot = scope.push(inner);
    const tag_sym = scope.push(try symbols.intern(tag_name));
    const qtag = scope.push(try makeQuote(tag_sym.*, symbols, gc));
    const qnil = scope.push(try makeQuote(value_mod.NIL, symbols, gc));
    const inner_pair = scope.push(try makeCall2(symbols, gc, "cons", inner_slot.*, qnil.*));
    return makeCall2(symbols, gc, "cons", qtag.*, inner_pair.*);
}

fn makeQuote(val: Value, symbols: *SymbolTable, gc: *GC) !Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const q = try symbols.intern("quote");
    const q_slot = scope.push(q);
    const v_slot = scope.push(val);
    const nil_slot = scope.push(value_mod.NIL);
    const inner_slot = scope.push(try objects.makePairFromSlots(gc, v_slot, nil_slot));
    return objects.makePairFromSlots(gc, q_slot, inner_slot);
}

// zepo-aqwc: (sym a) — one-argument call. GC-rooted like makeCall2.
fn makeCall1(symbols: *SymbolTable, gc: *GC, sym_name: []const u8, a: Value) !Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const fn_slot = scope.push(try symbols.intern(sym_name));
    const a_slot = scope.push(a);
    const nil_slot = scope.push(value_mod.NIL);
    const args_slot = scope.push(try objects.makePairFromSlots(gc, a_slot, nil_slot));
    return objects.makePairFromSlots(gc, fn_slot, args_slot);
}

// zepo-aqwc: build a proper list of a vector's elements (forward order). `vec`
// is rooted so makePairFromSlots' GC can't invalidate it mid-walk.
fn vectorToList(vec: Value, gc: *GC) !Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const vec_slot = scope.push(vec);
    const acc = scope.push(value_mod.NIL);
    const elem = scope.push(value_mod.NIL);
    var i: usize = objects.vectorLen(vec_slot.*);
    while (i > 0) {
        i -= 1;
        elem.* = objects.vectorGet(vec_slot.*, i);
        acc.* = try objects.makePairFromSlots(gc, elem, acc);
    }
    return acc.*;
}

fn makeCall2(symbols: *SymbolTable, gc: *GC, sym_name: []const u8, a: Value, b: Value) !Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const fn_sym = try symbols.intern(sym_name);
    const fn_slot = scope.push(fn_sym);
    const a_slot = scope.push(a);
    const b_slot = scope.push(b);
    const nil_slot = scope.push(value_mod.NIL);
    const b_slot2 = scope.push(try objects.makePairFromSlots(gc, b_slot, nil_slot));
    const a_slot2 = scope.push(try objects.makePairFromSlots(gc, a_slot, b_slot2));
    return objects.makePairFromSlots(gc, fn_slot, a_slot2);
}
