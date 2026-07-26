//! Convert reader output (Value) into typed AST nodes.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const gc_roots = @import("../gc/roots.zig"); // zepo-7fa

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;

const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeId = node_mod.NodeId;
const NodeArena = node_mod.NodeArena;
const LiteralKind = node_mod.LiteralKind;
const CondClause = node_mod.CondClause;
const LetBinding = node_mod.LetBinding;
const Span = node_mod.Span;

const reader_source = @import("../reader/source.zig");
const SpanTable = reader_source.SpanTable;

pub const BuildError = error{
    InvalidSpecialForm,
    ModuleNotAtTopLevel,
    ImportNotAtTopLevel,
    ImportNameMustBeSymbol,
    ExportOutsideModule,
    OutOfMemory,
};

// zepo-uney: Peel a leading `:documentation "STR"` clause from a list form.
// Returns the duped docstring (or null if absent) and the remaining list
// with the keyword pair removed.
fn peelDocumentation(
    arena: *NodeArena,
    form: Value,
) BuildError!struct { doc: ?[]const u8, rest: Value } {
    if (!objects.isPair(form)) return .{ .doc = null, .rest = form };
    const head = objects.pairCar(form).*;
    if (!objects.isSymbol(head)) return .{ .doc = null, .rest = form };
    const name = objects.symbolName(head);
    if (!std.mem.eql(u8, name, ":documentation")) return .{ .doc = null, .rest = form };
    const after = objects.pairCdr(form).*;
    if (!objects.isPair(after)) return BuildError.InvalidSpecialForm;
    const str = objects.pairCar(after).*;
    if (!objects.isString(str)) return BuildError.InvalidSpecialForm;
    const doc_owned = try arena.dupString(objects.stringBytes(str));
    return .{ .doc = doc_owned, .rest = objects.pairCdr(after).* };
}

fn parseKwDefault(v: Value) ?node_mod.KwDefault {
    if (value_mod.isNil(v)) return .{ .nil = {} };
    if (v == value_mod.TRUE) return .{ .boolean = true };
    if (v == value_mod.FALSE) return .{ .boolean = false };
    if (value_mod.isFixnum(v)) return .{ .fixnum = @intCast(value_mod.fixnumVal(v)) };
    if (value_mod.isPtr(v) and objects.isFloat(v)) return .{ .float = objects.floatVal(v) };
    if (value_mod.isPtr(v) and objects.isString(v)) return .{ .string = objects.stringBytes(v) };
    return null;
}

pub const Builder = struct {
    arena: *NodeArena,
    symbols: *SymbolTable,
    allocator: std.mem.Allocator,
    span_table: ?*SpanTable = null,
    current_span: Span = node_mod.dummySpan(),

    pub fn init(arena: *NodeArena, symbols: *SymbolTable, allocator: std.mem.Allocator) Builder {
        return .{ .arena = arena, .symbols = symbols, .allocator = allocator };
    }

    pub fn build(b: *Builder, v: Value) BuildError!NodeId {
        gc_roots.assertLive(v); // zepo-7fa
        return b.buildExpr(v);
    }

    fn buildExpr(b: *Builder, v: Value) BuildError!NodeId {
        if (b.span_table) |st| {
            if (st.get(v)) |sp| b.current_span = sp;
        }
        // Immediates and atoms
        if (value_mod.isNil(v)) {
            return b.arena.add(.{ .literal = .{ .val = .{ .nil = {} }, .span = b.current_span } });
        }
        if (v == value_mod.TRUE) {
            return b.arena.add(.{ .literal = .{ .val = .{ .boolean = true }, .span = b.current_span } });
        }
        if (v == value_mod.FALSE) {
            return b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
        }
        if (value_mod.isFixnum(v)) {
            return b.arena.add(.{ .literal = .{ .val = .{ .fixnum = value_mod.fixnumVal(v) }, .span = b.current_span } });
        }
        if (value_mod.isChar(v)) {
            return b.arena.add(.{ .literal = .{ .val = .{ .character = value_mod.charVal(v) }, .span = b.current_span } });
        }
        if (!value_mod.isPtr(v)) return BuildError.InvalidSpecialForm;

        if (objects.isFloat(v)) {
            return b.arena.add(.{ .literal = .{ .val = .{ .float = objects.floatVal(v) }, .span = b.current_span } });
        }
        // zepo-nfak: a bignum literal self-evaluates (like a number literal).
        if (objects.isBignum(v)) {
            return b.arena.add(.{ .quote = .{ .datum = v, .span = b.current_span } });
        }
        // zepo-or1d: a ratio literal (num/den) self-evaluates.
        if (objects.isRatio(v)) {
            return b.arena.add(.{ .quote = .{ .datum = v, .span = b.current_span } });
        }
        if (objects.isString(v)) {
            const bytes = objects.stringBytes(v);
            const owned = try b.arena.dupString(bytes);
            return b.arena.add(.{ .literal = .{ .val = .{ .string = owned }, .span = b.current_span } });
        }
        if (objects.isSymbol(v)) {
            const name = try b.arena.dupString(objects.symbolName(v));
            return b.arena.add(.{ .sym_ref = .{ .name = name, .span = b.current_span } });
        }
        if (objects.isPair(v)) {
            return b.buildPair(v);
        }
        // zepo-aqwc: a vector literal #(...) is self-quoting — it evaluates to
        // the vector itself, with its elements taken as data (unevaluated).
        if (objects.isVector(v)) {
            return b.arena.add(.{ .quote = .{ .datum = v, .span = b.current_span } });
        }

        return BuildError.InvalidSpecialForm;
    }

    fn buildPair(b: *Builder, pair: Value) BuildError!NodeId {
        const head = objects.pairCar(pair).*;
        if (objects.isSymbol(head)) {
            const name = objects.symbolName(head);
            if (std.mem.eql(u8, name, "quote")) return b.buildQuote(pair);
            if (std.mem.eql(u8, name, "lambda")) return b.buildLambda(pair);
            if (std.mem.eql(u8, name, "define")) return b.buildDefine(pair);
            if (std.mem.eql(u8, name, "set!")) return b.buildSetBang(pair);
            if (std.mem.eql(u8, name, "if")) return b.buildIf(pair);
            if (std.mem.eql(u8, name, "cond")) return b.buildCond(pair);
            if (std.mem.eql(u8, name, "begin")) return b.buildBegin(pair);
            if (std.mem.eql(u8, name, "let")) return b.buildLet(pair);
            if (std.mem.eql(u8, name, "let*")) return b.buildLetStar(pair);
            if (std.mem.eql(u8, name, "letrec")) return b.buildLetrec(pair);
            if (std.mem.eql(u8, name, "and")) return b.buildAnd(pair);
            if (std.mem.eql(u8, name, "or")) return b.buildOr(pair);
            if (std.mem.eql(u8, name, "when")) return b.buildWhen(pair);
            if (std.mem.eql(u8, name, "unless")) return b.buildUnless(pair);
            // zepo-9bi: with-exception-handler is a special form ONLY when
            // the thunk is a literal (lambda () ...). For any other thunk
            // shape we fall through to regular application (the prim still
            // exists as a fallback, with the known yield limitation).
            if (std.mem.eql(u8, name, "with-exception-handler")) {
                if (try b.tryBuildWithHandler(pair)) |node| return node;
            }
            // zepo-6o3p: parameterize is always a special form (no fallback).
            if (std.mem.eql(u8, name, "parameterize")) return b.buildParameterize(pair);
            // zepo-g120: handler-bind / restart-case are always special forms.
            if (std.mem.eql(u8, name, "handler-bind")) return b.buildHandlerBind(pair);
            if (std.mem.eql(u8, name, "restart-case")) return b.buildRestartCase(pair);
            // module/import/export are top-level-only forms handled by the
            // evaluation driver before the builder runs. Encountering one
            // here means it was nested inside another expression.
            if (std.mem.eql(u8, name, "module")) return BuildError.ModuleNotAtTopLevel;
            if (std.mem.eql(u8, name, "import")) return b.buildImport(pair);
            if (std.mem.eql(u8, name, "export")) return BuildError.ExportOutsideModule;
        }
        return b.buildApplication(pair);
    }

    /// (let ((x e1) (y e2)) body...) => ((lambda (x y) body...) e1 e2)
    fn buildLet(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const first = objects.pairCar(rest).*;

        // Named let: (let name ((bindings)...) body...)
        if (objects.isSymbol(first)) {
            return b.buildNamedLet(first, objects.pairCdr(rest).*);
        }

        const bindings_form = first;
        const body_form = objects.pairCdr(rest).*;

        var bindings = std.ArrayListUnmanaged(LetBinding).empty;
        defer bindings.deinit(b.allocator);

        var cur = bindings_form;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const binding = objects.pairCar(cur).*;
            if (!objects.isPair(binding)) return BuildError.InvalidSpecialForm;
            const var_v = objects.pairCar(binding).*;
            if (!objects.isSymbol(var_v)) return BuildError.InvalidSpecialForm;
            const val_rest = objects.pairCdr(binding).*;
            if (!objects.isPair(val_rest)) return BuildError.InvalidSpecialForm;
            const val_v = objects.pairCar(val_rest).*;
            const after = objects.pairCdr(val_rest).*;
            if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;

            const nm = try b.arena.dupString(objects.symbolName(var_v));
            const aid = try b.buildExpr(val_v);
            try bindings.append(b.allocator, .{ .name = nm, .value = aid });

            cur = objects.pairCdr(cur).*;
        }

        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectScopedBody(body_form, &body_ids);

        const bindings_owned = try b.arena.dupBindings(bindings.items);
        const body_owned = try b.arena.dupNodeIds(body_ids.items);

        return b.arena.add(.{ .let_expr = .{
            .bindings = bindings_owned,
            .body = body_owned,
            .span = b.current_span,
        } });
    }

    /// (let name ((x v)...) body...) => letrec-style: ((lambda (name) (set! name (lambda (x...) body...)) (name v...)) #f)
    fn buildNamedLet(b: *Builder, name_sym: Value, rest: Value) BuildError!NodeId {
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const bindings_form = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;

        const loop_name = try b.arena.dupString(objects.symbolName(name_sym));

        var params = std.ArrayListUnmanaged([]const u8).empty;
        defer params.deinit(b.allocator);
        var init_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer init_ids.deinit(b.allocator);

        var cur = bindings_form;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const binding = objects.pairCar(cur).*;
            if (!objects.isPair(binding)) return BuildError.InvalidSpecialForm;
            const var_v = objects.pairCar(binding).*;
            if (!objects.isSymbol(var_v)) return BuildError.InvalidSpecialForm;
            const val_rest = objects.pairCdr(binding).*;
            if (!objects.isPair(val_rest)) return BuildError.InvalidSpecialForm;
            const val_v = objects.pairCar(val_rest).*;
            const after = objects.pairCdr(val_rest).*;
            if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;
            const nm = try b.arena.dupString(objects.symbolName(var_v));
            try params.append(b.allocator, nm);
            const aid = try b.buildExpr(val_v);
            try init_ids.append(b.allocator, aid);
            cur = objects.pairCdr(cur).*;
        }

        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectScopedBody(body_form, &body_ids);

        // Build inner lambda: (lambda (params...) body...)
        const inner_params = try b.arena.dupNames(params.items);
        const inner_body = try b.arena.dupNodeIds(body_ids.items);
        const inner_lambda = try b.arena.add(.{ .lambda = .{
            .params = inner_params,
            .rest_param = null,
            .body = inner_body,
            .span = b.current_span,
        } });

        // Build (set! name inner_lambda)
        const set_id = try b.arena.add(.{ .set_bang = .{
            .name = loop_name,
            .value = inner_lambda,
            .span = b.current_span,
        } });

        // Build (name init-vals...)
        const name_ref = try b.arena.add(.{ .sym_ref = .{ .name = loop_name, .span = b.current_span } });
        const call_args = try b.arena.dupNodeIds(init_ids.items);
        const call_id = try b.arena.add(.{ .application = .{
            .func = name_ref,
            .args = call_args,
            .span = b.current_span,
        } });

        // Outer lambda body: (set! name ...) then (name v...)
        const outer_body_nodes = try b.arena.dupNodeIds(&[_]NodeId{ set_id, call_id });
        const outer_body_seq = try b.arena.add(.{ .sequence = .{
            .exprs = outer_body_nodes,
            .span = b.current_span,
        } });

        // Outer lambda: (lambda (name) outer-body)
        const outer_params = try b.arena.dupNames(&[_][]const u8{loop_name});
        const outer_body = try b.arena.dupNodeIds(&[_]NodeId{outer_body_seq});
        const outer_lambda = try b.arena.add(.{ .lambda = .{
            .params = outer_params,
            .rest_param = null,
            .body = outer_body,
            .span = b.current_span,
        } });

        // Apply outer lambda to #f: ((lambda (name) ...) #f)
        const false_id = try b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
        const outer_args = try b.arena.dupNodeIds(&[_]NodeId{false_id});
        return b.arena.add(.{ .application = .{
            .func = outer_lambda,
            .args = outer_args,
            .span = b.current_span,
        } });
    }

    /// (let* ((x e1) (y e2)) body...) => (let ((x e1)) (let* ((y e2)) body...))
    fn buildLetStar(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const bindings_form = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;

        var bindings = std.ArrayListUnmanaged(LetBinding).empty;
        defer bindings.deinit(b.allocator);

        var cur = bindings_form;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const binding = objects.pairCar(cur).*;
            if (!objects.isPair(binding)) return BuildError.InvalidSpecialForm;
            const var_v = objects.pairCar(binding).*;
            if (!objects.isSymbol(var_v)) return BuildError.InvalidSpecialForm;
            const val_rest = objects.pairCdr(binding).*;
            if (!objects.isPair(val_rest)) return BuildError.InvalidSpecialForm;
            const val_v = objects.pairCar(val_rest).*;
            const after = objects.pairCdr(val_rest).*;
            if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;
            const nm = try b.arena.dupString(objects.symbolName(var_v));
            const aid = try b.buildExpr(val_v);
            try bindings.append(b.allocator, .{ .name = nm, .value = aid });
            cur = objects.pairCdr(cur).*;
        }

        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectScopedBody(body_form, &body_ids);

        const bindings_owned = try b.arena.dupBindings(bindings.items);
        const body_owned = try b.arena.dupNodeIds(body_ids.items);

        return b.arena.add(.{ .let_star_expr = .{
            .bindings = bindings_owned,
            .body = body_owned,
            .span = b.current_span,
        } });
    }

    /// (letrec ((f e1) (g e2)) body...) =>
    ///   (let ((f #f) (g #f))
    ///     (set! f e1)
    ///     (set! g e2)
    ///     body...)
    fn buildLetrec(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const bindings_form = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;

        var names = std.ArrayListUnmanaged([]const u8).empty;
        defer names.deinit(b.allocator);
        var val_exprs = std.ArrayListUnmanaged(Value).empty;
        defer val_exprs.deinit(b.allocator);

        var cur = bindings_form;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const binding = objects.pairCar(cur).*;
            if (!objects.isPair(binding)) return BuildError.InvalidSpecialForm;
            const var_v = objects.pairCar(binding).*;
            if (!objects.isSymbol(var_v)) return BuildError.InvalidSpecialForm;
            const val_rest = objects.pairCdr(binding).*;
            if (!objects.isPair(val_rest)) return BuildError.InvalidSpecialForm;
            const val_v = objects.pairCar(val_rest).*;
            const after = objects.pairCdr(val_rest).*;
            if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;
            const nm = try b.arena.dupString(objects.symbolName(var_v));
            try names.append(b.allocator, nm);
            try val_exprs.append(b.allocator, val_v);
            cur = objects.pairCdr(cur).*;
        }

        // Build the inner body of the let: a sequence of set!s followed by the body.
        var inner_seq = std.ArrayListUnmanaged(NodeId).empty;
        defer inner_seq.deinit(b.allocator);

        for (names.items, 0..) |nm, i| {
            const vid = try b.buildExpr(val_exprs.items[i]);
            const set_id = try b.arena.add(.{ .set_bang = .{
                .name = nm,
                .value = vid,
                .span = b.current_span,
            } });
            try inner_seq.append(b.allocator, set_id);
        }
        // Append body exprs.
        try b.collectScopedBody(body_form, &inner_seq);

        const seq_owned = try b.arena.dupNodeIds(inner_seq.items);
        const body_seq = try b.arena.add(.{ .sequence = .{
            .exprs = seq_owned,
            .span = b.current_span,
        } });

        // Outer lambda params = names. Each init value is literal #f.
        const params_owned = try b.arena.dupNames(names.items);
        const body_ids = try b.arena.dupNodeIds(&[_]NodeId{body_seq});
        const lambda_id = try b.arena.add(.{ .lambda = .{
            .params = params_owned,
            .rest_param = null,
            .body = body_ids,
            .span = b.current_span,
        } });

        // Build arg exprs = #f for each binding.
        var arg_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer arg_ids.deinit(b.allocator);
        for (names.items) |_| {
            const fid = try b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
            try arg_ids.append(b.allocator, fid);
        }
        const args_owned = try b.arena.dupNodeIds(arg_ids.items);

        return b.arena.add(.{ .application = .{
            .func = lambda_id,
            .args = args_owned,
            .span = b.current_span,
        } });
    }

    /// (and) => #t, (and e) => e, (and e1 e2 ...) => (if e1 (and e2 ...) #f)
    fn buildAnd(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        // Collect exprs.
        var exprs = std.ArrayListUnmanaged(Value).empty;
        defer exprs.deinit(b.allocator);
        var cur = rest;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            try exprs.append(b.allocator, objects.pairCar(cur).*);
            cur = objects.pairCdr(cur).*;
        }
        if (exprs.items.len == 0) {
            return b.arena.add(.{ .literal = .{ .val = .{ .boolean = true }, .span = b.current_span } });
        }
        if (exprs.items.len == 1) {
            return b.buildExpr(exprs.items[0]);
        }
        // Build right-to-left.
        var i: usize = exprs.items.len;
        // Last expr is the base case.
        i -= 1;
        var acc: NodeId = try b.buildExpr(exprs.items[i]);
        while (i > 0) {
            i -= 1;
            const e_id = try b.buildExpr(exprs.items[i]);
            const false_id = try b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
            acc = try b.arena.add(.{ .if_expr = .{
                .cond = e_id,
                .then_ = acc,
                .else_ = false_id,
                .span = b.current_span,
            } });
        }
        return acc;
    }

    /// (or) => #f, (or e) => e, (or e1 e2 ...) => (let ((t e1)) (if t t (or e2 ...)))
    fn buildOr(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        var exprs = std.ArrayListUnmanaged(Value).empty;
        defer exprs.deinit(b.allocator);
        var cur = rest;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            try exprs.append(b.allocator, objects.pairCar(cur).*);
            cur = objects.pairCdr(cur).*;
        }
        if (exprs.items.len == 0) {
            return b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
        }
        if (exprs.items.len == 1) {
            return b.buildExpr(exprs.items[0]);
        }
        // Build right-to-left.
        var i: usize = exprs.items.len;
        i -= 1;
        var acc: NodeId = try b.buildExpr(exprs.items[i]);
        while (i > 0) {
            i -= 1;
            // (let ((t <e_i>)) (if t t <acc>))
            const tmp_name = try b.arena.dupString("%or-tmp");
            const val_id = try b.buildExpr(exprs.items[i]);
            const tref1 = try b.arena.add(.{ .sym_ref = .{ .name = tmp_name, .span = b.current_span } });
            const tref2 = try b.arena.add(.{ .sym_ref = .{ .name = tmp_name, .span = b.current_span } });
            const if_id = try b.arena.add(.{ .if_expr = .{
                .cond = tref1,
                .then_ = tref2,
                .else_ = acc,
                .span = b.current_span,
            } });
            const params_owned = try b.arena.dupNames(&[_][]const u8{tmp_name});
            const body_owned = try b.arena.dupNodeIds(&[_]NodeId{if_id});
            const lam_id = try b.arena.add(.{ .lambda = .{
                .params = params_owned,
                .rest_param = null,
                .body = body_owned,
                .span = b.current_span,
            } });
            const args_owned = try b.arena.dupNodeIds(&[_]NodeId{val_id});
            acc = try b.arena.add(.{ .application = .{
                .func = lam_id,
                .args = args_owned,
                .span = b.current_span,
            } });
        }
        return acc;
    }

    /// (when test body...) => (if test (begin body...) #f)
    fn buildWhen(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const test_v = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;
        const test_id = try b.buildExpr(test_v);
        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectBody(body_form, &body_ids);
        const body_owned = try b.arena.dupNodeIds(body_ids.items);
        const seq_id = try b.arena.add(.{ .sequence = .{ .exprs = body_owned, .span = b.current_span } });
        const false_id = try b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
        return b.arena.add(.{ .if_expr = .{
            .cond = test_id,
            .then_ = seq_id,
            .else_ = false_id,
            .span = b.current_span,
        } });
    }

    /// (unless test body...) => (if test #f (begin body...))
    fn buildUnless(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const test_v = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;
        const test_id = try b.buildExpr(test_v);
        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectBody(body_form, &body_ids);
        const body_owned = try b.arena.dupNodeIds(body_ids.items);
        const seq_id = try b.arena.add(.{ .sequence = .{ .exprs = body_owned, .span = b.current_span } });
        const false_id = try b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
        return b.arena.add(.{ .if_expr = .{
            .cond = test_id,
            .then_ = false_id,
            .else_ = seq_id,
            .span = b.current_span,
        } });
    }

    fn buildQuote(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const datum = objects.pairCar(rest).*;
        const after = objects.pairCdr(rest).*;
        if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;
        return b.arena.add(.{ .quote = .{ .datum = datum, .span = b.current_span } });
    }

    fn buildLambda(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const params_form = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;
        return b.buildLambdaParts(params_form, body_form);
    }

    // zepo-g120: build a lambda node from an already-split (params . body),
    // without an enclosing (lambda ...) pair. Used by restart-case to compile
    // each clause as a closure. Mirrors buildLambda's parsing exactly.
    fn buildLambdaParts(b: *Builder, params_form: Value, body_form: Value) BuildError!NodeId {

        var params = std.ArrayListUnmanaged([]const u8).empty;
        defer params.deinit(b.allocator);
        var rest_param: ?[]const u8 = null;
        var kw_params = std.ArrayListUnmanaged(node_mod.KwParam).empty;
        defer kw_params.deinit(b.allocator);

        if (objects.isSymbol(params_form)) {
            // (lambda rest body...) — whole arg list
            rest_param = try b.arena.dupString(objects.symbolName(params_form));
        } else if (value_mod.isNil(params_form)) {
            // no params
        } else if (objects.isPair(params_form)) {
            var cur = params_form;
            while (true) {
                if (objects.isPair(cur)) {
                    const car = objects.pairCar(cur).*;
                    if (!objects.isSymbol(car)) return BuildError.InvalidSpecialForm;
                    const sym_name = objects.symbolName(car);
                    if (sym_name.len > 0 and sym_name[0] == ':') {
                        // keyword param: :name default
                        const bare = try b.arena.dupString(sym_name[1..]);
                        const next = objects.pairCdr(cur).*;
                        if (!objects.isPair(next)) return BuildError.InvalidSpecialForm;
                        const default_v = objects.pairCar(next).*;
                        var def = parseKwDefault(default_v) orelse return BuildError.InvalidSpecialForm;
                        if (def == .string) def = .{ .string = try b.arena.dupString(def.string) };
                        try kw_params.append(b.allocator, .{ .name = bare, .default = def });
                        cur = objects.pairCdr(next).*;
                    } else {
                        const name = try b.arena.dupString(sym_name);
                        try params.append(b.allocator, name);
                        cur = objects.pairCdr(cur).*;
                    }
                } else if (value_mod.isNil(cur)) {
                    break;
                } else if (objects.isSymbol(cur)) {
                    // dotted rest
                    rest_param = try b.arena.dupString(objects.symbolName(cur));
                    break;
                } else {
                    return BuildError.InvalidSpecialForm;
                }
            }
        } else {
            return BuildError.InvalidSpecialForm;
        }

        // zepo-iv6k: a rest param MAY now combine with #:keyword params — the
        // rest param captures the UNKNOWN keyword pairs (a flat plist) so a
        // function can handle some keys and forward the rest. (Previously this
        // combination was rejected.)

        // zepo-uney: peel optional :documentation "..." before body collection
        const peeled = try peelDocumentation(b.arena, body_form);

        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectScopedBody(peeled.rest, &body_ids);

        const params_owned = try b.arena.dupNames(params.items);
        const body_owned = try b.arena.dupNodeIds(body_ids.items);
        const kw_owned = try b.arena.dupKwParams(kw_params.items);

        return b.arena.add(.{ .lambda = .{
            .params = params_owned,
            .rest_param = rest_param,
            .keyword_params = kw_owned,
            .body = body_owned,
            .span = b.current_span,
            .docstring = peeled.doc,
        } });
    }

    fn collectBody(b: *Builder, body_form: Value, out: *std.ArrayList(NodeId)) BuildError!void {
        var cur = body_form;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const expr = objects.pairCar(cur).*;
            const id = try b.buildExpr(expr);
            try out.append(b.allocator, id);
            cur = objects.pairCdr(cur).*;
        }
    }

    // zepo-3dtd: a parsed internal definition — the bound name and the AST node
    // for its value. `(define x e)` yields (x, <e>); `(define (f a) body)`
    // yields (f, <(lambda (a) body)>).
    const InternalDefine = struct { name: []const u8, value: NodeId };

    // zepo-3dtd: if `form` is a `(define ...)`, parse it into its name and value
    // node WITHOUT emitting a global-scope `.define` node; otherwise return
    // null. Mirrors buildDefine's parsing of both define shapes.
    fn internalDefineParts(b: *Builder, form: Value) BuildError!?InternalDefine {
        if (!objects.isPair(form)) return null;
        const head = objects.pairCar(form).*;
        if (!objects.isSymbol(head)) return null;
        if (!std.mem.eql(u8, objects.symbolName(head), "define")) return null;

        const rest = objects.pairCdr(form).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const target = objects.pairCar(rest).*;
        const tail = objects.pairCdr(rest).*;

        if (objects.isSymbol(target)) {
            // (define name [:documentation "..."] expr)
            const peeled = try peelDocumentation(b.arena, tail);
            const tail2 = peeled.rest;
            if (!objects.isPair(tail2)) return BuildError.InvalidSpecialForm;
            const expr = objects.pairCar(tail2).*;
            if (!value_mod.isNil(objects.pairCdr(tail2).*)) return BuildError.InvalidSpecialForm;
            const name = try b.arena.dupString(objects.symbolName(target));
            const value_id = try b.buildExpr(expr);
            return InternalDefine{ .name = name, .value = value_id };
        }

        if (objects.isPair(target)) {
            // (define (name params...) body...) => name, (lambda (params...) body...)
            const name_val = objects.pairCar(target).*;
            if (!objects.isSymbol(name_val)) return BuildError.InvalidSpecialForm;
            const name = try b.arena.dupString(objects.symbolName(name_val));
            const params_form = objects.pairCdr(target).*;
            const peeled = try peelDocumentation(b.arena, tail);
            const value_id = try b.buildLambdaParts(params_form, peeled.rest);
            return InternalDefine{ .name = name, .value = value_id };
        }

        return BuildError.InvalidSpecialForm;
    }

    // zepo-3dtd: collect a lambda/let-family <body>. Per R7RS a body is zero or
    // more internal definitions followed by expressions, and those definitions
    // are letrec*-scoped locals — NOT globals (the old path lowered every
    // define, at any nesting, to store_global, so internal defines leaked to
    // the top level and same-named helpers in different functions clobbered
    // one another). Peel the leading run of defines and desugar them exactly
    // like `letrec` (see buildDefineScope). With no leading defines this is
    // byte-identical to collectBody.
    fn collectScopedBody(b: *Builder, body_form: Value, out: *std.ArrayList(NodeId)) BuildError!void {
        var defines = std.ArrayListUnmanaged(InternalDefine).empty;
        defer defines.deinit(b.allocator);

        var cur = body_form;
        while (objects.isPair(cur)) {
            const form = objects.pairCar(cur).*;
            const parts = (try b.internalDefineParts(form)) orelse break;
            try defines.append(b.allocator, parts);
            cur = objects.pairCdr(cur).*;
        }

        if (defines.items.len == 0) {
            return b.collectBody(body_form, out);
        }

        const scope_id = try b.buildDefineScope(defines.items, cur);
        try out.append(b.allocator, scope_id);
    }

    // zepo-3dtd: desugar peeled internal defines plus the remaining body into a
    // letrec* scope, reusing the shape buildLetrec produces:
    //   ((lambda (n1 n2 ...) (set! n1 v1) (set! n2 v2) rest...) #f #f ...)
    // The names become lambda params (fresh locals), so references resolve to
    // local slots instead of globals and mutual recursion still works (all
    // names are in scope before any initializer runs). `rest_body` begins at
    // the first non-define form and carries no leading defines.
    fn buildDefineScope(b: *Builder, defines: []const InternalDefine, rest_body: Value) BuildError!NodeId {
        var inner_seq = std.ArrayListUnmanaged(NodeId).empty;
        defer inner_seq.deinit(b.allocator);

        for (defines) |d| {
            const set_id = try b.arena.add(.{ .set_bang = .{
                .name = d.name,
                .value = d.value,
                .span = b.current_span,
            } });
            try inner_seq.append(b.allocator, set_id);
        }
        try b.collectBody(rest_body, &inner_seq);

        const seq_owned = try b.arena.dupNodeIds(inner_seq.items);
        const body_seq = try b.arena.add(.{ .sequence = .{
            .exprs = seq_owned,
            .span = b.current_span,
        } });

        var names = std.ArrayListUnmanaged([]const u8).empty;
        defer names.deinit(b.allocator);
        for (defines) |d| try names.append(b.allocator, d.name);
        const params_owned = try b.arena.dupNames(names.items);
        const body_ids = try b.arena.dupNodeIds(&[_]NodeId{body_seq});
        const lambda_id = try b.arena.add(.{ .lambda = .{
            .params = params_owned,
            .rest_param = null,
            .body = body_ids,
            .span = b.current_span,
        } });

        var arg_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer arg_ids.deinit(b.allocator);
        for (defines) |_| {
            const fid = try b.arena.add(.{ .literal = .{ .val = .{ .boolean = false }, .span = b.current_span } });
            try arg_ids.append(b.allocator, fid);
        }
        const args_owned = try b.arena.dupNodeIds(arg_ids.items);

        return b.arena.add(.{ .application = .{
            .func = lambda_id,
            .args = args_owned,
            .span = b.current_span,
        } });
    }

    // zepo-uney: If `doc` is non-null, wrap `define_id` in a sequence that
    // calls `(%set-binding-doc! 'name "doc")` after the define so the
    // docstring lands in the binding's EntryMeta.
    fn wrapWithDocCall(b: *Builder, define_id: NodeId, name_sym: Value, doc: ?[]const u8) BuildError!NodeId {
        const doc_str = doc orelse return define_id;
        const func_ref = try b.arena.add(.{ .sym_ref = .{
            .name = "%set-binding-doc!",
            .span = b.current_span,
        } });
        const sym_quote = try b.arena.add(.{ .quote = .{
            .datum = name_sym,
            .span = b.current_span,
        } });
        const doc_owned = try b.arena.dupString(doc_str);
        const doc_lit = try b.arena.add(.{ .literal = .{
            .val = .{ .string = doc_owned },
            .span = b.current_span,
        } });
        const args_owned = try b.arena.dupNodeIds(&[_]NodeId{ sym_quote, doc_lit });
        const call_id = try b.arena.add(.{ .application = .{
            .func = func_ref,
            .args = args_owned,
            .span = b.current_span,
        } });
        const seq_owned = try b.arena.dupNodeIds(&[_]NodeId{ define_id, call_id });
        return b.arena.add(.{ .sequence = .{
            .exprs = seq_owned,
            .span = b.current_span,
        } });
    }

    fn buildDefine(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const target = objects.pairCar(rest).*;
        const tail = objects.pairCdr(rest).*;

        if (objects.isSymbol(target)) {
            // (define name [:documentation "..."] expr)
            // zepo-uney: peel docstring before reading the value form
            const peeled = try peelDocumentation(b.arena, tail);
            const tail2 = peeled.rest;
            if (!objects.isPair(tail2)) return BuildError.InvalidSpecialForm;
            const expr = objects.pairCar(tail2).*;
            const after = objects.pairCdr(tail2).*;
            if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;
            const name = try b.arena.dupString(objects.symbolName(target));
            const value_id = try b.buildExpr(expr);
            const define_id = try b.arena.add(.{ .define = .{
                .name = name,
                .value = value_id,
                .span = b.current_span,
                .docstring = peeled.doc,
            } });
            return b.wrapWithDocCall(define_id, target, peeled.doc);
        }

        if (objects.isPair(target)) {
            // (define (name params...) body...) => (define name (lambda (params...) body...))
            const name_val = objects.pairCar(target).*;
            if (!objects.isSymbol(name_val)) return BuildError.InvalidSpecialForm;
            const name = try b.arena.dupString(objects.symbolName(name_val));
            const params_form = objects.pairCdr(target).*;

            var params = std.ArrayListUnmanaged([]const u8).empty;
            defer params.deinit(b.allocator);
            var rest_param: ?[]const u8 = null;
            var kw_params = std.ArrayListUnmanaged(node_mod.KwParam).empty;
            defer kw_params.deinit(b.allocator);

            var cur = params_form;
            while (true) {
                if (objects.isPair(cur)) {
                    const car = objects.pairCar(cur).*;
                    if (!objects.isSymbol(car)) return BuildError.InvalidSpecialForm;
                    const sym_name = objects.symbolName(car);
                    if (sym_name.len > 0 and sym_name[0] == ':') {
                        const bare = try b.arena.dupString(sym_name[1..]);
                        const next = objects.pairCdr(cur).*;
                        if (!objects.isPair(next)) return BuildError.InvalidSpecialForm;
                        const default_v = objects.pairCar(next).*;
                        var def = parseKwDefault(default_v) orelse return BuildError.InvalidSpecialForm;
                        if (def == .string) def = .{ .string = try b.arena.dupString(def.string) };
                        try kw_params.append(b.allocator, .{ .name = bare, .default = def });
                        cur = objects.pairCdr(next).*;
                    } else {
                        const pname = try b.arena.dupString(sym_name);
                        try params.append(b.allocator, pname);
                        cur = objects.pairCdr(cur).*;
                    }
                } else if (value_mod.isNil(cur)) {
                    break;
                } else if (objects.isSymbol(cur)) {
                    rest_param = try b.arena.dupString(objects.symbolName(cur));
                    break;
                } else {
                    return BuildError.InvalidSpecialForm;
                }
            }

            // zepo-iv6k: rest + #:keyword params now allowed (see above).

            // zepo-uney: shorthand define-with-params: peel docstring from
            // body before collecting body forms.
            const peeled = try peelDocumentation(b.arena, tail);

            var body_ids = std.ArrayListUnmanaged(NodeId).empty;
            defer body_ids.deinit(b.allocator);
            try b.collectScopedBody(peeled.rest, &body_ids);

            const params_owned = try b.arena.dupNames(params.items);
            const body_owned = try b.arena.dupNodeIds(body_ids.items);
            const kw_owned = try b.arena.dupKwParams(kw_params.items);

            const lambda_id = try b.arena.add(.{ .lambda = .{
                .params = params_owned,
                .rest_param = rest_param,
                .keyword_params = kw_owned,
                .body = body_owned,
                .span = b.current_span,
                .docstring = peeled.doc,
            } });

            const define_id = try b.arena.add(.{ .define = .{
                .name = name,
                .value = lambda_id,
                .span = b.current_span,
                .docstring = peeled.doc,
            } });
            return b.wrapWithDocCall(define_id, name_val, peeled.doc);
        }

        return BuildError.InvalidSpecialForm;
    }

    fn buildSetBang(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const target = objects.pairCar(rest).*;
        if (!objects.isSymbol(target)) return BuildError.InvalidSpecialForm;
        const tail = objects.pairCdr(rest).*;
        if (!objects.isPair(tail)) return BuildError.InvalidSpecialForm;
        const expr = objects.pairCar(tail).*;
        const after = objects.pairCdr(tail).*;
        if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;

        const name = try b.arena.dupString(objects.symbolName(target));
        const value_id = try b.buildExpr(expr);
        return b.arena.add(.{ .set_bang = .{ .name = name, .value = value_id, .span = b.current_span } });
    }

    fn buildIf(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const cond_v = objects.pairCar(rest).*;
        const tail = objects.pairCdr(rest).*;
        if (!objects.isPair(tail)) return BuildError.InvalidSpecialForm;
        const then_v = objects.pairCar(tail).*;
        const tail2 = objects.pairCdr(tail).*;

        const cond_id = try b.buildExpr(cond_v);
        const then_id = try b.buildExpr(then_v);
        var else_id: ?NodeId = null;
        if (objects.isPair(tail2)) {
            const else_v = objects.pairCar(tail2).*;
            const after = objects.pairCdr(tail2).*;
            if (!value_mod.isNil(after)) return BuildError.InvalidSpecialForm;
            else_id = try b.buildExpr(else_v);
        } else if (!value_mod.isNil(tail2)) {
            return BuildError.InvalidSpecialForm;
        }

        return b.arena.add(.{ .if_expr = .{ .cond = cond_id, .then_ = then_id, .else_ = else_id, .span = b.current_span } });
    }

    fn buildCond(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        var clauses = std.ArrayListUnmanaged(CondClause).empty;
        defer clauses.deinit(b.allocator);

        var cur = rest;
        while (true) {
            if (value_mod.isNil(cur)) break;
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const clause_form = objects.pairCar(cur).*;
            if (!objects.isPair(clause_form)) return BuildError.InvalidSpecialForm;

            const test_v = objects.pairCar(clause_form).*;
            const body_form = objects.pairCdr(clause_form).*;
            // `else` is a conventional catch-all — compile directly to #t.
            const test_id = if (objects.isSymbol(test_v) and
                std.mem.eql(u8, objects.symbolName(test_v), "else"))
                try b.arena.add(.{ .literal = .{ .val = .{ .boolean = true }, .span = b.current_span } })
            else
                try b.buildExpr(test_v);

            var body_ids = std.ArrayListUnmanaged(NodeId).empty;
            defer body_ids.deinit(b.allocator);
            try b.collectBody(body_form, &body_ids);
            const body_owned = try b.arena.dupNodeIds(body_ids.items);

            try clauses.append(b.allocator, .{ .test_ = test_id, .body = body_owned });
            cur = objects.pairCdr(cur).*;
        }

        const clauses_owned = try b.arena.dupClauses(clauses.items);
        return b.arena.add(.{ .cond_expr = .{ .clauses = clauses_owned, .span = b.current_span } });
    }

    /// zepo-9bi: Pattern-match `(with-exception-handler H (lambda () body...))`.
    /// On success returns the `.with_handler` AST node; on a shape mismatch
    /// returns null so the caller falls back to regular application.
    /// Errors only on actual malformed pairs (not on shape mismatch).
    fn tryBuildWithHandler(b: *Builder, pair: Value) BuildError!?NodeId {
        // pair = (with-exception-handler H thunk)
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return null;
        const handler_form = objects.pairCar(rest).*;
        const rest2 = objects.pairCdr(rest).*;
        if (!objects.isPair(rest2)) return null;
        const thunk_form = objects.pairCar(rest2).*;
        const rest3 = objects.pairCdr(rest2).*;
        if (!value_mod.isNil(rest3)) return null; // exactly 2 args required

        // thunk must be (lambda () body...) with EMPTY param list to qualify.
        if (!objects.isPair(thunk_form)) return null;
        const lam_head = objects.pairCar(thunk_form).*;
        if (!objects.isSymbol(lam_head)) return null;
        if (!std.mem.eql(u8, objects.symbolName(lam_head), "lambda")) return null;
        const lam_rest = objects.pairCdr(thunk_form).*;
        if (!objects.isPair(lam_rest)) return null;
        const params_form = objects.pairCar(lam_rest).*;
        if (!value_mod.isNil(params_form)) return null; // must be ()
        const lam_body_forms = objects.pairCdr(lam_rest).*;

        // Build handler and body.
        const handler_id = try b.buildExpr(handler_form);
        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectBody(lam_body_forms, &body_ids);
        if (body_ids.items.len == 0) return null; // empty body — let app handle
        const body_owned = try b.arena.dupNodeIds(body_ids.items);
        return try b.arena.add(.{ .with_handler = .{
            .handler = handler_id,
            .body = body_owned,
            .span = b.current_span,
        } });
    }

    // zepo-6o3p: (parameterize ((p1 v1) (p2 v2) ...) body...)
    fn buildParameterize(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const bindings_form = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;

        var params = std.ArrayListUnmanaged(NodeId).empty;
        defer params.deinit(b.allocator);
        var inits = std.ArrayListUnmanaged(NodeId).empty;
        defer inits.deinit(b.allocator);

        var cur = bindings_form;
        while (!value_mod.isNil(cur)) {
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const binding = objects.pairCar(cur).*;
            if (!objects.isPair(binding)) return BuildError.InvalidSpecialForm;
            const p_form = objects.pairCar(binding).*;
            const bind_rest = objects.pairCdr(binding).*;
            if (!objects.isPair(bind_rest)) return BuildError.InvalidSpecialForm;
            const v_form = objects.pairCar(bind_rest).*;
            // exactly (param value) — reject (param) or (param v extra)
            if (!value_mod.isNil(objects.pairCdr(bind_rest).*)) return BuildError.InvalidSpecialForm;
            try params.append(b.allocator, try b.buildExpr(p_form));
            try inits.append(b.allocator, try b.buildExpr(v_form));
            cur = objects.pairCdr(cur).*;
        }

        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectScopedBody(body_form, &body_ids);
        if (body_ids.items.len == 0) return BuildError.InvalidSpecialForm;

        return b.arena.add(.{ .parameterize = .{
            .params = try b.arena.dupNodeIds(params.items),
            .inits = try b.arena.dupNodeIds(inits.items),
            .body = try b.arena.dupNodeIds(body_ids.items),
            .span = b.current_span,
        } });
    }

    // zepo-g120: (handler-bind HANDLER body...) — non-unwinding handler.
    // Reuses the with_handler node with binding=true; HANDLER runs in place at
    // the signal site (see vm.signal) and either declines (returns) or transfers
    // (e.g. invoke-restart). Body is inline (no thunk wrapper).
    fn buildHandlerBind(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const handler_form = objects.pairCar(rest).*;
        const body_form = objects.pairCdr(rest).*;
        const handler_id = try b.buildExpr(handler_form);
        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try b.collectBody(body_form, &body_ids);
        if (body_ids.items.len == 0) return BuildError.InvalidSpecialForm;
        return b.arena.add(.{ .with_handler = .{
            .handler = handler_id,
            .body = try b.arena.dupNodeIds(body_ids.items),
            .span = b.current_span,
            .binding = true,
        } });
    }

    // zepo-g120: (restart-case BODY (NAME (param...) [:report STR] cbody...) ...)
    fn buildRestartCase(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const body_expr = objects.pairCar(rest).*;
        const clauses_form = objects.pairCdr(rest).*;

        // The protected body is a single expression (wrap multiple in begin).
        var body_ids = std.ArrayListUnmanaged(NodeId).empty;
        defer body_ids.deinit(b.allocator);
        try body_ids.append(b.allocator, try b.buildExpr(body_expr));

        var names = std.ArrayListUnmanaged(Value).empty;
        defer names.deinit(b.allocator);
        var clauses = std.ArrayListUnmanaged(NodeId).empty;
        defer clauses.deinit(b.allocator);
        var reports = std.ArrayListUnmanaged(Value).empty;
        defer reports.deinit(b.allocator);

        var cur = clauses_form;
        while (!value_mod.isNil(cur)) {
            if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
            const clause = objects.pairCar(cur).*;
            if (!objects.isPair(clause)) return BuildError.InvalidSpecialForm;
            // NAME
            const name_v = objects.pairCar(clause).*;
            if (!objects.isSymbol(name_v)) return BuildError.InvalidSpecialForm;
            // (param...)
            const after_name = objects.pairCdr(clause).*;
            if (!objects.isPair(after_name)) return BuildError.InvalidSpecialForm;
            const params_form = objects.pairCar(after_name).*;
            // optional :report STR, then clause body
            var tail = objects.pairCdr(after_name).*;
            var report_v: Value = value_mod.NIL;
            if (objects.isPair(tail)) {
                const head = objects.pairCar(tail).*;
                if (objects.isSymbol(head) and std.mem.eql(u8, objects.symbolName(head), ":report")) {
                    const rrest = objects.pairCdr(tail).*;
                    if (!objects.isPair(rrest)) return BuildError.InvalidSpecialForm;
                    report_v = objects.pairCar(rrest).*;
                    tail = objects.pairCdr(rrest).*;
                }
            }
            // Compile the clause as a closure (lambda (params...) cbody...).
            const clause_fn = try b.buildLambdaParts(params_form, tail);
            try names.append(b.allocator, name_v);
            try clauses.append(b.allocator, clause_fn);
            try reports.append(b.allocator, report_v);
            cur = objects.pairCdr(cur).*;
        }

        return b.arena.add(.{ .restart_case = .{
            .body = try b.arena.dupNodeIds(body_ids.items),
            .names = try b.arena.dupValues(names.items),
            .clauses = try b.arena.dupNodeIds(clauses.items),
            .reports = try b.arena.dupValues(reports.items),
            .span = b.current_span,
        } });
    }

    fn buildBegin(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        var exprs = std.ArrayListUnmanaged(NodeId).empty;
        defer exprs.deinit(b.allocator);
        try b.collectBody(rest, &exprs);
        const owned = try b.arena.dupNodeIds(exprs.items);
        return b.arena.add(.{ .sequence = .{ .exprs = owned, .span = b.current_span } });
    }

    fn buildApplication(b: *Builder, pair: Value) BuildError!NodeId {
        const func_v = objects.pairCar(pair).*;
        const args_form = objects.pairCdr(pair).*;
        const func_id = try b.buildExpr(func_v);

        var args = std.ArrayListUnmanaged(NodeId).empty;
        defer args.deinit(b.allocator);
        try b.collectBody(args_form, &args);
        const args_owned = try b.arena.dupNodeIds(args.items);

        return b.arena.add(.{ .application = .{ .func = func_id, .args = args_owned, .span = b.current_span } });
    }

    fn buildImport(b: *Builder, pair: Value) BuildError!NodeId {
        const rest = objects.pairCdr(pair).*;
        if (!objects.isPair(rest)) return BuildError.InvalidSpecialForm;
        const name_v = objects.pairCar(rest).*;
        if (!objects.isSymbol(name_v)) return BuildError.ImportNameMustBeSymbol;
        const name = try b.arena.dupString(objects.symbolName(name_v));

        const tail = objects.pairCdr(rest).*;
        var selection: node_mod.ImportSelection = .all;

        if (!value_mod.isNil(tail)) {
            if (!objects.isPair(tail)) return BuildError.InvalidSpecialForm;
            const selector = objects.pairCar(tail).*;
            const after_selector = objects.pairCdr(tail).*;

            // (import name as alias)
            if (objects.isSymbol(selector) and std.mem.eql(u8, objects.symbolName(selector), "as")) {
                if (!objects.isPair(after_selector)) return BuildError.InvalidSpecialForm;
                const alias_v = objects.pairCar(after_selector).*;
                if (!objects.isSymbol(alias_v)) return BuildError.InvalidSpecialForm;
                if (!value_mod.isNil(objects.pairCdr(after_selector).*)) return BuildError.InvalidSpecialForm;
                const alias = try b.arena.dupString(objects.symbolName(alias_v));
                selection = .{ .as_alias = alias };
            } else {
                // (import name (only sym...))   — explicit
                // (import name (sym ...))         — zepo-ug3 sugar
                if (!value_mod.isNil(after_selector)) return BuildError.InvalidSpecialForm;
                if (!objects.isPair(selector)) return BuildError.InvalidSpecialForm;
                var cur = blk: {
                    const head = objects.pairCar(selector).*;
                    if (objects.isSymbol(head) and std.mem.eql(u8, objects.symbolName(head), "only")) {
                        break :blk objects.pairCdr(selector).*;
                    }
                    break :blk selector;
                };
                var names = std.ArrayListUnmanaged([]const u8).empty;
                defer names.deinit(b.allocator);
                while (!value_mod.isNil(cur)) {
                    if (!objects.isPair(cur)) return BuildError.InvalidSpecialForm;
                    const nm_v = objects.pairCar(cur).*;
                    if (!objects.isSymbol(nm_v)) return BuildError.InvalidSpecialForm;
                    try names.append(b.allocator, try b.arena.dupString(objects.symbolName(nm_v)));
                    cur = objects.pairCdr(cur).*;
                }
                const owned = try b.allocator.dupe([]const u8, names.items);
                // Track the slice so it gets freed with the arena lifetime
                try b.arena.name_lists.append(b.allocator, owned);
                selection = .{ .only = owned };
            }
        }

        return b.arena.add(.{ .import_stmt = .{ .name = name, .selection = selection, .span = b.current_span } });
    }
};
