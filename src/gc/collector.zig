//! Top-level GC facade that orchestrates nursery, old-gen, card table, roots.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const Kind = abi.Kind;
const Space = abi.Space;
const layout_mod = abi.layout;
const value_mod = abi.value;

pub const nursery_mod = @import("nursery.zig");
pub const oldgen_mod = @import("oldgen.zig");
pub const cards_mod = @import("cards.zig");
pub const roots_mod = @import("roots.zig");

pub const Nursery = nursery_mod.Nursery;
pub const OldGen = oldgen_mod.OldGen;
pub const CardTable = cards_mod.CardTable;
pub const RootSet = roots_mod.RootSet;
pub const HandleScope = roots_mod.HandleScope;
pub const WORD: usize = 8;

/// RAII guard that asserts no GC collection fires while in scope (debug builds
/// only). Nest freely — the depth counter handles recursive/overlapping scopes.
/// Usage:
///   var guard = gc.noCollect();
///   defer guard.release();
pub const NoCollectGuard = struct {
    gc: if (builtin.mode == .Debug) *GC else void,

    pub fn release(g: *NoCollectGuard) void {
        if (builtin.mode != .Debug) return;
        g.gc.no_gc_depth -= 1;
    }
};

pub const GC = struct {
    allocator: std.mem.Allocator,
    nursery: Nursery,
    old_gen: OldGen,
    cards: CardTable,
    roots: RootSet,
    /// Debug-only nesting counter for noCollect guards. Zero means collections
    /// are allowed; nonzero means a guard is active and minor() will panic.
    no_gc_depth: if (builtin.mode == .Debug) u32 else void =
        if (builtin.mode == .Debug) 0 else {},
    /// Lifetime collection counters — always tracked, cheap, useful for gc-stats.
    minor_count: u64 = 0,
    major_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !GC {
        var nursery = try Nursery.init();
        errdefer nursery.deinit();
        var old_gen = try OldGen.init(allocator);
        errdefer old_gen.deinit();
        const cards = try CardTable.init(allocator, old_gen.baseAddr(), old_gen.heapSize());
        return .{
            .allocator = allocator,
            .nursery = nursery,
            .old_gen = old_gen,
            .cards = cards,
            .roots = .{},
        };
    }

    pub fn deinit(gc: *GC) void {
        // Run finalizers on every live foreign handle before tearing down
        // oldgen storage — otherwise std-allocator-backed FFI payloads leak
        // when the host shuts down with live handles.
        gc.old_gen.runAllFinalizers();
        gc.roots.deinit(gc.allocator);
        gc.cards.deinit(gc.allocator);
        gc.old_gen.deinit();
        gc.nursery.deinit();
        gc.* = undefined;
    }

    /// Allocate an object of the given kind with `body_words` body words.
    /// If the nursery is full, a minor collection is triggered automatically
    /// before retrying. If still full, OldGen is used as fallback.
    pub fn alloc(gc: *GC, kind: Kind, body_words: usize) !*ObjHeader {
        const sz_bytes = WORD + body_words * WORD;
        if (gc.nursery.alloc(sz_bytes)) |p| {
            p.* = ObjHeader.init(kind, .nursery_from, @intFromEnum(kind), @intCast(body_words));
            return p;
        }
        // Minor GC then retry.
        try gc.minor();
        if (gc.nursery.alloc(sz_bytes)) |p| {
            p.* = ObjHeader.init(kind, .nursery_from, @intFromEnum(kind), @intCast(body_words));
            return p;
        }
        // Fallback to old-gen.
        const p = gc.old_gen.alloc(body_words) orelse return error.OutOfMemory;
        p.* = ObjHeader.init(kind, .old_gen, @intFromEnum(kind), @intCast(body_words));
        return p;
    }

    /// Allocate a foreign-handle object directly in old-gen. Bypasses the
    /// nursery so finalizers only ever run from the mark-sweep path
    /// (finalizers in the Cheney nursery would need a dead-object walk —
    /// unnecessary complexity for typically long-lived foreign handles).
    ///
    /// Body layout:
    ///   body[0] = payload pointer (raw)
    ///   body[1] = deinit fn pointer (raw, 0 = none)
    ///   body[2] = type tag (raw u64, caller-defined discriminator)
    pub fn allocForeign(
        gc: *GC,
        payload: ?*anyopaque,
        deinit_fn: ?*const fn (?*anyopaque) callconv(.c) void,
        type_tag: u64,
    ) !*ObjHeader {
        return gc.allocForeignRaw(@intFromPtr(payload), deinit_fn, type_tag);
    }

    /// Lower-level constructor that takes the payload as raw u64 bits. Used
    /// for primitives whose value is encoded inline (int/float/bool) rather
    /// than behind a pointer.
    pub fn allocForeignRaw(
        gc: *GC,
        payload_bits: u64,
        deinit_fn: ?*const fn (?*anyopaque) callconv(.c) void,
        type_tag: u64,
    ) !*ObjHeader {
        const body_words: usize = 3;
        const p = gc.old_gen.alloc(body_words) orelse return error.OutOfMemory;
        p.* = ObjHeader.init(.foreign, .old_gen, @intFromEnum(Kind.foreign), @intCast(body_words));
        const body: [*]u64 = @ptrFromInt(@intFromPtr(p) + WORD);
        body[0] = payload_bits;
        body[1] = @intFromPtr(deinit_fn);
        body[2] = type_tag;
        return p;
    }

    pub fn minor(gc: *GC) !void {
        if (builtin.mode == .Debug) {
            if (gc.no_gc_depth > 0) {
                std.debug.panic(
                    "GC collection fired while a noCollect guard is active (depth={}). " ++
                        "An unrooted GC Value is live across an allocation. " ++
                        "Check the call site that triggered this collection.",
                    .{gc.no_gc_depth},
                );
            }
        }
        try nursery_mod.collect(&gc.nursery, &gc.old_gen, &gc.cards, &gc.roots);
        gc.minor_count += 1;
    }

    /// Returns a guard that asserts no minor GC fires while it is alive.
    /// Zero cost in release builds. Use with defer:
    ///   var guard = gc.noCollect();
    ///   defer guard.release();
    pub fn noCollect(gc: *GC) NoCollectGuard {
        if (builtin.mode == .Debug) {
            gc.no_gc_depth += 1;
            return .{ .gc = gc };
        }
        return .{ .gc = {} };
    }

    /// Assert that `v`, if a pointer, does not point to a forwarded (moved)
    /// object. A forwarded object has bit 0 set in its header word — reading
    /// it as a live value produces garbage. Panics with the raw bits of `v` in
    /// debug builds; no-op in release.
    pub fn assertLive(gc: *GC, v: Value) void {
        _ = gc;
        if (builtin.mode != .Debug) return;
        if (!value_mod.isPtr(v)) return;
        const obj = value_mod.ptrVal(v);
        if (obj.isForward()) {
            std.debug.panic(
                "assertLive failed: Value 0x{x} points to a forwarded object " ++
                    "(header=0x{x}). The Value was not rooted across a GC collection.",
                .{ @as(u64, @bitCast(v)), obj.word },
            );
        }
    }

    /// Ensure the nursery has at least `needed_bytes` of contiguous free space.
    /// Triggers a preemptive minor GC if not. Used to make GC-unsafe tight
    /// loops (e.g. rest-args list construction over a C-stack buffer) safe by
    /// guaranteeing no collection can fire during the loop.
    pub fn reserveNursery(gc: *GC, needed_bytes: usize) !void {
        if (gc.nursery.free() >= needed_bytes) return;
        try gc.minor();
        // After minor, if still insufficient (catastrophic), error out rather
        // than risk a mid-loop collection.
        if (gc.nursery.free() < needed_bytes) return error.OutOfMemory;
    }

    pub fn major(gc: *GC) !void {
        // Minor first so there are no nursery pointers to worry about.
        try gc.minor();
        gc.old_gen.mark(&gc.roots, &gc.cards, gc.nursery.from_start, nursery_mod.NURSERY_SIZE);
        gc.old_gen.sweep();
        gc.major_count += 1;
    }

    /// Write barrier. Call before storing `new_val` into `*field_ptr` when
    /// `field_ptr` lives inside `obj`. If obj is in old-gen and new_val is a
    /// young pointer, mark the containing card.
    pub inline fn writeBarrier(gc: *GC, obj: *ObjHeader, field_ptr: *Value, new_val: Value) void {
        if (obj.space() != .old_gen) return;
        if (!value_mod.isPtr(new_val)) return;
        const tgt = value_mod.ptrVal(new_val);
        if (gc.nursery.contains(tgt)) {
            // Mark the card containing the FIELD, not the object header.
            // For large objects spanning multiple cards, a write to a distant
            // field lives in a different card than the header.
            gc.cards.markCard(@intFromPtr(field_ptr));
        }
    }
};
