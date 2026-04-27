const std = @import("std");
const zepo = @import("zepo");
const GC = zepo.GC;
const Value = zepo.Value;
const abi = zepo.abi;
const value_mod = abi.value;
const gc_mod = zepo.gc;
const HandleScope = gc_mod.HandleScope;
const runtime = zepo.runtime;
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;

fn makeGC() !GC {
    return GC.init(std.testing.allocator);
}

test "makePair car cdr" {
    var gc = try makeGC();
    defer gc.deinit();
    const car = value_mod.fixnum(1);
    const cdr = value_mod.fixnum(2);
    const p = try objects.makePair(&gc, car, cdr);
    try std.testing.expect(objects.isPair(p));
    try std.testing.expectEqual(car, objects.pairCar(p).*);
    try std.testing.expectEqual(cdr, objects.pairCdr(p).*);
}

test "makeFloat round-trip" {
    var gc = try makeGC();
    defer gc.deinit();
    const v = try objects.makeFloat(&gc, 3.14);
    try std.testing.expect(objects.isFloat(v));
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), objects.floatVal(v), 1e-9);
}

test "makeBox get set" {
    var gc = try makeGC();
    defer gc.deinit();
    const b = try objects.makeBox(&gc, value_mod.fixnum(42));
    try std.testing.expect(objects.isBox(b));
    try std.testing.expectEqual(value_mod.fixnum(42), objects.boxGet(b));
    objects.boxSet(&gc, b, value_mod.fixnum(99));
    try std.testing.expectEqual(value_mod.fixnum(99), objects.boxGet(b));
}

test "makeString len bytes" {
    var gc = try makeGC();
    defer gc.deinit();
    const s = try objects.makeString(&gc, "hello");
    try std.testing.expect(objects.isString(s));
    try std.testing.expectEqual(@as(usize, 5), objects.stringLen(s));
    try std.testing.expectEqualStrings("hello", objects.stringBytes(s));
}

test "makeString empty" {
    var gc = try makeGC();
    defer gc.deinit();
    const s = try objects.makeString(&gc, "");
    try std.testing.expectEqual(@as(usize, 0), objects.stringLen(s));
    try std.testing.expectEqualStrings("", objects.stringBytes(s));
}

test "makeVector get set" {
    var gc = try makeGC();
    defer gc.deinit();
    const v = try objects.makeVector(&gc, 3, value_mod.fixnum(0));
    try std.testing.expect(objects.isVector(v));
    try std.testing.expectEqual(@as(usize, 3), objects.vectorLen(v));
    objects.vectorSet(&gc, v, 1, value_mod.fixnum(77));
    try std.testing.expectEqual(value_mod.fixnum(0), objects.vectorGet(v, 0));
    try std.testing.expectEqual(value_mod.fixnum(77), objects.vectorGet(v, 1));
    try std.testing.expectEqual(value_mod.fixnum(0), objects.vectorGet(v, 2));
}

test "makeClosure captures" {
    var gc = try makeGC();
    defer gc.deinit();
    const caps = [_]Value{ value_mod.fixnum(10), value_mod.fixnum(20) };
    const cl = try objects.makeClosure(&gc, 0xDEAD, 2, 0, &caps);
    try std.testing.expect(objects.isClosure(cl));
    try std.testing.expectEqual(@as(u64, 0xDEAD), objects.closureCodePtr(cl));
    try std.testing.expectEqual(@as(u64, 2), objects.closureArity(cl));
    const got = objects.closureCaptures(cl);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(value_mod.fixnum(10), got[0]);
    try std.testing.expectEqual(value_mod.fixnum(20), got[1]);
}

test "symbol interning identity" {
    var gc = try makeGC();
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, std.testing.allocator);
    defer syms.deinit();

    const a = try syms.intern("foo");
    const b = try syms.intern("foo");
    const c = try syms.intern("bar");
    // Same string → identical Value (eq? identity)
    try std.testing.expectEqual(a, b);
    // Different string → different Value
    try std.testing.expect(a != c);
    // Name is accessible
    try std.testing.expectEqualStrings("foo", objects.symbolName(a));
    try std.testing.expectEqualStrings("bar", objects.symbolName(c));
}

test "symbols survive minor GC" {
    var gc = try makeGC();
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, std.testing.allocator);
    defer syms.deinit();

    const before = try syms.intern("survive");
    // Trigger several minor GCs by allocating lots of pairs
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        _ = try objects.makePair(&gc, value_mod.fixnum(@intCast(i)), value_mod.NIL);
    }
    const after = try syms.intern("survive");
    // Same identity after GC
    try std.testing.expectEqual(before, after);
    try std.testing.expectEqualStrings("survive", objects.symbolName(after));
}
