//! GC stress matrix: every object layout shape x every GC phase, with the
//! invariant verifier asserted after every collection. Fast enough for CI.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;
const WORD: usize = 8;

// zepo-6s9
fn bodyP(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

// ── factory: one builder per layout shape ──────────────────────────────────

fn makePair(gc: *gcmod.GC, car: Value, cdr: Value) !Value {
    const h = try gc.alloc(.pair, 2);
    const b = bodyP(h);
    b[0] = car;
    b[1] = cdr;
    return value_mod.fromPtr(h);
}

// Vector: body[0] = length (raw), body[1..1+len] = Value slots.
fn makeVector(gc: *gcmod.GC, len: usize, fill: Value) !Value {
    const h = try gc.alloc(.vector, 1 + len);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = @as(u64, len);
    var i: usize = 0;
    while (i < len) : (i += 1) bodyP(h)[1 + i] = fill;
    return value_mod.fromPtr(h);
}

fn vecRef(v: Value, i: usize) Value {
    return bodyP(value_mod.ptrVal(v))[1 + i];
}

// String: body[0] = byte length (raw), raw byte tail. Leaf (no Value slots).
fn makeString(gc: *gcmod.GC, bytes: []const u8) !Value {
    const tail_words = (bytes.len + WORD - 1) / WORD;
    const h = try gc.alloc(.string, 1 + tail_words);
    const raw: [*]u8 = @as([*]u8, @ptrCast(h)) + WORD;
    const lenp: *u64 = @ptrCast(@alignCast(raw));
    lenp.* = @as(u64, bytes.len);
    if (bytes.len > 0) @memcpy((raw + WORD)[0..bytes.len], bytes);
    return value_mod.fromPtr(h);
}

// Box: single Value at body[0].
fn makeBox(gc: *gcmod.GC, v: Value) !Value {
    const h = try gc.alloc(.box, 1);
    bodyP(h)[0] = v;
    return value_mod.fromPtr(h);
}

// Closure: body[0..3] raw header words, captures (Values) from body[3].
fn makeClosure(gc: *gcmod.GC, captures: []const Value) !Value {
    const h = try gc.alloc(.closure, 3 + captures.len);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = 0; // code_ptr (raw, unused in test)
    raw[1] = 0; // arity (raw)
    raw[2] = 0; // home_env_ptr (raw)
    var i: usize = 0;
    while (i < captures.len) : (i += 1) bodyP(h)[3 + i] = captures[i];
    return value_mod.fromPtr(h);
}

// Hash table: body[0] = len (raw), body[1] = backing vector (Value).
fn makeHashTable(gc: *gcmod.GC, backing: Value) !Value {
    const h = try gc.alloc(.hash_table, 2);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = 0; // len (raw)
    bodyP(h)[1] = backing;
    return value_mod.fromPtr(h);
}

// Float: body[0] = raw f64. Leaf.
fn makeFloat(gc: *gcmod.GC, f: f64) !Value {
    const h = try gc.alloc(.float, 1);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = @as(u64, @bitCast(f));
    return value_mod.fromPtr(h);
}

const FreeCount = struct {
    var n: usize = 0;
    fn deinit(_: ?*anyopaque) callconv(.c) void {
        n += 1;
    }
};

// Foreign handle wrapped as a Value, with a counting finalizer.
fn makeForeign(gc: *gcmod.GC) !Value {
    const h = try gc.allocForeign(null, FreeCount.deinit, 0xF00D);
    return value_mod.fromPtr(h);
}

test "stress: pair nursery churn — verify after each minor" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const keep = scope.push(try makePair(&gc, value_mod.fixnum(1), value_mod.fixnum(2)));

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var i: i63 = 0;
        while (i < 2000) : (i += 1) {
            _ = try makePair(&gc, value_mod.fixnum(i), value_mod.NIL);
        }
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    // Rooted pair intact.
    const b = bodyP(value_mod.ptrVal(keep.*));
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(b[0]));
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(b[1]));
}

test "stress: vector of rooted pairs survives minor + major" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Vector with 8 NIL slots, rooted.
    const vec = scope.push(try makeVector(&gc, 8, value_mod.NIL));

    // Fill each slot with a fresh pair (young), via write barrier in case the
    // vector promoted. Re-fetch the header each time (it may have moved).
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const p = try makePair(&gc, value_mod.fixnum(@intCast(i)), value_mod.NIL);
        const vh = value_mod.ptrVal(vec.*);
        gc.writeBarrier(vh, &bodyP(vh)[1 + i], p);
        bodyP(vh)[1 + i] = p;
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    try gc.major();
    try gcmod.Verifier.verify(&gc);

    // Every slot still references a pair with the right car.
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const e = vecRef(vec.*, k);
        try std.testing.expect(value_mod.isPtr(e));
        try std.testing.expectEqual(@as(i63, @intCast(k)), value_mod.fixnumVal(bodyP(value_mod.ptrVal(e))[0]));
    }
}

test "stress: every layout shape survives promotion + major" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Build one of each shape, all rooted. A hash table needs a backing
    // vector; build that first and root it too.
    const backing = scope.push(try makeVector(&gc, 4, value_mod.fixnum(0)));
    _ = scope.push(try makePair(&gc, value_mod.fixnum(10), value_mod.fixnum(20)));
    _ = scope.push(try makeString(&gc, "hello generational world"));
    _ = scope.push(try makeBox(&gc, value_mod.fixnum(99)));
    _ = scope.push(try makeClosure(&gc, &.{ value_mod.fixnum(1), value_mod.fixnum(2) }));
    _ = scope.push(try makeHashTable(&gc, backing.*));
    _ = scope.push(try makeFloat(&gc, 3.14159));
    _ = scope.push(try makeForeign(&gc));

    // Age them past PROMOTE_AGE so they all promote to old-gen.
    var n: usize = 0;
    while (n < gcmod.nursery.PROMOTE_AGE + 1) : (n += 1) {
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    try gc.major();
    try gcmod.Verifier.verify(&gc);

    // String content intact after promotion (sanity that raw tails copy).
    // The string is the 3rd handle pushed (index 2).
    const sv = scope.handles[2];
    const raw: [*]u8 = @as([*]u8, @ptrCast(value_mod.ptrVal(sv))) + WORD;
    const lenp: *u64 = @ptrCast(@alignCast(raw));
    try std.testing.expectEqual(@as(u64, 24), lenp.*); // "hello generational world" = 24 bytes
}
