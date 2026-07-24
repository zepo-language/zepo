// zepo-ajf: syntax-rules hygienic pattern-based macro transformers.
//
// Implements R7RS-style (syntax-rules (literals...) (pattern template) ...)
// transformers. The transformer value IS the (syntax-rules ...) list stored in
// the global env; no separate allocation is needed.
//
// Hygiene: variables that appear in *binding positions* inside templates (i.e.
// the binders of let/let*/letrec/lambda/define forms) and are not pattern
// variables or literals are renamed to fresh gensym names at expansion time.
// This prevents macro-introduced bindings from capturing use-site variables.
// References to those same freshly-named variables within the binding's scope
// are also rewritten consistently. Free variable *references* in templates
// (e.g. `if`, `begin`, `display`) are left intact so they resolve to globals.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const objects = @import("objects.zig");
const symbols_mod = @import("symbols.zig");
const SymbolTable = symbols_mod.SymbolTable;
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const HandleScope = gc_mod.HandleScope;

// ── helpers ────────────────────────────────────────────────────────────────

fn symEq(v: Value, name: []const u8) bool {
    return objects.isSymbol(v) and std.mem.eql(u8, objects.symbolName(v), name);
}

fn isEllipsis(v: Value) bool {
    return symEq(v, "...");
}

/// Return the head symbol name of a list, or null.
fn headSym(v: Value) ?[]const u8 {
    if (!objects.isPair(v)) return null;
    const h = objects.pairCar(v).*;
    if (!objects.isSymbol(h)) return null;
    return objects.symbolName(h);
}

// ── Bindings (pattern variable → matched Value / []Value) ──────────────────

pub const Bindings = struct {
    /// Scalar bindings: pattern variable bound to a single Value.
    scalar: std.StringHashMapUnmanaged(Value) = .empty,
    /// Ellipsis bindings: pattern variable bound to a list of Values.
    list: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Value)) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bindings {
        return .{ .allocator = allocator };
    }

    pub fn deinit(b: *Bindings) void {
        var it = b.list.valueIterator();
        while (it.next()) |lst| lst.deinit(b.allocator);
        b.list.deinit(b.allocator);
        b.scalar.deinit(b.allocator);
    }

    pub fn putScalar(b: *Bindings, name: []const u8, val: Value) anyerror!void {
        try b.scalar.put(b.allocator, name, val);
    }

    pub fn putEllipsis(b: *Bindings, name: []const u8) anyerror!void {
        if (!b.list.contains(name)) {
            try b.list.put(b.allocator, name, .empty);
        }
    }

    pub fn appendEllipsis(b: *Bindings, name: []const u8, val: Value) anyerror!void {
        const entry = b.list.getPtr(name) orelse return error.UnboundPatternVar;
        try entry.append(b.allocator, val);
    }

    pub fn isPatternVar(b: *const Bindings, name: []const u8) bool {
        return b.scalar.contains(name) or b.list.contains(name);
    }

    pub fn getScalar(b: *const Bindings, name: []const u8) ?Value {
        return b.scalar.get(name);
    }

    pub fn getList(b: *const Bindings, name: []const u8) ?[]Value {
        if (b.list.getPtr(name)) |l| return l.items;
        return null;
    }
};

// ── Pattern matching ───────────────────────────────────────────────────────

/// Match `form` against `pattern` given `literals`.
/// Populates `bindings` on success. Returns false on mismatch.
pub fn matchPattern(
    pattern: Value,
    form: Value,
    literals: Value, // linked list of literal symbols
    bindings: *Bindings,
) anyerror!bool {
    // _ matches anything with no binding.
    if (symEq(pattern, "_")) return true;

    if (objects.isSymbol(pattern)) {
        // Check if pattern symbol is a literal.
        if (isLiteral(pattern, literals)) {
            // Must match the exact same symbol in form.
            if (!objects.isSymbol(form)) return false;
            return std.mem.eql(u8, objects.symbolName(pattern), objects.symbolName(form));
        }
        // Pattern variable: bind to form.
        try bindings.putScalar(objects.symbolName(pattern), form);
        return true;
    }

    if (objects.isPair(pattern)) {
        // Check for ellipsis pattern: (head-pat ...) or (p1 p2 ... . rest)
        const pat_car = objects.pairCar(pattern).*;
        const pat_cdr = objects.pairCdr(pattern).*;

        // Is pat_cdr a pair whose car is `...`?
        if (objects.isPair(pat_cdr) and isEllipsis(objects.pairCar(pat_cdr).*)) {
            const after_ellipsis = objects.pairCdr(pat_cdr).*;
            // Count how many elements are after the ellipsis.
            const tail_len = listLength(after_ellipsis);
            // Collect the symbols that pat_car binds so we can init lists.
            try initEllipsisBindings(pat_car, literals, bindings);
            // Match the tail of form against after_ellipsis.
            const form_len = listLength(form);
            if (form_len < tail_len) return false;
            const ellipsis_count = form_len - tail_len;
            // Match ellipsis_count elements against pat_car.
            var cur_form = form;
            var i: usize = 0;
            while (i < ellipsis_count) : (i += 1) {
                if (!objects.isPair(cur_form)) return false;
                var sub = Bindings.init(bindings.allocator);
                defer sub.deinit();
                const ok = try matchPattern(pat_car, objects.pairCar(cur_form).*, literals, &sub);
                if (!ok) return false;
                // Merge sub scalar bindings into ellipsis lists.
                var sit = sub.scalar.iterator();
                while (sit.next()) |kv| {
                    try bindings.appendEllipsis(kv.key_ptr.*, kv.value_ptr.*);
                }
                cur_form = objects.pairCdr(cur_form).*;
            }
            // Match tail.
            return matchListTail(after_ellipsis, cur_form, literals, bindings);
        }

        // Normal pair: form must also be a pair.
        if (!objects.isPair(form)) return false;
        const ok_car = try matchPattern(pat_car, objects.pairCar(form).*, literals, bindings);
        if (!ok_car) return false;
        return matchPattern(pat_cdr, objects.pairCdr(form).*, literals, bindings);
    }

    // Literal non-symbol datum: must equal form exactly.
    if (value_mod.isFixnum(pattern)) return pattern == form;
    if (value_mod.isNil(pattern)) return value_mod.isNil(form);
    if (pattern == value_mod.TRUE or pattern == value_mod.FALSE) return pattern == form;
    return false;
}

fn matchListTail(
    pattern: Value,
    form: Value,
    literals: Value,
    bindings: *Bindings,
) anyerror!bool {
    if (value_mod.isNil(pattern)) return value_mod.isNil(form);
    if (!objects.isPair(pattern)) return matchPattern(pattern, form, literals, bindings);
    if (!objects.isPair(form)) return false;
    const ok = try matchPattern(objects.pairCar(pattern).*, objects.pairCar(form).*, literals, bindings);
    if (!ok) return false;
    return matchListTail(objects.pairCdr(pattern).*, objects.pairCdr(form).*, literals, bindings);
}

/// Collect all pattern variables introduced by `pat_car` (a sub-pattern before
/// `...`) and pre-initialize their ellipsis list slots.
fn initEllipsisBindings(pat: Value, literals: Value, bindings: *Bindings) anyerror!void {
    if (symEq(pat, "_")) return;
    if (objects.isSymbol(pat)) {
        if (!isLiteral(pat, literals)) {
            try bindings.putEllipsis(objects.symbolName(pat));
        }
        return;
    }
    if (objects.isPair(pat)) {
        try initEllipsisBindings(objects.pairCar(pat).*, literals, bindings);
        try initEllipsisBindings(objects.pairCdr(pat).*, literals, bindings);
    }
}

fn isLiteral(sym: Value, literals: Value) bool {
    var cur = literals;
    while (objects.isPair(cur)) {
        if (objects.isSymbol(objects.pairCar(cur).*)) {
            if (std.mem.eql(u8, objects.symbolName(sym), objects.symbolName(objects.pairCar(cur).*)))
                return true;
        }
        cur = objects.pairCdr(cur).*;
    }
    return false;
}

fn listLength(v: Value) usize {
    var n: usize = 0;
    var cur = v;
    while (objects.isPair(cur)) : (cur = objects.pairCdr(cur).*) n += 1;
    return n;
}

// ── Hygiene: rename binding-site identifiers ────────────────────────────────

/// Rename map: maps original symbol name → fresh gensym Value.
/// Built lazily: a fresh name is created on first encounter of each binder.
pub const RenameMap = struct {
    map: std.StringHashMapUnmanaged(Value) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(r: *RenameMap) void {
        r.map.deinit(r.allocator);
    }

    pub fn getOrCreate(r: *RenameMap, name: []const u8, syms: *SymbolTable) anyerror!Value {
        if (r.map.get(name)) |v| return v;
        const fresh = try syms.gensym(name);
        try r.map.put(r.allocator, name, fresh);
        return fresh;
    }

    pub fn get(r: *const RenameMap, name: []const u8) ?Value {
        return r.map.get(name);
    }
};

/// Walk `template` and rename binding-site identifiers (those in let/lambda/
/// define binders) that are not pattern variables. Returns the rewritten template.
///
/// `bindings`: current pattern variable set (to exclude from renaming).
/// `rename`: accumulates fresh names; caller owns and reuses across the template.
pub fn applyHygiene(
    template: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    // Rewrite symbol references that are in scope of a renamed binder.
    if (objects.isSymbol(template)) return rewriteSymRef(template, rename);
    if (!objects.isPair(template)) return template;

    const hd = headSym(template);

    // (lambda (params...) body...)
    if (hd != null and (std.mem.eql(u8, hd.?, "lambda") or std.mem.eql(u8, hd.?, "λ"))) {
        return rewriteLambda(template, bindings, rename, syms, gc);
    }

    // (let ((var val) ...) body...)  / (let* ...) / (letrec ...)
    if (hd != null and (std.mem.eql(u8, hd.?, "let") or
        std.mem.eql(u8, hd.?, "let*") or
        std.mem.eql(u8, hd.?, "letrec") or
        std.mem.eql(u8, hd.?, "letrec*")))
    {
        // Handle named-let: (let name ((var val) ...) body...)
        const after_let = objects.pairCdr(template).*;
        if (objects.isPair(after_let) and objects.isSymbol(objects.pairCar(after_let).*)) {
            // named-let: the loop name is also a binder
            return rewriteNamedLet(template, bindings, rename, syms, gc);
        }
        return rewriteLet(template, bindings, rename, syms, gc);
    }

    // (define (name params...) body...) or (define name value)
    if (hd != null and std.mem.eql(u8, hd.?, "define")) {
        const after_define = objects.pairCdr(template).*;
        if (objects.isPair(after_define)) {
            const name_v = objects.pairCar(after_define).*;
            // (define (name params...) body...)
            if (objects.isPair(name_v)) {
                return rewriteFunDefine(template, bindings, rename, syms, gc);
            }
            // (define name value) — the name itself is a binder in the outer scope.
            // We don't rename top-level defines inside macros (they'd escape the
            // scope anyway), so only recurse into the value.
            const val_pair = objects.pairCdr(after_define).*;
            if (!objects.isPair(val_pair)) return template;
            var scope = HandleScope{};
            gc.roots.pushHandleScope(&scope);
            defer gc.roots.popHandleScope();
            const new_val_slot = scope.push(try applyHygiene(
                objects.pairCar(val_pair).*,
                bindings, rename, syms, gc,
            ));
            const nil_slot = scope.push(value_mod.NIL);
            const new_val_pair = scope.push(try objects.makePairFromSlots(gc, new_val_slot, nil_slot));
            const name_slot = scope.push(name_v);
            const bindings_pair = scope.push(try objects.makePairFromSlots(gc, name_slot, new_val_pair));
            const kw_slot = scope.push(objects.pairCar(template).*);
            return objects.makePairFromSlots(gc, kw_slot, bindings_pair);
        }
        return template;
    }

    // Default: recurse into car and cdr.
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const car_slot = scope.push(objects.pairCar(template).*);
    const cdr_slot = scope.push(objects.pairCdr(template).*);
    car_slot.* = try applyHygiene(car_slot.*, bindings, rename, syms, gc);
    cdr_slot.* = try applyHygiene(cdr_slot.*, bindings, rename, syms, gc);
    return objects.makePairFromSlots(gc, car_slot, cdr_slot);
}

fn renameSymIfBinder(
    sym: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
) anyerror!Value {
    const name = objects.symbolName(sym);
    // zepo-aua: never rename the ellipsis marker — it's a syntactic token
    // that the template expander needs to see literally to recognize
    // ellipsis patterns like (var ...).
    if (std.mem.eql(u8, name, "...")) return sym;
    if (bindings.isPatternVar(name)) return sym; // pattern var, don't rename
    return rename.getOrCreate(name, syms);
}

fn rewriteSymRef(sym: Value, rename: *const RenameMap) Value {
    const name = objects.symbolName(sym);
    return rename.get(name) orelse sym;
}

fn rewriteLambda(
    tmpl: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    // (lambda params body...)
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const kw = scope.push(objects.pairCar(tmpl).*); // "lambda"
    const rest = objects.pairCdr(tmpl).*;
    if (!objects.isPair(rest)) return tmpl;
    const params_v = objects.pairCar(rest).*;
    const body = objects.pairCdr(rest).*;

    // Build a child rename map that extends the parent.
    var child_rename = RenameMap{ .allocator = rename.allocator };
    defer child_rename.deinit();
    // Copy parent renames.
    var it = rename.map.iterator();
    while (it.next()) |kv| try child_rename.map.put(child_rename.allocator, kv.key_ptr.*, kv.value_ptr.*);

    // Rename parameters.
    const new_params_slot = scope.push(try renameParamList(params_v, bindings, &child_rename, syms, gc));
    // Rewrite body with child rename.
    const new_body_slot = scope.push(try applyHygiene(body, bindings, &child_rename, syms, gc));
    // Rebuild: (lambda new-params . new-body)
    const inner = scope.push(try objects.makePairFromSlots(gc, new_params_slot, new_body_slot));
    return objects.makePairFromSlots(gc, kw, inner);
}

fn renameParamList(
    params: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    if (value_mod.isNil(params)) return params;
    if (objects.isSymbol(params)) {
        // Rest parameter (dotted list).
        return renameSymIfBinder(params, bindings, rename, syms);
    }
    if (!objects.isPair(params)) return params;
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const sym_slot = scope.push(objects.pairCar(params).*);
    if (objects.isSymbol(sym_slot.*)) {
        sym_slot.* = try renameSymIfBinder(sym_slot.*, bindings, rename, syms);
    }
    const rest_slot = scope.push(try renameParamList(objects.pairCdr(params).*, bindings, rename, syms, gc));
    return objects.makePairFromSlots(gc, sym_slot, rest_slot);
}

fn rewriteLet(
    tmpl: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    // (let ((var val) ...) body...)
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const kw = scope.push(objects.pairCar(tmpl).*);
    const rest = objects.pairCdr(tmpl).*;
    if (!objects.isPair(rest)) return tmpl;
    const bind_list = objects.pairCar(rest).*;
    const body = objects.pairCdr(rest).*;

    var child_rename = RenameMap{ .allocator = rename.allocator };
    defer child_rename.deinit();
    var it = rename.map.iterator();
    while (it.next()) |kv| try child_rename.map.put(child_rename.allocator, kv.key_ptr.*, kv.value_ptr.*);

    // Rewrite binding list.
    const is_let_star = if (headSym(tmpl)) |h| std.mem.eql(u8, h, "let*") else false;
    const new_bind_slot = scope.push(try rewriteLetBindings(
        bind_list, bindings, rename, &child_rename, is_let_star, syms, gc,
    ));
    // Rewrite body using child_rename.
    const new_body_slot = scope.push(try applyHygiene(body, bindings, &child_rename, syms, gc));
    const inner = scope.push(try objects.makePairFromSlots(gc, new_bind_slot, new_body_slot));
    return objects.makePairFromSlots(gc, kw, inner);
}

/// Rewrite let binding list. For plain `let`, rename vars AFTER processing all
/// init-vals (so vals see outer scope). For `let*`, rename vars one by one so
/// each init-val sees prior bindings.
fn rewriteLetBindings(
    bindings_list: Value,
    pat_bindings: *const Bindings,
    outer_rename: *const RenameMap,
    inner_rename: *RenameMap,
    is_star: bool,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    if (value_mod.isNil(bindings_list)) return bindings_list;
    if (!objects.isPair(bindings_list)) return bindings_list;

    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const binding = objects.pairCar(bindings_list).*;
    if (!objects.isPair(binding)) return bindings_list;
    const var_sym = objects.pairCar(binding).*;
    const val_rest = objects.pairCdr(binding).*;
    const val = if (objects.isPair(val_rest)) objects.pairCar(val_rest).* else value_mod.NIL;

    // Init-val sees outer scope (or inner so-far for let*).
    const val_rename: *const RenameMap = if (is_star) inner_rename else outer_rename;
    const new_val_slot = scope.push(try applyHygiene(val, pat_bindings, @constCast(val_rename), syms, gc));

    // Rename the var.
    const new_var_slot = scope.push(if (objects.isSymbol(var_sym))
        try renameSymIfBinder(var_sym, pat_bindings, inner_rename, syms)
    else
        var_sym);

    // Rebuild this binding: (new_var new_val).
    const nil_slot = scope.push(value_mod.NIL);
    const val_pair = scope.push(try objects.makePairFromSlots(gc, new_val_slot, nil_slot));
    const this_binding = scope.push(try objects.makePairFromSlots(gc, new_var_slot, val_pair));

    // Recurse for the rest.
    const rest_slot = scope.push(try rewriteLetBindings(
        objects.pairCdr(bindings_list).*,
        pat_bindings, outer_rename, inner_rename, is_star, syms, gc,
    ));
    return objects.makePairFromSlots(gc, this_binding, rest_slot);
}

fn rewriteNamedLet(
    tmpl: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const kw = scope.push(objects.pairCar(tmpl).*);
    const rest = objects.pairCdr(tmpl).*;
    if (!objects.isPair(rest)) return tmpl;
    const loop_name = objects.pairCar(rest).*;
    const rest2 = objects.pairCdr(rest).*;
    if (!objects.isPair(rest2)) return tmpl;

    var child_rename = RenameMap{ .allocator = rename.allocator };
    defer child_rename.deinit();
    var it = rename.map.iterator();
    while (it.next()) |kv| try child_rename.map.put(child_rename.allocator, kv.key_ptr.*, kv.value_ptr.*);

    // Rename the loop name.
    const new_loop_slot = scope.push(if (objects.isSymbol(loop_name))
        try renameSymIfBinder(loop_name, bindings, &child_rename, syms)
    else
        loop_name);

    const bind_list = objects.pairCar(rest2).*;
    const body = objects.pairCdr(rest2).*;
    const new_bind_slot = scope.push(try rewriteLetBindings(
        bind_list, bindings, rename, &child_rename, false, syms, gc,
    ));
    const new_body_slot = scope.push(try applyHygiene(body, bindings, &child_rename, syms, gc));

    const bind_body = scope.push(try objects.makePairFromSlots(gc, new_bind_slot, new_body_slot));
    const with_loop = scope.push(try objects.makePairFromSlots(gc, new_loop_slot, bind_body));
    return objects.makePairFromSlots(gc, kw, with_loop);
}

fn rewriteFunDefine(
    tmpl: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    // (define (name params...) body...)
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const kw = scope.push(objects.pairCar(tmpl).*);
    const rest = objects.pairCdr(tmpl).*;
    if (!objects.isPair(rest)) return tmpl;
    const sig = objects.pairCar(rest).*;
    const body = objects.pairCdr(rest).*;

    // Don't rename `name` (it defines a new global); DO rename params.
    var child_rename = RenameMap{ .allocator = rename.allocator };
    defer child_rename.deinit();
    var it = rename.map.iterator();
    while (it.next()) |kv| try child_rename.map.put(child_rename.allocator, kv.key_ptr.*, kv.value_ptr.*);

    const new_sig_slot = scope.push(try renameParamList(sig, bindings, &child_rename, syms, gc));
    const new_body_slot = scope.push(try applyHygiene(body, bindings, &child_rename, syms, gc));
    const inner = scope.push(try objects.makePairFromSlots(gc, new_sig_slot, new_body_slot));
    return objects.makePairFromSlots(gc, kw, inner);
}

// ── Template expansion ─────────────────────────────────────────────────────

/// Expand `template` with `bindings`, applying hygiene renaming. Returns the
/// expanded Value.
pub fn expandTemplate(
    template: Value,
    bindings: *const Bindings,
    rename: *RenameMap,
    syms: *SymbolTable,
    gc: *GC,
) anyerror!Value {
    // Symbol: check rename map first, then pattern variable substitution.
    if (objects.isSymbol(template)) {
        // Hygiene rewrite: if the symbol was renamed by applyHygiene, use fresh name.
        if (rename.get(objects.symbolName(template))) |fresh| return fresh;
        // Pattern variable substitution.
        if (bindings.getScalar(objects.symbolName(template))) |v| return v;
        // Free reference: left as-is.
        return template;
    }

    if (!objects.isPair(template)) return template; // number, bool, etc.

    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Check for ellipsis: (tmpl-car ...) or (tmpl-car ... . rest)
    const t_car = scope.push(objects.pairCar(template).*);
    const t_cdr = scope.push(objects.pairCdr(template).*);

    if (objects.isPair(t_cdr.*) and isEllipsis(objects.pairCar(t_cdr.*).*)) {
        const after_ellipsis = objects.pairCdr(t_cdr.*).*;
        // zepo-bn0a: an ellipsis template may reference MORE THAN ONE
        // ellipsis-bound variable — e.g. (cons k v) ... — and they are iterated
        // together in lockstep. The old code drove iteration off the first var
        // only and left the others bound to their list form, so a sibling like
        // `v` leaked out of the macro as an unbound symbol.
        var evars = std.ArrayListUnmanaged([]const u8).empty;
        defer evars.deinit(bindings.allocator);
        try collectEllipsisVars(t_car.*, bindings, &evars);
        if (evars.items.len == 0) return error.BadEllipsisTemplate;
        // All driving lists come from the same ellipsis group and so share a
        // length; disagreement means an ill-formed ellipsis template.
        const count = (bindings.getList(evars.items[0]) orelse return error.BadEllipsisTemplate).len;
        for (evars.items) |ev| {
            const l = bindings.getList(ev) orelse return error.BadEllipsisTemplate;
            if (l.len != count) return error.EllipsisCountMismatch;
        }
        // Expand t_car once per element, overriding EVERY ellipsis var.
        const tail_slot = scope.push(try expandTemplate(after_ellipsis, bindings, rename, syms, gc));
        // Build list in reverse.
        const acc_slot = scope.push(tail_slot.*);
        var k: usize = count;
        while (k > 0) {
            k -= 1;
            var iter_bindings = Bindings.init(bindings.allocator);
            defer iter_bindings.deinit();
            // Copy scalar bindings, then override each ellipsis var with its
            // k-th element for this iteration.
            var sit = bindings.scalar.iterator();
            while (sit.next()) |kv| try iter_bindings.scalar.put(iter_bindings.allocator, kv.key_ptr.*, kv.value_ptr.*);
            for (evars.items) |ev| {
                const l = bindings.getList(ev).?;
                try iter_bindings.scalar.put(iter_bindings.allocator, ev, l[k]);
            }
            const expanded = scope.push(try expandTemplate(t_car.*, &iter_bindings, rename, syms, gc));
            acc_slot.* = try objects.makePairFromSlots(gc, expanded, acc_slot);
        }
        return acc_slot.*;
    }

    // Normal pair: expand car and cdr.
    t_car.* = try expandTemplate(t_car.*, bindings, rename, syms, gc);
    t_cdr.* = try expandTemplate(t_cdr.*, bindings, rename, syms, gc);
    return objects.makePairFromSlots(gc, t_car, t_cdr);
}

/// Find the first symbol in `tmpl` that is an ellipsis-bound pattern variable.
fn findEllipsisVar(tmpl: Value, bindings: *const Bindings) ?[]const u8 {
    if (objects.isSymbol(tmpl)) {
        const name = objects.symbolName(tmpl);
        if (bindings.list.contains(name)) return name;
        return null;
    }
    if (objects.isPair(tmpl)) {
        if (findEllipsisVar(objects.pairCar(tmpl).*, bindings)) |n| return n;
        return findEllipsisVar(objects.pairCdr(tmpl).*, bindings);
    }
    return null;
}

/// zepo-bn0a: collect every distinct ellipsis-bound pattern variable appearing
/// in `tmpl`. All of them drive one ellipsis expansion in lockstep, so an
/// ellipsis template like (cons k v) ... substitutes both k and v.
fn collectEllipsisVars(
    tmpl: Value,
    bindings: *const Bindings,
    out: *std.ArrayListUnmanaged([]const u8),
) anyerror!void {
    if (objects.isSymbol(tmpl)) {
        const name = objects.symbolName(tmpl);
        if (bindings.list.contains(name)) {
            for (out.items) |e| if (std.mem.eql(u8, e, name)) return;
            try out.append(bindings.allocator, name);
        }
        return;
    }
    if (objects.isPair(tmpl)) {
        try collectEllipsisVars(objects.pairCar(tmpl).*, bindings, out);
        try collectEllipsisVars(objects.pairCdr(tmpl).*, bindings, out);
    }
}

// ── Top-level apply: match + expand ───────────────────────────────────────

/// Apply the `(syntax-rules ...)` transformer `sr_form` to `use_form`.
/// Returns the expanded Value on success.
pub fn applySyntaxRules(
    sr_form: Value, // (syntax-rules (lits...) (pat tmpl) ...)
    use_form: Value, // the original macro-call form
    syms: *SymbolTable,
    gc: *GC,
    allocator: std.mem.Allocator,
) anyerror!Value {
    // Parse: (syntax-rules (lits...) clauses...)
    if (!objects.isPair(sr_form)) return error.InvalidSyntaxRules;
    const rest = objects.pairCdr(sr_form).*;
    if (!objects.isPair(rest)) return error.InvalidSyntaxRules;
    const literals = objects.pairCar(rest).*;
    var clauses = objects.pairCdr(rest).*;

    while (objects.isPair(clauses)) {
        const clause = objects.pairCar(clauses).*;
        clauses = objects.pairCdr(clauses).*;
        if (!objects.isPair(clause)) continue;
        const pattern = objects.pairCar(clause).*;
        const tmpl_rest = objects.pairCdr(clause).*;
        if (!objects.isPair(tmpl_rest)) continue;
        const tmpl = objects.pairCar(tmpl_rest).*;

        var bindings = Bindings.init(allocator);
        defer bindings.deinit();

        // The pattern's car is the macro name (or _); skip it by matching
        // the cdr of pattern against the cdr of use_form.
        const pat_args = objects.pairCdr(pattern).*;
        const use_args = objects.pairCdr(use_form).*;

        const matched = try matchPattern(pat_args, use_args, literals, &bindings);
        if (!matched) continue;

        // Hygiene pass: rename binding-site identifiers in the template.
        var rename = RenameMap{ .allocator = allocator };
        defer rename.deinit();
        var scope = HandleScope{};
        gc.roots.pushHandleScope(&scope);
        defer gc.roots.popHandleScope();
        const hygienic_tmpl = scope.push(try applyHygiene(tmpl, &bindings, &rename, syms, gc));

        // Expand template.
        return expandTemplate(hygienic_tmpl.*, &bindings, &rename, syms, gc);
    }
    return error.NoMatchingSyntaxRulesClause;
}
