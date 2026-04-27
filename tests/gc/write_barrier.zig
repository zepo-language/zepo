//! GC test: old->young edge installed via the write barrier survives a
//! minor collection.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;
const runtime = zepo.runtime;
const objects = runtime.objects;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;

test "write barrier: old->young edge survives minor GC" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Allocate a pair and root it via a handle; run enough minor GCs to
    // promote it into old-gen.
    const initial = try objects.makePair(&gc, value_mod.fixnum(1), value_mod.fixnum(2));
    const root_slot = scope.push(initial);

    var n: usize = 0;
    while (n < gcmod.nursery.PROMOTE_AGE + 1) : (n += 1) {
        try gc.minor();
    }
    const promoted = root_slot.*;
    const promoted_hdr = value_mod.ptrVal(promoted);
    try std.testing.expect(gc.old_gen.contains(promoted_hdr));

    // Allocate a fresh nursery object.
    const young = try objects.makePair(&gc, value_mod.fixnum(7), value_mod.fixnum(8));
    try std.testing.expect(gc.nursery.contains(value_mod.ptrVal(young)));

    // Install an old->young edge via the write barrier (replace car slot).
    const car_slot = objects.pairCar(promoted);
    gc.writeBarrier(promoted_hdr, car_slot, young);
    car_slot.* = young;

    // Card must be marked dirty.
    const card_idx = gc.cards.cardIndexFor(@intFromPtr(promoted_hdr));
    try std.testing.expect(gc.cards.isCardDirty(card_idx));

    // Minor GC: remembered-set scan should forward car_slot to the new
    // nursery-to location (or promote it); afterward the value chain must
    // still read as the original fixnums.
    try gc.minor();
    try gcmod.Verifier.verify(&gc);

    const after = car_slot.*;
    try std.testing.expect(value_mod.isPtr(after));
    try std.testing.expect(objects.isPair(after));
    try std.testing.expectEqual(@as(i63, 7), value_mod.fixnumVal(objects.pairCar(after).*));
    try std.testing.expectEqual(@as(i63, 8), value_mod.fixnumVal(objects.pairCdr(after).*));
}
