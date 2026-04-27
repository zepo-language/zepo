const std = @import("std");
const zepo = @import("zepo");
const GC = zepo.GC;
const Value = zepo.Value;
const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;
const SymbolTable = runtime.SymbolTable;
const reader_mod = zepo.reader;
const Parser = reader_mod.Parser;
const SpanTable = reader_mod.SpanTable;

const ast_mod = zepo.ast;
const NodeArena = ast_mod.NodeArena;
const Builder = ast_mod.Builder;
const NodeId = ast_mod.NodeId;

const sema_mod = zepo.sema;

const alloc = std.testing.allocator;

fn buildOne(gc: *GC, syms: *SymbolTable, spans: *SpanTable, arena: *NodeArena, src: []const u8) !NodeId {
    var p = Parser.init(gc, syms, spans, src, "<test>", alloc);
    defer p.deinit();
    const v = try p.readOne();
    var b = Builder.init(arena, syms, alloc);
    return b.build(v);
}

test "build lambda" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(lambda (x) x)");
    const n = arena.get(id).*;
    try std.testing.expect(n == .lambda);
    try std.testing.expectEqual(@as(usize, 1), n.lambda.params.len);
    try std.testing.expectEqualStrings("x", n.lambda.params[0]);
    try std.testing.expectEqual(@as(usize, 1), n.lambda.body.len);
    const body = arena.get(n.lambda.body[0]).*;
    try std.testing.expect(body == .sym_ref);
    try std.testing.expectEqualStrings("x", body.sym_ref.name);
}

test "build define" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(define foo 42)");
    const n = arena.get(id).*;
    try std.testing.expect(n == .define);
    try std.testing.expectEqualStrings("foo", n.define.name);
    const val = arena.get(n.define.value).*;
    try std.testing.expect(val == .literal);
    try std.testing.expectEqual(@as(i63, 42), val.literal.val.fixnum);
}

test "build if" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(if #t 1 2)");
    const n = arena.get(id).*;
    try std.testing.expect(n == .if_expr);
    try std.testing.expect(n.if_expr.else_ != null);
}

test "build set!" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(set! x 5)");
    const n = arena.get(id).*;
    try std.testing.expect(n == .set_bang);
    try std.testing.expectEqualStrings("x", n.set_bang.name);
}

test "build application" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(+ 1 2)");
    const n = arena.get(id).*;
    try std.testing.expect(n == .application);
    try std.testing.expectEqual(@as(usize, 2), n.application.args.len);
}

test "build cond" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(cond (#t 1) (#f 2))");
    const n = arena.get(id).*;
    try std.testing.expect(n == .cond_expr);
    try std.testing.expectEqual(@as(usize, 2), n.cond_expr.clauses.len);
}

test "build quote" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "'(1 2)");
    const n = arena.get(id).*;
    try std.testing.expect(n == .quote);
}

test "captures: set! marks mutated" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(lambda (x) (set! x 1) x)");
    var analyzer = sema_mod.CaptureAnalyzer.init(&arena, alloc);
    try analyzer.analyze(id);
    const n = arena.get(id).*;
    try std.testing.expect(n == .lambda);
    var saw_x = false;
    for (n.lambda.mutated_vars) |name| {
        if (std.mem.eql(u8, name, "x")) saw_x = true;
    }
    try std.testing.expect(saw_x);
}

test "captures: inner lambda captures free var" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();

    const id = try buildOne(&gc, &syms, &spans, &arena, "(lambda (x) (lambda () x))");
    var analyzer = sema_mod.CaptureAnalyzer.init(&arena, alloc);
    try analyzer.analyze(id);
    const outer = arena.get(id).*;
    try std.testing.expect(outer == .lambda);
    for (outer.lambda.free_vars) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "x"));
    }
    const inner = arena.get(outer.lambda.body[0]).*;
    try std.testing.expect(inner == .lambda);
    var saw_x = false;
    for (inner.lambda.free_vars) |name| {
        if (std.mem.eql(u8, name, "x")) saw_x = true;
    }
    try std.testing.expect(saw_x);
}
