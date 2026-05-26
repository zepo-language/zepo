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
