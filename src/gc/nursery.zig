//! Bump-pointer nursery with a Cheney semispace collector.
//!
//! Two semispaces allocated via mmap. `from` is the active allocation space;
//! during a minor collection survivors are copied to `to`, which is then flipped
//! to become the new `from`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const Kind = abi.Kind;
const Space = abi.Space;
const layout_mod = abi.layout;
const value_mod = abi.value;

const oldgen_mod = @import("oldgen.zig");
const OldGen = oldgen_mod.OldGen;
const cards_mod = @import("cards.zig");
const CardTable = cards_mod.CardTable;
const roots_mod = @import("roots.zig");
const RootSet = roots_mod.RootSet;

pub const NURSERY_SIZE: usize = 4 * 1024 * 1024; // zepo-299; zepo-nmqj: now the default cap
pub const PROMOTE_AGE: u4 = 3;
pub const WORD: usize = 8;

pub const Nursery = struct {
    from_start: [*]u8,
    from_end: [*]u8,
    bump: [*]u8,
    to_start: [*]u8,
    to_end: [*]u8,
    /// zepo-nmqj: capacity of each semispace in bytes (configurable at init).
    capacity: usize,

    pub fn init() !Nursery {
        return initWithSize(NURSERY_SIZE);
    }

    /// zepo-nmqj: init with a user-supplied semispace size.
    pub fn initWithSize(bytes: usize) !Nursery {
        const aligned = std.mem.alignForward(usize, bytes, std.heap.page_size_min);
        const from = try mmapAnon(aligned);
        const to = try mmapAnon(aligned);
        return .{
            .from_start = from,
            .from_end = from + aligned,
            .bump = from,
            .to_start = to,
            .to_end = to + aligned,
            .capacity = aligned,
        };
    }

    pub fn deinit(n: *Nursery) void {
        posix.munmap(@alignCast(n.from_start[0..n.capacity]));
        posix.munmap(@alignCast(n.to_start[0..n.capacity]));
        n.* = undefined;
    }

    /// zepo-nmqj: actual configured semispace capacity in bytes.
    pub fn size(n: *const Nursery) usize {
        return n.capacity;
    }

    pub fn alloc(n: *Nursery, size_bytes: usize) ?*ObjHeader {
        const aligned = std.mem.alignForward(usize, size_bytes, WORD);
        const end_addr = @intFromPtr(n.bump) + aligned;
        if (end_addr > @intFromPtr(n.from_end)) return null;
        const p: *ObjHeader = @ptrCast(@alignCast(n.bump));
        n.bump = @ptrFromInt(end_addr);
        return p;
    }

    pub fn contains(n: *const Nursery, ptr: *ObjHeader) bool {
        return inFromSpace(n, ptr) or inToSpace(n, ptr);
    }

    pub fn inFromSpace(n: *const Nursery, ptr: *ObjHeader) bool {
        const a = @intFromPtr(ptr);
        return a >= @intFromPtr(n.from_start) and a < @intFromPtr(n.from_end);
    }

    pub fn inToSpace(n: *const Nursery, ptr: *ObjHeader) bool {
        const a = @intFromPtr(ptr);
        return a >= @intFromPtr(n.to_start) and a < @intFromPtr(n.to_end);
    }

    pub fn used(n: *const Nursery) usize {
        return @intFromPtr(n.bump) - @intFromPtr(n.from_start);
    }

    pub fn free(n: *const Nursery) usize {
        return @intFromPtr(n.from_end) - @intFromPtr(n.bump);
    }
};

fn mmapAnon(size: usize) ![*]u8 {
    const slice = try posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    return slice.ptr;
}

// ========== Cheney collector ==========

pub const CopyCtx = struct {
    nursery: *Nursery,
    old_gen: *OldGen,
    cards: *CardTable,
    /// Scan pointer through to-space (bytes).
    scan: [*]u8,
    /// Bump pointer into to-space (bytes).
    to_bump: [*]u8,
    to_end: [*]u8,
    err: ?anyerror = null,
    /// Promoted objects whose interiors need scanning after the Cheney loop.
    /// Promoted objects land in old-gen (not to-space), so the Cheney scan
    /// pointer never visits them; we must scan them explicitly before the
    /// flip while from-space forwarding pointers are still valid.
    promoted: std.ArrayListUnmanaged(*ObjHeader) = .empty,
};

/// Returns size in BYTES for an object given its header, assuming header-word
/// accurately describes the body size (variable-size objects must embed size).
pub fn objectSizeBytes(h: *const ObjHeader) usize {
    const body_words: usize = @intCast(h.sizeWords());
    return WORD + body_words * WORD;
}

/// Compute total word count for an object whose header is already populated.
pub fn objectBodyWords(h: *const ObjHeader) usize {
    return @intCast(h.sizeWords());
}

pub fn bodyPtr(h: *ObjHeader) [*]u64 {
    const base: [*]u8 = @ptrCast(h);
    return @ptrCast(@alignCast(base + WORD));
}

/// Visit every Value slot in object body according to its layout.
fn forEachValueSlot(h: *ObjHeader, ctx: *anyopaque, fcn: *const fn (*anyopaque, *Value) void) void {
    const desc = layout_mod.layoutForKind(h.kind());
    const body = bodyPtr(h);
    const nwords: usize = @intCast(h.sizeWords());

    // Fixed-offset Value fields.
    for (desc.value_offsets) |off| {
        std.debug.assert(off < nwords);
        const slot: *Value = @ptrCast(&body[off]);
        fcn(ctx, slot);
    }

    // Variable-length Value region (vector, closure captures, env_frame slots).
    if (desc.all_slots_are_values) {
        var i: usize = desc.value_slots_start;
        while (i < nwords) : (i += 1) {
            const slot: *Value = @ptrCast(&body[i]);
            fcn(ctx, slot);
        }
    }
}

fn forwardSlotFn(ctx_raw: *anyopaque, slot: *Value) void {
    const ctx: *CopyCtx = @ptrCast(@alignCast(ctx_raw));
    forwardSlot(ctx, slot);
}

/// If `slot` is a pointer into nursery from-space, copy its target (unless
/// already forwarded) and rewrite the slot. Old-gen pointers and non-pointers
/// are left alone.
fn forwardSlot(ctx: *CopyCtx, slot: *Value) void {
    const v = slot.*;
    if (!value_mod.isPtr(v)) return;
    const obj = value_mod.ptrVal(v);
    if (!ctx.nursery.inFromSpace(obj)) return; // not in collecting space

    // Already forwarded?
    if (obj.isForward()) {
        const target = obj.forwardTo();
        slot.* = value_mod.fromPtr(target);
        return;
    }

    // Otherwise copy (or promote).
    const sz_bytes = objectSizeBytes(obj);
    const should_promote = obj.age() >= PROMOTE_AGE;

    const target: *ObjHeader = blk: {
        if (should_promote) {
            if (ctx.old_gen.promoteRaw(obj, sz_bytes)) |p| {
                // Queue for interior scan after the Cheney loop. We can't scan
                // inline: a deep list would overflow the Zig call stack, and
                // from-space forwarding pointers must still be valid (i.e. we
                // must finish before the flip). The index loop in collect()
                // handles cascading promotions.
                ctx.promoted.append(ctx.old_gen.allocator, p) catch {
                    ctx.err = error.OutOfMemory;
                };
                break :blk p;
            } else |e| {
                ctx.err = e;
                // Fall back to to-space copy on promote failure.
            }
        }
        // To-space copy. If to-space is full, force-promote to old-gen to
        // avoid leaving the heap in a partially-collected state.
        const end_addr = @intFromPtr(ctx.to_bump) + sz_bytes;
        if (end_addr > @intFromPtr(ctx.to_end)) {
            // zepo-svu: queue for interior scan just like the normal promote
            // path does. Without this, the force-promoted object's body fields
            // remain as stale from-space pointers — traversal reads forwarding
            // headers and interprets kind bits from target addresses, producing
            // either CdrOfNonPair or (via garbage kind bits that match .pair)
            // a circular list.
            if (ctx.old_gen.promoteRaw(obj, sz_bytes)) |p| {
                ctx.promoted.append(ctx.old_gen.allocator, p) catch {
                    ctx.err = error.OutOfMemory;
                };
                break :blk p;
            } else |e| {
                ctx.err = e;
                return;
            }
        }
        const dst: *ObjHeader = @ptrCast(@alignCast(ctx.to_bump));
        const src_bytes: [*]const u8 = @ptrCast(obj);
        const dst_bytes: [*]u8 = @ptrCast(dst);
        @memcpy(dst_bytes[0..sz_bytes], src_bytes[0..sz_bytes]);
        dst.setSpace(.nursery_to);
        dst.incAge();
        ctx.to_bump = @ptrFromInt(end_addr);
        break :blk dst;
    };

    obj.setForward(target);
    slot.* = value_mod.fromPtr(target);
}

/// zepo-jus: forward a slot that lives inside an OLD-GEN object, then record
/// the old->young edge if it now points at a young (to-space) survivor. Used
/// only when scanning old objects (dirty cards + promoted interiors), so the
/// young-heavy Cheney loop pays no per-pointer card-marking cost. markCard is
/// a no-op unless `slot` is in the old-gen range, so this is also self-filtering.
/// This rebuilds the remembered set the collector itself dirties — edges the
/// end-of-collect clearAll used to drop, collecting the young target next pass.
fn forwardSlotOld(ctx: *CopyCtx, slot: *Value) void {
    forwardSlot(ctx, slot);
    const v = slot.*;
    if (!value_mod.isPtr(v)) return;
    if (ctx.nursery.contains(value_mod.ptrVal(v))) {
        ctx.cards.markCard(@intFromPtr(slot));
    }
}

fn forwardSlotOldFn(ctx_raw: *anyopaque, slot: *Value) void {
    const ctx: *CopyCtx = @ptrCast(@alignCast(ctx_raw));
    forwardSlotOld(ctx, slot);
}

fn cheneyScanObj(ctx: *CopyCtx, obj: *ObjHeader) void {
    forEachValueSlot(obj, ctx, forwardSlotFn);
}

/// Scan an OLD-GEN object's interior, recording any surviving old->young edges.
fn cheneyScanObjOld(ctx: *CopyCtx, obj: *ObjHeader) void {
    forEachValueSlot(obj, ctx, forwardSlotOldFn);
}

/// Run a minor collection. Roots + remembered set are traced; reachable objects
/// are copied into to-space (or promoted). Then the spaces flip.
pub fn collect(n: *Nursery, og: *OldGen, cards: *CardTable, roots: *RootSet) !void {
    var ctx = CopyCtx{
        .nursery = n,
        .old_gen = og,
        .cards = cards,
        .scan = n.to_start,
        .to_bump = n.to_start,
        .to_end = n.to_end,
    };

    // 1. Roots.
    roots.visitAll(@ptrCast(&ctx), forwardSlotFn);

    // 2. Remembered set: scan dirty old-gen cards for young pointers.
    //    zepo-jus: scanDirtyCards clears each card as it scans it, so
    //    forwardSlot's re-marks (for old->young edges that survive, plus ones
    //    the collector creates by promotion) rebuild the post-collection
    //    remembered set. This replaces the old end-of-collect clearAll, which
    //    dropped collector-created edges and collected their young targets.
    og.scanDirtyCards(cards, &ctx, forwardSlotOldFn);

    // 3. Cheney scan loop.
    while (@intFromPtr(ctx.scan) < @intFromPtr(ctx.to_bump)) {
        const obj: *ObjHeader = @ptrCast(@alignCast(ctx.scan));
        const sz = objectSizeBytes(obj);
        cheneyScanObj(&ctx, obj);
        ctx.scan = @ptrFromInt(@intFromPtr(ctx.scan) + sz);
    }

    // 3.5 Scan promoted-object interiors. Must happen before the flip because
    //     forwarding pointers in from-space are zeroed when to-space is reset.
    //     Index-based loop handles cascading promotions: scanning one promoted
    //     object may promote additional objects, which are appended and then
    //     visited in subsequent iterations.
    //
    //     zepo-svu: a promoted object's interior scan (forwardSlot) may copy
    //     young nursery cells into to-space when to-space has room (freed up
    //     by earlier force-promotions). Step 3's Cheney loop has already
    //     finished, so those copies would never be scanned — their CDR slots
    //     would remain stale from-space pointers and corrupt after the flip.
    //     Fix: drain any new to-space copies after each promoted-object scan.
    {
        var pi: usize = 0;
        while (pi < ctx.promoted.items.len) : (pi += 1) {
            // zepo-jus: promoted objects are now OLD; scan their interiors with
            // the old-object visitor so any slot still pointing at a young
            // survivor is recorded in the remembered set.
            cheneyScanObjOld(&ctx, ctx.promoted.items[pi]);
            // Drain new to-space copies produced by the scan above.
            while (@intFromPtr(ctx.scan) < @intFromPtr(ctx.to_bump)) {
                const obj: *ObjHeader = @ptrCast(@alignCast(ctx.scan));
                const sz = objectSizeBytes(obj);
                cheneyScanObj(&ctx, obj);
                ctx.scan = @ptrFromInt(@intFromPtr(ctx.scan) + sz);
            }
        }
        ctx.promoted.deinit(og.allocator);
    }

    if (ctx.err) |e| return e;

    // 4. Flip: old from-space is garbage. Swap from/to and reset bump.
    //    zepo-jus: the card table is NOT cleared here — forwardSlot rebuilt it
    //    above to hold every surviving old->young edge. Clearing it (as the
    //    old code did) would drop the collector-created edges.
    const old_from = n.from_start;
    const old_from_end = n.from_end;
    n.from_start = n.to_start;
    n.from_end = n.to_end;
    n.bump = ctx.to_bump;
    n.to_start = old_from;
    n.to_end = old_from_end;

    // zepo-299: only zero to-space in debug builds for dangling-pointer detection.
    if (builtin.mode == .Debug) @memset(n.to_start[0..n.capacity], 0);

}

test "nursery alloc/exhaust" {
    var n = try Nursery.init();
    defer n.deinit();
    const cap = n.size();
    try std.testing.expectEqual(cap, n.free());
    const p1 = n.alloc(24) orelse return error.TestUnexpected;
    _ = p1;
    try std.testing.expectEqual(cap - 24, n.free());
}

// zepo-nmqj
test "nursery initWithSize honors custom capacity" {
    var n = try Nursery.initWithSize(16 * 1024 * 1024);
    defer n.deinit();
    try std.testing.expect(n.size() >= 16 * 1024 * 1024);
    try std.testing.expectEqual(n.size(), n.free());
}
