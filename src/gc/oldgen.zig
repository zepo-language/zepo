//! Old generation: segregated free-list mark-sweep.
//!
//! Backing store is a single contiguous mmap region so the card table can map
//! object addresses to card indices. Allocations are carved out of size-class
//! free lists; "large" objects (> max size class) fall back to a simple linear
//! allocator inside the same region (no separate large-obj space yet).
//!
//! Mark phase: traverse reachable objects from roots + remembered set, setting
//! the mark bit in each header. We explicitly do NOT descend into nursery
//! objects (the nursery collects itself).
//!
//! Sweep phase: linearly scan the region. Each allocated block carries a size
//! so we can walk the heap. Unmarked blocks are added to a free list of their
//! size class. Marked objects have their mark bit cleared.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const Kind = abi.Kind;
const Space = abi.Space;
const layout_mod = abi.layout;
const value_mod = abi.value;

const cards_mod = @import("cards.zig");
const CardTable = cards_mod.CardTable;
const roots_mod = @import("roots.zig");
const RootSet = roots_mod.RootSet;

pub const OLD_GEN_SIZE: usize = 4 * 1024 * 1024; // 4 MiB default
pub const WORD: usize = 8;

pub const SIZE_CLASSES = [_]usize{ 2, 3, 4, 6, 8, 12, 16, 32, 64 };

fn sizeClassIndex(body_words: usize) ?usize {
    for (SIZE_CLASSES, 0..) |c, i| {
        if (body_words <= c) return i;
    }
    return null;
}

/// Free list node stored in-place inside a free block. Layout:
///   word 0 = ObjHeader-shaped word with Kind=0 (reserved/free) and size_words
///            set so the heap remains walkable.
///   word 1 = next free block pointer (or null).
const FreeNode = extern struct {
    hdr: ObjHeader,
    next: ?*FreeNode,
};

pub const OldGen = struct {
    allocator: std.mem.Allocator,
    base: [*]u8,
    end: [*]u8,
    bump: [*]u8, // high-water mark; beyond this is virgin memory
    size: usize,
    free_lists: [SIZE_CLASSES.len]?*FreeNode,
    /// Free list for large objects (body_words > last size class).
    /// Nodes share the same FreeNode layout; their `hdr.sizeWords()` gives
    /// the body-word capacity of the block.
    large_free_list: ?*FreeNode,
    /// Per-card starting object (for precise remembered-set scanning).
    /// Indexed by card index; null means no object begins in that card
    /// (object may span from a previous card).
    card_starts: []?*ObjHeader,

    pub fn init(allocator: std.mem.Allocator) !OldGen {
        const buf = try allocator.alignedAlloc(u8, .@"8", OLD_GEN_SIZE);
        @memset(buf, 0);
        var lists: [SIZE_CLASSES.len]?*FreeNode = undefined;
        for (&lists) |*l| l.* = null;
        const n_cards = (OLD_GEN_SIZE + cards_mod.CARD_SIZE - 1) / cards_mod.CARD_SIZE;
        const card_starts = try allocator.alloc(?*ObjHeader, n_cards);
        @memset(card_starts, null);
        return .{
            .allocator = allocator,
            .base = buf.ptr,
            .end = buf.ptr + OLD_GEN_SIZE,
            .bump = buf.ptr,
            .size = OLD_GEN_SIZE,
            .free_lists = lists,
            .large_free_list = null,
            .card_starts = card_starts,
        };
    }

    pub fn deinit(og: *OldGen) void {
        og.allocator.free(og.card_starts);
        const slice: []align(8) u8 = @alignCast(og.base[0..og.size]);
        og.allocator.free(slice);
        og.* = undefined;
    }

    fn cardIdx(og: *const OldGen, h: *ObjHeader) usize {
        return (@intFromPtr(h) - @intFromPtr(og.base)) / cards_mod.CARD_SIZE;
    }

    fn recordCardStart(og: *OldGen, h: *ObjHeader) void {
        const idx = og.cardIdx(h);
        if (idx >= og.card_starts.len) return;
        if (og.card_starts[idx] == null) og.card_starts[idx] = h;
    }

    pub fn contains(og: *const OldGen, ptr: *ObjHeader) bool {
        const a = @intFromPtr(ptr);
        return a >= @intFromPtr(og.base) and a < @intFromPtr(og.end);
    }

    pub fn baseAddr(og: *const OldGen) usize {
        return @intFromPtr(og.base);
    }

    pub fn heapSize(og: *const OldGen) usize {
        return og.size;
    }

    pub const AllocResult = struct {
        hdr: *ObjHeader,
        actual_words: usize,
    };

    /// Allocate body-size `body_words` words. Returns a pointer to the header
    /// and the actual body-word capacity of the block (>= body_words due to
    /// size-class rounding). Caller sets the header fully.
    pub fn allocWithCap(og: *OldGen, body_words: usize) ?AllocResult {
        const class_idx = sizeClassIndex(body_words);
        const block_body_words = if (class_idx) |i| SIZE_CLASSES[i] else body_words;
        const block_bytes = WORD + block_body_words * WORD;

        // Try free list.
        if (class_idx) |idx| {
            if (og.free_lists[idx]) |node| {
                og.free_lists[idx] = node.next;
                const p: *ObjHeader = @ptrCast(node);
                @memset(@as([*]u8, @ptrCast(p))[0..block_bytes], 0);
                og.recordCardStart(p);
                return AllocResult{ .hdr = p, .actual_words = block_body_words };
            }
        } else {
            // Large-object path: walk the large free list, first-fit by
            // capacity (stored as sizeWords on the free node header).
            var prev: ?*FreeNode = null;
            var cur = og.large_free_list;
            while (cur) |node| : ({
                prev = node;
                cur = node.next;
            }) {
                const cap_words: usize = @intCast(node.hdr.sizeWords());
                if (cap_words >= body_words) {
                    // Unlink.
                    if (prev) |pr| pr.next = node.next else og.large_free_list = node.next;
                    const p: *ObjHeader = @ptrCast(node);
                    const cap_bytes = WORD + cap_words * WORD;
                    @memset(@as([*]u8, @ptrCast(p))[0..cap_bytes], 0);
                    og.recordCardStart(p);
                    return AllocResult{ .hdr = p, .actual_words = cap_words };
                }
            }
        }

        // Bump-alloc virgin memory.
        const new_bump = @intFromPtr(og.bump) + block_bytes;
        if (new_bump > @intFromPtr(og.end)) return null;
        const p: *ObjHeader = @ptrCast(@alignCast(og.bump));
        og.bump = @ptrFromInt(new_bump);
        @memset(@as([*]u8, @ptrCast(p))[0..block_bytes], 0);
        og.recordCardStart(p);
        return AllocResult{ .hdr = p, .actual_words = block_body_words };
    }

    /// Allocate body-size `body_words` words. Returns a pointer to the header,
    /// with a size-class block carved out. Caller sets the header fully.
    pub fn alloc(og: *OldGen, body_words: usize) ?*ObjHeader {
        const r = og.allocWithCap(body_words) orelse return null;
        return r.hdr;
    }

    /// Copy a nursery object into old-gen, preserving body words.
    /// Returns the new old-gen pointer.
    pub fn promote(og: *OldGen, obj: *ObjHeader) !*ObjHeader {
        const body_words: usize = @intCast(obj.sizeWords());
        const sz_bytes = WORD + body_words * WORD;
        return og.promoteRaw(obj, sz_bytes) catch |e| return e;
    }

    pub fn promoteRaw(og: *OldGen, obj: *ObjHeader, sz_bytes: usize) !*ObjHeader {
        const body_words = (sz_bytes - WORD) / WORD;
        const r = og.allocWithCap(body_words) orelse return error.OldGenOOM;
        const dst = r.hdr;
        const src_bytes: [*]const u8 = @ptrCast(obj);
        const dst_bytes: [*]u8 = @ptrCast(dst);
        // Copy the body words only (skip source header, which carries the
        // source's sizeWords). We'll write a fresh header below using the
        // destination block's actual capacity.
        if (sz_bytes > WORD) {
            @memcpy(dst_bytes[WORD..sz_bytes], src_bytes[WORD..sz_bytes]);
        }
        // Write a correct destination header: same kind/layout as source,
        // space=old_gen, sizeWords=actual allocated capacity (not source size).
        dst.* = ObjHeader.init(
            obj.kind(),
            .old_gen,
            obj.layoutDescId(),
            @intCast(r.actual_words),
        );
        return dst;
    }

    // ===== Heap walking =====

    /// Iterate every allocated block between base and bump. Each block, live or
    /// free, is identified by its header word (Kind != 0 => live; Kind == 0 =>
    /// free node). `sizeWords` must be accurate for both.
    pub fn walk(og: *OldGen, ctx: *anyopaque, cb: *const fn (*anyopaque, *ObjHeader, bool) void) void {
        var p: [*]u8 = og.base;
        while (@intFromPtr(p) < @intFromPtr(og.bump)) {
            const h: *ObjHeader = @ptrCast(@alignCast(p));
            const body_words: usize = @intCast(h.sizeWords());
            const block_bytes = WORD + body_words * WORD;
            const is_free = @intFromEnum(h.kind()) == 0;
            cb(ctx, h, is_free);
            p = @ptrFromInt(@intFromPtr(p) + block_bytes);
        }
    }

    // ===== Mark/Sweep =====

    const MarkCtx = struct {
        og: *OldGen,
        /// Optional ptr-to-nursery so mark skips nursery descendants (they are
        /// collected by minor GC; or during a major GC a minor runs first).
        nursery_from_start: usize = 0,
        nursery_from_end: usize = 0,
    };

    fn isInNursery(mc: *const MarkCtx, addr: usize) bool {
        return addr >= mc.nursery_from_start and addr < mc.nursery_from_end;
    }

    fn markSlot(ctx_raw: *anyopaque, slot: *Value) void {
        const mc: *MarkCtx = @ptrCast(@alignCast(ctx_raw));
        markValue(mc, slot.*);
    }

    fn markValue(mc: *MarkCtx, v: Value) void {
        if (!value_mod.isPtr(v)) return;
        const obj = value_mod.ptrVal(v);
        const a = @intFromPtr(obj);
        if (!mc.og.contains(obj)) {
            // Nursery-resident survivor: minor already kept it alive (it's
            // reachable from roots). We don't set a mark bit here — nursery
            // doesn't use one — but we must still trace its children so any
            // old-gen descendants they reference get marked by the major.
            // Without this, a young object holding the only reference to an
            // old-gen object (e.g. a freshly-allocated pair wrapping an FFI
            // foreign handle) would let the old-gen target be reclaimed.
            if (isInNursery(mc, a)) traceChildren(mc, obj);
            return;
        }
        if (obj.marked()) return;
        obj.setMark();
        traceChildren(mc, obj);
    }

    fn traceChildren(mc: *MarkCtx, h: *ObjHeader) void {
        const desc = layout_mod.layoutForKind(h.kind());
        const body: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
        const nwords: usize = @intCast(h.sizeWords());

        for (desc.value_offsets) |off| {
            std.debug.assert(off < nwords);
            markValue(mc, body[off]);
        }
        if (desc.all_slots_are_values) {
            var i: usize = desc.value_slots_start;
            while (i < nwords) : (i += 1) markValue(mc, body[i]);
        }
    }

    pub fn mark(og: *OldGen, roots: *RootSet, cards: *CardTable, nursery_from: [*]u8, nursery_from_len: usize) void {
        _ = cards; // cards are for minor, not major
        var mc = MarkCtx{
            .og = og,
            .nursery_from_start = @intFromPtr(nursery_from),
            .nursery_from_end = @intFromPtr(nursery_from) + nursery_from_len,
        };
        roots.visitAll(@ptrCast(&mc), markSlot);
    }

    const SweepCtx = struct {
        og: *OldGen,
    };

    fn sweepVisit(ctx_raw: *anyopaque, h: *ObjHeader, is_free: bool) void {
        const sc: *SweepCtx = @ptrCast(@alignCast(ctx_raw));
        const body_words: usize = @intCast(h.sizeWords());
        if (is_free) {
            // Previously-free block: re-link it into its appropriate free list
            // (we reset all free lists at sweep start).
            if (sizeClassIndex(body_words)) |class_idx| {
                const node: *FreeNode = @ptrCast(h);
                node.next = sc.og.free_lists[class_idx];
                sc.og.free_lists[class_idx] = node;
            } else {
                const node: *FreeNode = @ptrCast(h);
                node.next = sc.og.large_free_list;
                sc.og.large_free_list = node;
            }
            return;
        }
        if (h.marked()) {
            h.clearMark();
            return;
        }
        // Run finalizer on foreign handles before reclaiming. Body layout:
        // body[0]=payload, body[1]=deinit fn, body[2]=type tag. A zero deinit
        // slot means "no finalizer".
        if (h.kind() == .foreign) {
            const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + WORD);
            const deinit_raw = body[1];
            if (deinit_raw != 0) {
                const payload_raw = body[0];
                const payload: ?*anyopaque = if (payload_raw == 0) null else @ptrFromInt(@as(usize, @intCast(payload_raw)));
                const fn_ptr: *const fn (?*anyopaque) callconv(.c) void = @ptrFromInt(@as(usize, @intCast(deinit_raw)));
                fn_ptr(payload);
            }
        }
        // Reclaim: turn into a free node. Preserve sizeWords so the heap stays
        // walkable; zero the Kind so it is "free".
        h.word = (h.word & ~@as(u64, ObjHeader.KIND_MASK));
        const node: *FreeNode = @ptrCast(h);
        if (sizeClassIndex(body_words)) |class_idx| {
            node.next = sc.og.free_lists[class_idx];
            sc.og.free_lists[class_idx] = node;
        } else {
            // Large object: push to large free list.
            node.next = sc.og.large_free_list;
            sc.og.large_free_list = node;
        }
    }

    /// Walk every live object in old-gen and invoke deinit on any foreign
    /// handle. Used at GC teardown so FFI payloads (allocated on the std
    /// heap) are freed even when the host is exiting and roots are already
    /// being dismantled.
    pub fn runAllFinalizers(og: *OldGen) void {
        const WalkCtx = struct {};
        const cb = struct {
            fn visit(_: *anyopaque, h: *ObjHeader, is_free: bool) void {
                if (is_free) return;
                if (h.kind() != .foreign) return;
                const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + WORD);
                const deinit_raw = body[1];
                if (deinit_raw == 0) return;
                const payload_raw = body[0];
                const payload: ?*anyopaque = if (payload_raw == 0) null else @ptrFromInt(@as(usize, @intCast(payload_raw)));
                const fn_ptr: *const fn (?*anyopaque) callconv(.c) void = @ptrFromInt(@as(usize, @intCast(deinit_raw)));
                fn_ptr(payload);
                // Null the deinit so a subsequent sweep does not re-fire.
                body[1] = 0;
            }
        };
        var ctx: WalkCtx = .{};
        og.walk(@ptrCast(&ctx), cb.visit);
    }

    pub fn sweep(og: *OldGen) void {
        // Reset free lists; we'll rebuild them. This avoids referencing already-
        // freed nodes that may have been reclaimed multiple times.
        for (&og.free_lists) |*l| l.* = null;
        og.large_free_list = null;
        var sc = SweepCtx{ .og = og };
        og.walk(@ptrCast(&sc), sweepVisit);

        // Invariant check (debug only): card_starts[i], when non-null, must
        // still point at a valid block head — either a live object (kind != 0)
        // or a free node (kind == 0) with a positive sizeWords. This catches
        // card_starts staleness before it silently corrupts the heap walker.
        if (builtin.mode == .Debug) {
            for (og.card_starts) |maybe_start| {
                const hdr = maybe_start orelse continue;
                std.debug.assert(og.contains(hdr));
                std.debug.assert(hdr.sizeWords() > 0);
            }
        }
    }

    /// Scan all objects touched by dirty cards, invoking `visit` on every Value
    /// slot so that forwarder callbacks can update old->young edges.
    pub fn scanDirtyCards(
        og: *OldGen,
        cards: *CardTable,
        ctx: *anyopaque,
        visit: *const fn (*anyopaque, *Value) void,
    ) void {
        // Iterate the card table; for each dirty card, walk only objects
        // starting in that card (using the per-card start index). Objects
        // spanning multiple cards are scanned once via the card they begin in.
        var card_idx: usize = 0;
        const n_cards = cards.table.len;
        while (card_idx < n_cards) : (card_idx += 1) {
            if (!cards.isCardDirty(card_idx)) continue;
            const start_obj = og.card_starts[card_idx] orelse continue;
            const card_end_addr = @intFromPtr(og.base) + (card_idx + 1) * cards_mod.CARD_SIZE;

            var p: [*]u8 = @ptrCast(start_obj);
            const bump_addr = @intFromPtr(og.bump);
            while (@intFromPtr(p) < card_end_addr and @intFromPtr(p) < bump_addr) {
                const h: *ObjHeader = @ptrCast(@alignCast(p));
                const body_words: usize = @intCast(h.sizeWords());
                const block_bytes = WORD + body_words * WORD;
                const is_free = @intFromEnum(h.kind()) == 0;
                if (!is_free) {
                    const desc = layout_mod.layoutForKind(h.kind());
                    const body: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
                    for (desc.value_offsets) |off| {
                        if (off < body_words) {
                            const slot: *Value = @ptrCast(&body[off]);
                            visit(ctx, slot);
                        }
                    }
                    if (desc.all_slots_are_values) {
                        var i: usize = desc.value_slots_start;
                        while (i < body_words) : (i += 1) {
                            const slot: *Value = @ptrCast(&body[i]);
                            visit(ctx, slot);
                        }
                    }
                }
                p = @ptrFromInt(@intFromPtr(p) + block_bytes);
            }
        }
    }
};

test "oldgen size class selection" {
    try std.testing.expectEqual(@as(?usize, 0), sizeClassIndex(2));
    try std.testing.expectEqual(@as(?usize, 0), sizeClassIndex(1));
    try std.testing.expectEqual(@as(?usize, 1), sizeClassIndex(3));
    try std.testing.expectEqual(@as(?usize, 8), sizeClassIndex(64));
    try std.testing.expectEqual(@as(?usize, null), sizeClassIndex(100));
}
