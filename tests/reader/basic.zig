const std = @import("std");
const zepo = @import("zepo");
const GC = zepo.GC;
const Value = zepo.Value;
const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;
const reader_mod = zepo.reader;
const Parser = reader_mod.Parser;
const SpanTable = reader_mod.SpanTable;
const ReaderError = reader_mod.ReaderError;

const alloc = std.testing.allocator;

fn parse(gc: *GC, syms: *SymbolTable, spans: *SpanTable, src: []const u8) !Value {
    var p = Parser.init(gc, syms, spans, src, "<test>", alloc);
    defer p.deinit();
    return p.readOne();
}

fn parseAll(gc: *GC, syms: *SymbolTable, spans: *SpanTable, src: []const u8) !Value {
    var p = Parser.init(gc, syms, spans, src, "<test>", alloc);
    defer p.deinit();
    return p.readAll();
}

test "boolean #t" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "#t");
    try std.testing.expectEqual(value_mod.TRUE, v);
}

test "boolean #f" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "#f");
    try std.testing.expectEqual(value_mod.FALSE, v);
}

test "integer positive" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "42");
    try std.testing.expect(value_mod.isFixnum(v));
    try std.testing.expectEqual(@as(i63, 42), value_mod.fixnumVal(v));
}

test "integer negative" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "-7");
    try std.testing.expectEqual(@as(i63, -7), value_mod.fixnumVal(v));
}

test "float decimal" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "3.14");
    try std.testing.expect(objects.isFloat(v));
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), objects.floatVal(v), 1e-9);
}

test "float scientific" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "1e10");
    try std.testing.expect(objects.isFloat(v));
    try std.testing.expectApproxEqAbs(@as(f64, 1e10), objects.floatVal(v), 1.0);
}

test "string basic" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "\"hello\"");
    try std.testing.expect(objects.isString(v));
    try std.testing.expectEqualStrings("hello", objects.stringBytes(v));
}

test "string with escape newline" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "\"a\\nb\"");
    try std.testing.expectEqualStrings("a\nb", objects.stringBytes(v));
}

test "character letter" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "#\\a");
    try std.testing.expect(value_mod.isChar(v));
    try std.testing.expectEqual(@as(u21, 'a'), value_mod.charVal(v));
}

test "character space" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "#\\space");
    try std.testing.expectEqual(@as(u21, ' '), value_mod.charVal(v));
}

test "character newline" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "#\\newline");
    try std.testing.expectEqual(@as(u21, '\n'), value_mod.charVal(v));
}

test "character unicode" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "#\\u03BB");
    try std.testing.expectEqual(@as(u21, 0x03BB), value_mod.charVal(v));
}

test "symbol interned" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const a = try parse(&gc, &syms, &spans, "foo");
    const b = try parse(&gc, &syms, &spans, "foo");
    try std.testing.expect(objects.isSymbol(a));
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqualStrings("foo", objects.symbolName(a));
}

test "nil empty list" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "()");
    try std.testing.expectEqual(value_mod.NIL, v);
}

test "proper list (1 2 3)" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "(1 2 3)");
    try std.testing.expect(objects.isPair(v));
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(objects.pairCar(v).*));
    const rest = objects.pairCdr(v).*;
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(objects.pairCar(rest).*));
    const rest2 = objects.pairCdr(rest).*;
    try std.testing.expectEqual(@as(i63, 3), value_mod.fixnumVal(objects.pairCar(rest2).*));
    try std.testing.expectEqual(value_mod.NIL, objects.pairCdr(rest2).*);
}

test "dotted pair (1 . 2)" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "(1 . 2)");
    try std.testing.expect(objects.isPair(v));
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(objects.pairCar(v).*));
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(objects.pairCdr(v).*));
}

test "quote sugar" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    // 'x → (quote x)
    const v = try parse(&gc, &syms, &spans, "'x");
    try std.testing.expect(objects.isPair(v));
    const head = objects.pairCar(v).*;
    try std.testing.expect(objects.isSymbol(head));
    try std.testing.expectEqualStrings("quote", objects.symbolName(head));
    const tail = objects.pairCdr(v).*;
    try std.testing.expect(objects.isPair(tail));
    const sym_x = objects.pairCar(tail).*;
    try std.testing.expectEqualStrings("x", objects.symbolName(sym_x));
    try std.testing.expectEqual(value_mod.NIL, objects.pairCdr(tail).*);
}

test "comment skipped" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const v = try parse(&gc, &syms, &spans, "; this is a comment\n42");
    try std.testing.expectEqual(@as(i63, 42), value_mod.fixnumVal(v));
}

test "error: unbalanced paren" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const result = parse(&gc, &syms, &spans, "(1 2");
    try std.testing.expectError(ReaderError.UnbalancedParen, result);
}

test "error: unterminated string" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const result = parse(&gc, &syms, &spans, "\"unterminated");
    try std.testing.expectError(ReaderError.StringUnterminated, result);
}
