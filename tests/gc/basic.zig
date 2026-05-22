//! Phase 1 GC correctness tests.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const header_mod = abi.header;
const Kind = abi.Kind;

/// Build a pair with car/cdr. Caller must ensure GC roots are set up before
/// calling so that allocation-induced minor GC preserves the inputs.
fn makePair(gc: *gcmod.GC, car: Value, cdr: Value) !Value {
    const h = try gc.alloc(.pair, 2);
    const body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + 8));
    body[0] = car;
    body[1] = cdr;
    return value_mod.fromPtr(h);
}

fn pairCar(v: Value) Value {
    const h = value_mod.ptrVal(v);
    const body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + 8));
    return body[0];
}

fn pairCdr(v: Value) Value {
    const h = value_mod.ptrVal(v);
    const body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + 8));
    return body[1];
}

fn setPairCdr(v: Value, new_cdr: Value) void {
    const h = value_mod.ptrVal(v);
    const body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + 8));
    body[1] = new_cdr;
}

test "retain every 3rd pair across minor GC" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Build 1000 pairs, retaining every 3rd via handle scope (up to scope capacity).
    var retained: [gcmod.roots.HANDLE_SCOPE_CAPACITY]*Value = undefined;
    var retained_count: usize = 0;
    var retained_expected: [gcmod.roots.HANDLE_SCOPE_CAPACITY]i63 = undefined;

    var i: i63 = 0;
    while (i < 1000) : (i += 1) {
        const p = try makePair(&gc, value_mod.fixnum(i), value_mod.fixnum(i * 2));
        if (@mod(@as(usize, @intCast(i)), 3) == 0 and retained_count < gcmod.roots.HANDLE_SCOPE_CAPACITY) {
            const slot = scope.push(p);
            retained[retained_count] = slot;
            retained_expected[retained_count] = i;
            retained_count += 1;
        }
    }

    try gc.minor();
    try gcmod.Verifier.verify(&gc);

    // Verify retained pairs still have correct values.
    var k: usize = 0;
    while (k < retained_count) : (k += 1) {
        const v = retained[k].*;
        try std.testing.expect(value_mod.isPtr(v));
        try std.testing.expectEqual(
            retained_expected[k],
            value_mod.fixnumVal(pairCar(v)),
        );
        try std.testing.expectEqual(
            retained_expected[k] * 2,
            value_mod.fixnumVal(pairCdr(v)),
        );
    }
}

test "auto minor GC when nursery exhausted" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Allocate many short-lived pairs. Without any root they should all be
    // reclaimed, but the auto-GC in alloc() must keep the heap consistent.
    // Each pair = 24 bytes => nursery (512 KB) holds ~21,000 pairs; loop
    // beyond that to force at least one minor GC.
    var i: i63 = 0;
    while (i < 40_000) : (i += 1) {
        _ = try makePair(&gc, value_mod.fixnum(i), value_mod.NIL);
    }
    try gcmod.Verifier.verify(&gc);
}

test "write barrier marks card for old->young edge" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    // Directly allocate a pair in old-gen.
    const old_h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    old_h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const old_body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(old_h)) + 8));
    old_body[0] = value_mod.NIL;
    old_body[1] = value_mod.NIL;

    // Allocate a young pair in the nursery.
    const young_h = try gc.alloc(.pair, 2);
    const young_body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(young_h)) + 8));
    young_body[0] = value_mod.fixnum(7);
    young_body[1] = value_mod.NIL;

    // Write young into old via write barrier.
    const young_val = value_mod.fromPtr(young_h);
    gc.writeBarrier(old_h, &old_body[1], young_val);
    old_body[1] = young_val;

    // Card covering old_h must be dirty.
    const card_idx = gc.cards.cardIndexFor(@intFromPtr(old_h));
    try std.testing.expect(gc.cards.isCardDirty(card_idx));
}

test "promotion after surviving PROMOTE_AGE minor GCs" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const p = try makePair(&gc, value_mod.fixnum(99), value_mod.fixnum(100));
    const slot = scope.push(p);

    // Run enough minor GCs to promote.
    var n: usize = 0;
    while (n < gcmod.nursery.PROMOTE_AGE + 1) : (n += 1) {
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    const final = slot.*;
    try std.testing.expect(value_mod.isPtr(final));
    const h = value_mod.ptrVal(final);
    try std.testing.expect(gc.old_gen.contains(h));
    try std.testing.expectEqual(@as(i63, 99), value_mod.fixnumVal(pairCar(final)));
    try std.testing.expectEqual(@as(i63, 100), value_mod.fixnumVal(pairCdr(final)));
}

test "major GC sweeps unreachable old-gen objects" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    // Allocate some objects directly in old-gen, none rooted.
    var i: usize = 0;
    var count_before: usize = 0;
    while (i < 100) : (i += 1) {
        const h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
        h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
        const body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + 8));
        body[0] = value_mod.fixnum(@intCast(i));
        body[1] = value_mod.NIL;
        count_before += 1;
    }

    // All unreachable => major GC should reclaim them to free lists.
    try gc.major();
    try gcmod.Verifier.verify(&gc);

    // After sweep, at least size class 0 (body 2) free list should be non-empty.
    try std.testing.expect(gc.old_gen.free_lists[0] != null);
}

test "fixnum and char round trip through GC" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const p = try makePair(&gc, value_mod.fixnum(-12345), value_mod.char('Z'));
    const slot = scope.push(p);

    try gc.minor();
    try gcmod.Verifier.verify(&gc);

    const v = slot.*;
    try std.testing.expectEqual(@as(i63, -12345), value_mod.fixnumVal(pairCar(v)));
    try std.testing.expectEqual(@as(u21, 'Z'), value_mod.charVal(pairCdr(v)));
}

// zepo-svu: regression test for the drain-loop fix in collect() step 3.5.
//
// Scenario: object A reaches PROMOTE_AGE and is promoted during a minor GC.
// A points to young pair B which points to young pair C (neither B nor C is
// directly rooted — only reachable through A). During step 3.5, scanning
// promoted-A calls forwardSlot on A.cdr, which copies B into to-space. B's
// CDR (pointing at C) must then also be forwarded. Without the drain loop that
// was added for zepo-svu, B in to-space retains a stale from-space CDR; after
// the flip and debug-mode zeroing, traversal of B.cdr hits zeroed memory and
// the list is corrupted.
test "zepo-svu: promoted object interior scan drains to-space copies" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Allocate A = (1 . NIL) and root it. B and C are created later so they
    // remain young when A is promoted.
    const a_slot = scope.push(try makePair(&gc, value_mod.fixnum(1), value_mod.NIL));

    // Age A to PROMOTE_AGE without promoting it yet (needs one more GC to promote).
    var n: usize = 0;
    while (n < gcmod.nursery.PROMOTE_AGE) : (n += 1) {
        try gc.minor();
    }
    // A is still in the nursery (age == PROMOTE_AGE; the next GC will promote).
    try std.testing.expect(!gc.old_gen.contains(value_mod.ptrVal(a_slot.*)));

    // Build chain B = (2 . C), C = (3 . NIL). No extra roots; only A.cdr will
    // keep B and C live. Allocating 2 pairs won't fill the nursery, so no
    // auto-GC occurs and the un-rooted Values are safe for these two lines.
    const c_val = try makePair(&gc, value_mod.fixnum(3), value_mod.NIL);
    const b_val = try makePair(&gc, value_mod.fixnum(2), c_val);

    // Attach B to A. A is in nursery (not old-gen) so no write barrier needed.
    setPairCdr(a_slot.*, b_val);

    // This minor GC promotes A (age == PROMOTE_AGE). B and C are young (age 0)
    // so they are copied into to-space during step 3.5's scan of promoted-A.
    // The drain loop must scan B after it lands in to-space so that B.cdr → C
    // is also forwarded; without it B.cdr remains a stale from-space pointer.
    try gc.minor();
    try gcmod.Verifier.verify(&gc);

    // A must be in old-gen now.
    const a_final = a_slot.*;
    try std.testing.expect(gc.old_gen.contains(value_mod.ptrVal(a_final)));

    // B must be reachable from A and have car=2.
    const b_from_a = pairCdr(a_final);
    try std.testing.expect(value_mod.isPtr(b_from_a));
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(pairCar(b_from_a)));

    // C must be reachable from B and have car=3, cdr=NIL.
    const c_from_b = pairCdr(b_from_a);
    try std.testing.expect(value_mod.isPtr(c_from_b));
    try std.testing.expectEqual(@as(i63, 3), value_mod.fixnumVal(pairCar(c_from_b)));
    try std.testing.expect(!value_mod.isPtr(pairCdr(c_from_b)));
}
