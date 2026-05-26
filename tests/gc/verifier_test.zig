//! Tests that the GC invariant verifier actually rejects broken heaps.
//! Each test deliberately constructs an invariant violation and asserts the
//! verifier returns the matching error — proving the checks have teeth.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;

const WORD: usize = 8;

// zepo-rnr
fn body(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

test "verifier rejects old->young edge on a clean card" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    // Old-gen pair, slots NIL for now.
    const old_h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    old_h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const ob = body(old_h);
    ob[0] = value_mod.NIL;
    ob[1] = value_mod.NIL;

    // Young pair in the nursery.
    const young_h = try gc.alloc(.pair, 2);
    const yb = body(young_h);
    yb[0] = value_mod.fixnum(7);
    yb[1] = value_mod.NIL;

    // Store the young pointer into the old object WITHOUT the write barrier,
    // so the card stays clean — exactly the corruption zepo-jus produced.
    ob[1] = value_mod.fromPtr(young_h);

    try std.testing.expectError(
        gcmod.verifier.VerifyError.UnmarkedOldYoungEdge,
        gcmod.Verifier.verify(&gc),
    );
}

test "verifier passes when the old->young edge's card is dirty" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    const old_h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    old_h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const ob = body(old_h);
    ob[0] = value_mod.NIL;
    ob[1] = value_mod.NIL;

    const young_h = try gc.alloc(.pair, 2);
    const yb = body(young_h);
    yb[0] = value_mod.fixnum(7);
    yb[1] = value_mod.NIL;

    const young_val = value_mod.fromPtr(young_h);
    gc.writeBarrier(old_h, &ob[1], young_val); // marks the card
    ob[1] = young_val;

    try gcmod.Verifier.verify(&gc); // must NOT error
}

test "verifier rejects a corrupted (zero-size) old-gen header" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    const h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const b = body(h);
    b[0] = value_mod.NIL;
    b[1] = value_mod.NIL;

    // Corrupt the size field to 0 — the heap walker would stall here.
    h.word = (h.word & ~ObjHeader.SIZE_MASK);

    try std.testing.expectError(
        gcmod.verifier.VerifyError.HeapNotWalkable,
        gcmod.Verifier.verify(&gc),
    );
}
