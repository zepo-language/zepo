//! Regression for zepo-a7j: GC.alloc's old-gen fallback wrote the object
//! header with the REQUESTED body_words instead of the size-class-rounded
//! block capacity. For a non-class size (e.g. a 1-word box -> rounded to the
//! 2-word size class 0), the header under-reported the block size, so the
//! old-gen heap walk (sweep / major-mark / verifier) desynced and read garbage.
//! promote() already sized correctly via allocWithCap + actual_words.
//!
//! Deterministic trigger: fill the nursery to 8 bytes free with one rooted
//! vector, then allocate a 1-word box. The box cannot fit (and cannot fit even
//! after a minor, since the vector is rooted and survives), so GC.alloc takes
//! the old-gen fallback — placing a body-1 box in old-gen.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;
const WORD: usize = 8;

// zepo-a7j
fn bodyP(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

test "zepo-a7j: a body-1 object forced into the old-gen fallback keeps the heap walkable" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Fill the nursery to exactly 8 free bytes with one rooted vector. A vector
    // body of N words occupies WORD + N*WORD bytes; choose N so the remaining
    // free space is < 16 (a box needs 16) but the vector itself fits.
    const free_target: usize = 8;
    const total = gcmod.nursery.NURSERY_SIZE - free_target; // = WORD + body*WORD
    const body_words = (total - WORD) / WORD;
    const len = body_words - 1; // vector body[0] is the length slot

    const vh = try gc.alloc(.vector, body_words);
    {
        const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(vh)) + WORD));
        raw[0] = @as(u64, len);
        var i: usize = 0;
        while (i < len) : (i += 1) bodyP(vh)[1 + i] = value_mod.NIL;
    }
    _ = scope.push(value_mod.fromPtr(vh));

    // The box (16 bytes) cannot fit in the 8 free bytes; a minor cannot free
    // the rooted vector, so GC.alloc falls back to old-gen.
    const box = try gc.alloc(.box, 1);
    bodyP(box)[0] = value_mod.fixnum(123);
    _ = scope.push(value_mod.fromPtr(box)); // root so a major keeps it

    // The box must really be in old-gen (the fallback fired).
    try std.testing.expect(gc.old_gen.contains(box));

    // The old-gen heap must be walkable: pre-fix the box header claimed 1 body
    // word while its block is 2, so the verifier's walk desynced
    // (HeapNotWalkable). Post-fix the header carries the true capacity.
    try gcmod.Verifier.verify(&gc);

    // And a major over it must keep the box intact.
    try gc.major();
    try gcmod.Verifier.verify(&gc);
    try std.testing.expectEqual(@as(i63, 123), value_mod.fixnumVal(bodyP(box)[0]));
}
