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

// zepo-x9w: `.` is the qualified-access separator (see ADR 0001).
// These tests lock in the lexer contract that the rest of the namespace
// work (zepo-aqm) builds on: `t.transpose` is a single symbol whose name
// contains a `.`, and it never gets confused with a number.
test "x9w: qualified symbol t.transpose is one symbol" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const s = try parse(&gc, &syms, &spans, "t.transpose");
    try std.testing.expect(objects.isSymbol(s));
    try std.testing.expectEqualStrings("t.transpose", objects.symbolName(s));
}

test "x9w: chained qualified symbol math.tensor.transpose is one symbol" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const s = try parse(&gc, &syms, &spans, "math.tensor.transpose");
    try std.testing.expect(objects.isSymbol(s));
    try std.testing.expectEqualStrings("math.tensor.transpose", objects.symbolName(s));
}

test "x9w: float and qualified symbol are unambiguous" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    // Leading digit → float, even if followed by alpha that could *look* like a member.
    const n = try parse(&gc, &syms, &spans, "1.5");
    try std.testing.expect(!objects.isSymbol(n));

    // Leading alpha → symbol all the way.
    const s = try parse(&gc, &syms, &spans, "x.5");
    try std.testing.expect(objects.isSymbol(s));
    try std.testing.expectEqualStrings("x.5", objects.symbolName(s));
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

// zepo-pybo: R7RS reader syntax — named/hex characters, radix + exactness
// number prefixes, and |...| pipe symbols.

test "pybo: named and hex character literals" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    try std.testing.expectEqual(value_mod.char(0), try parse(&gc, &syms, &spans, "#\\null"));
    try std.testing.expectEqual(value_mod.char(0x7f), try parse(&gc, &syms, &spans, "#\\delete"));
    try std.testing.expectEqual(value_mod.char(0x1b), try parse(&gc, &syms, &spans, "#\\escape"));
    try std.testing.expectEqual(value_mod.char(0x07), try parse(&gc, &syms, &spans, "#\\alarm"));
    try std.testing.expectEqual(value_mod.char(0x08), try parse(&gc, &syms, &spans, "#\\backspace"));
    try std.testing.expectEqual(value_mod.char('A'), try parse(&gc, &syms, &spans, "#\\x41"));
    // A bare "#\x" is still the character 'x'.
    try std.testing.expectEqual(value_mod.char('x'), try parse(&gc, &syms, &spans, "#\\x"));
}

test "pybo: radix and exactness number prefixes" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    try std.testing.expectEqual(@as(i63, 255), value_mod.fixnumVal(try parse(&gc, &syms, &spans, "#xff")));
    try std.testing.expectEqual(@as(i63, 15), value_mod.fixnumVal(try parse(&gc, &syms, &spans, "#o17")));
    try std.testing.expectEqual(@as(i63, 10), value_mod.fixnumVal(try parse(&gc, &syms, &spans, "#b1010")));
    try std.testing.expectEqual(@as(i63, 42), value_mod.fixnumVal(try parse(&gc, &syms, &spans, "#d42")));
    try std.testing.expectEqual(@as(i63, -26), value_mod.fixnumVal(try parse(&gc, &syms, &spans, "#x-1a")));
    // #i makes it inexact; #e#x combines exactness + radix.
    const inexact = try parse(&gc, &syms, &spans, "#i42");
    try std.testing.expect(objects.isFloat(inexact));
    try std.testing.expectEqual(@as(f64, 42.0), objects.floatVal(inexact));
    try std.testing.expectEqual(@as(i63, 16), value_mod.fixnumVal(try parse(&gc, &syms, &spans, "#e#x10")));
}

test "pybo: pipe-delimited symbols" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();

    const s = try parse(&gc, &syms, &spans, "|weird name|");
    try std.testing.expect(objects.isSymbol(s));
    try std.testing.expectEqualStrings("weird name", objects.symbolName(s));
    // A pipe symbol interns to the same symbol as the bare form.
    try std.testing.expectEqual(
        try parse(&gc, &syms, &spans, "abc"),
        try parse(&gc, &syms, &spans, "|abc|"),
    );
    // Escapes inside pipes.
    const e = try parse(&gc, &syms, &spans, "|a\\|b|");
    try std.testing.expectEqualStrings("a|b", objects.symbolName(e));
}
