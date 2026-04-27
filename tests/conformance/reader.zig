//! Reader conformance tests.

const std = @import("std");
const zepo = @import("zepo");
const helpers = @import("helpers.zig");
const Rig = helpers.Rig;

const alloc = std.testing.allocator;

test "reader: integer literal" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("42"), 42);
    try helpers.expectInt(try r.eval("-7"), -7);
    try helpers.expectInt(try r.eval("0"), 0);
}

test "reader: float literal" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("3.14");
    try helpers.expectFloat(v, 3.14, 1e-9);
}

test "reader: boolean literals" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("#t"));
    try helpers.expectFalse(try r.eval("#f"));
}

test "reader: empty list reads as nil" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectNil(try r.eval("(quote ())"));
    try helpers.expectTrue(try r.eval("(null? (quote ()))"));
}

test "reader: proper list" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(quote (1 2 3))");
    try std.testing.expect(helpers.objects.isPair(v));
    try helpers.expectInt(helpers.objects.pairCar(v).*, 1);
}

test "reader: nested list" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(car (quote ((1 2) 3)))");
    try std.testing.expect(helpers.objects.isPair(v));
    try helpers.expectInt(helpers.objects.pairCar(v).*, 1);
}

test "reader: improper/dotted list" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(quote (1 . 2))");
    try std.testing.expect(helpers.objects.isPair(v));
    try helpers.expectInt(helpers.objects.pairCar(v).*, 1);
    try helpers.expectInt(helpers.objects.pairCdr(v).*, 2);
}

test "reader: quote desugaring" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // 'x === (quote x); car of '(1 2) is 1
    const v = try r.eval("(car '(1 2))");
    try helpers.expectInt(v, 1);
}

test "reader: line comment" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("; this is a comment\n42");
    try helpers.expectInt(v, 42);
}

test "reader: string literal" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("\"hello\"");
    try std.testing.expect(helpers.objects.isString(v));
    try std.testing.expectEqualStrings("hello", helpers.objects.stringBytes(v));
}

test "reader: symbol" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(quote foo)");
    try std.testing.expect(helpers.objects.isSymbol(v));
    try std.testing.expectEqualStrings("foo", helpers.objects.symbolName(v));
}

test "reader error: unbalanced paren" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const res = r.eval("(+ 1 2");
    try std.testing.expect(std.meta.isError(res));
}

test "reader error: unterminated string" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const res = r.eval("\"unterminated");
    try std.testing.expect(std.meta.isError(res));
}
