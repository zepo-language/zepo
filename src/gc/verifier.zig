//! Debug-mode GC invariant verifier. Invoked after every collection step.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const layout_mod = abi.layout;

const collector_mod = @import("collector.zig");
const GC = collector_mod.GC;

pub const VerifyError = error{
    DanglingPointer,
    ReachableFromSpaceObject,
    UnmarkedOldYoungEdge,
    HeapNotWalkable,
    CardStartMissing,
};

// zepo-rnr
const WORD: usize = 8;

const Ctx = struct {
    gc: *GC,
    err: ?VerifyError = null,
};

fn visitSlot(ctx_raw: *anyopaque, slot: *Value) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_raw));
    if (ctx.err != null) return;
    const v = slot.*;
    if (!value_mod.isPtr(v)) return;
    const obj = value_mod.ptrVal(v);

    // Must live in either nursery (from-space only after flip) or old-gen.
    const in_nursery_from = ctx.gc.nursery.inFromSpace(obj);
    const in_nursery_to = ctx.gc.nursery.inToSpace(obj);
    const in_old = ctx.gc.old_gen.contains(obj);

    if (!(in_nursery_from or in_old)) {
        if (in_nursery_to) {
            // Rooted pointer still into to-space is a bug post-flip.
            ctx.err = VerifyError.ReachableFromSpaceObject;
            return;
        }
        ctx.err = VerifyError.DanglingPointer;
        return;
    }

    if (obj.isForward()) {
        ctx.err = VerifyError.ReachableFromSpaceObject;
    }
}

pub const Verifier = struct {
    pub fn verify(gc: *GC) !void {
        var ctx = Ctx{ .gc = gc };
        gc.roots.visitAll(@ptrCast(&ctx), visitSlot);
        if (ctx.err) |e| return e;

        // zepo-rnr: walk every live old-gen block. For each Value slot that
        // points into the nursery, the card covering THAT SLOT must be dirty —
        // otherwise the next minor GC cannot find the edge (zepo-jus /
        // spanning-card). The walk also asserts the heap stays walkable.
        try verifyOldGen(gc);
        try verifyCardStarts(gc);
    }

    // zepo-rnr: every dirty card must name a covering object in card_starts,
    // and that object must actually span the card's start address. A dirty
    // card with a null start means a minor GC would skip the card and lose its
    // edges (the spanning-card root cause, zepo-gol).
    fn verifyCardStarts(gc: *GC) !void {
        const og = &gc.old_gen;
        var idx: usize = 0;
        while (idx < gc.cards.table.len) : (idx += 1) {
            if (!gc.cards.isCardDirty(idx)) continue;
            const start = og.card_starts[idx] orelse return VerifyError.CardStartMissing;
            if (!og.contains(start)) return VerifyError.CardStartMissing;
            const sw: usize = @intCast(start.sizeWords());
            if (sw == 0) return VerifyError.CardStartMissing;
            const block_end = @intFromPtr(start) + WORD + sw * WORD;
            const card_begin = gc.cards.cardStart(idx);
            // The covering object must start at or before the card and extend
            // into it.
            if (@intFromPtr(start) > card_begin or block_end <= card_begin)
                return VerifyError.CardStartMissing;
        }
    }

    fn verifyOldGen(gc: *GC) !void {
        const og = &gc.old_gen;
        var p: [*]u8 = og.base;
        while (@intFromPtr(p) < @intFromPtr(og.bump)) {
            const h: *ObjHeader = @ptrCast(@alignCast(p));
            const body_words: usize = @intCast(h.sizeWords());
            if (body_words == 0) return VerifyError.HeapNotWalkable;
            const block_bytes = WORD + body_words * WORD;
            const is_free = @intFromEnum(h.kind()) == 0;
            if (!is_free) try checkSlots(gc, h, body_words);
            p = @ptrFromInt(@intFromPtr(p) + block_bytes);
        }
        // Walk must land exactly on bump, or a sizeWords was wrong.
        if (@intFromPtr(p) != @intFromPtr(og.bump)) return VerifyError.HeapNotWalkable;
    }

    fn checkSlots(gc: *GC, h: *ObjHeader, body_words: usize) !void {
        const desc = layout_mod.layoutForKind(h.kind());
        const body: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
        for (desc.value_offsets) |off| {
            if (off < body_words) try checkSlot(gc, &body[off]);
        }
        if (desc.all_slots_are_values) {
            var i: usize = desc.value_slots_start;
            while (i < body_words) : (i += 1) try checkSlot(gc, &body[i]);
        }
    }

    fn checkSlot(gc: *GC, slot: *u64) !void {
        const v: Value = @bitCast(slot.*);
        if (!value_mod.isPtr(v)) return;
        const tgt = value_mod.ptrVal(v);
        if (!gc.nursery.contains(tgt)) return; // old->old edge: not our concern
        const slot_addr = @intFromPtr(slot);
        const idx = gc.cards.cardIndexFor(slot_addr);
        if (!gc.cards.isCardDirty(idx)) return VerifyError.UnmarkedOldYoungEdge;
    }
};
