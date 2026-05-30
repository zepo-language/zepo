//! Top-level GC facade that orchestrates nursery, old-gen, card table, roots.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi/mod.zig");
const trace_mod = @import("../runtime/trace.zig");
pub const TraceFlags = trace_mod.TraceFlags;
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

// zepo-8ou: incremental major GC trigger at 50% old-gen usage.
// zepo-nmqj: computed from the actual old-gen size at runtime.
inline fn oldGenTriggerBytes(gc: *const GC) usize {
    return gc.old_gen.heapSize() / 2;
}
/// Budget (objects traced) per incremental marking step in the scheduler.
const MARK_STEP_BUDGET: usize = 256;

pub const MarkPhase = enum { idle, marking };

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
    /// Subsystem trace flags read from ZEPO_TRACE at init time.
    trace: TraceFlags = .{},
    // zepo-8ou: incremental major GC state.
    /// Gray object worklist: objects seen but whose children haven't been traced.
    gray: std.ArrayListUnmanaged(*ObjHeader) = .empty,
    mark_phase: MarkPhase = .idle,

    pub fn init(allocator: std.mem.Allocator) !GC {
        return initWithSize(allocator, nursery_mod.NURSERY_SIZE, oldgen_mod.OLD_GEN_SIZE);
    }

    /// zepo-nmqj: init the GC with explicit nursery and old-gen sizes (bytes).
    /// Sizes are aligned up to page/word boundaries internally.
    pub fn initWithSize(
        allocator: std.mem.Allocator,
        nursery_bytes: usize,
        old_gen_bytes: usize,
    ) !GC {
        var nursery = try Nursery.initWithSize(nursery_bytes);
        errdefer nursery.deinit();
        var old_gen = try OldGen.initWithSize(allocator, old_gen_bytes);
        errdefer old_gen.deinit();
        const cards = try CardTable.init(allocator, old_gen.baseAddr(), old_gen.heapSize());
        return .{
            .allocator = allocator,
            .nursery = nursery,
            .old_gen = old_gen,
            .cards = cards,
            .roots = .{},
            .trace = TraceFlags.fromEnv(),
        };
    }

    pub fn deinit(gc: *GC) void {
        gc.gray.deinit(gc.allocator); // zepo-8ou
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
        // Fallback to old-gen. zepo-a7j: size the header with the block's
        // ACTUAL (size-class-rounded) capacity, like promote() does — using the
        // requested body_words under-reports a rounded-up block (e.g. a 1-word
        // box lands in the 2-word size class) and desyncs the old-gen heap
        // walker (sweep / major-mark / verifier).
        const r = gc.old_gen.allocWithCap(body_words) orelse return error.OutOfMemory;
        r.hdr.* = ObjHeader.init(kind, .old_gen, @intFromEnum(kind), @intCast(r.actual_words));
        return r.hdr;
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
        // zepo-8ou: foreign objects have no Value children, so marking them
        // black immediately is safe and prevents them being swept mid-mark.
        if (gc.mark_phase == .marking) p.setMark();
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
        // zepo-8ou: if an incremental major mark is in progress, complete it
        // before running the nursery collector. Running the Cheney forwarder
        // while marking could promote nursery objects to old-gen as white
        // (unmarked) objects with the mark bit not set, violating the
        // tri-color invariant. Completing mark+sweep first avoids the issue.
        if (gc.mark_phase == .marking) {
            gc.finishMark();
            gc.sweepAndFinish();
        }
        if (gc.trace.gc) {
            const used_before = gc.nursery.used();
            const roots_n = gc.roots.extra.items.len;
            try nursery_mod.collect(&gc.nursery, &gc.old_gen, &gc.cards, &gc.roots);
            gc.minor_count += 1;
            std.debug.print(
                "[gc] minor #{d}  nursery {d}/{d} bytes ({d}%)  roots={d}\n",
                .{
                    gc.minor_count,
                    used_before,
                    gc.nursery.size(),
                    used_before * 100 / gc.nursery.size(),
                    roots_n,
                },
            );
        } else {
            try nursery_mod.collect(&gc.nursery, &gc.old_gen, &gc.cards, &gc.roots);
            gc.minor_count += 1;
        }
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
        roots_mod.assertLive(v); // zepo-7fa: delegates to free function in roots.zig
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
        const old_used_before = if (gc.trace.gc) gc.old_gen.usedBytes() else 0;
        // Minor first so there are no nursery pointers to worry about.
        try gc.minor();
        gc.old_gen.mark(&gc.roots, &gc.cards, gc.nursery.from_start, gc.nursery.bump);
        gc.old_gen.sweep();
        gc.major_count += 1;
        if (gc.trace.gc) {
            std.debug.print(
                "[gc] major #{d}  old-gen {d} → {d} bytes  roots={d}\n",
                .{
                    gc.major_count,
                    old_used_before,
                    gc.old_gen.usedBytes(),
                    gc.roots.extra.items.len,
                },
            );
        }
    }

    /// Write barrier. Call before storing `new_val` into `*field_ptr` when
    /// `field_ptr` lives inside `obj`. Maintains:
    ///   (a) generational invariant: marks card when old-gen stores young ptr.
    ///   (b) zepo-8ou tri-color invariant (SATB): during incremental marking,
    ///       if a black old-gen slot is overwritten, the OLD value is grayed so
    ///       the snapshot taken at markBegin is preserved.
    pub inline fn writeBarrier(gc: *GC, obj: *ObjHeader, field_ptr: *Value, new_val: Value) void {
        if (obj.space() != .old_gen) return;
        // (a) generational barrier — card marking for old→young
        if (value_mod.isPtr(new_val)) {
            const tgt = value_mod.ptrVal(new_val);
            if (gc.nursery.contains(tgt)) {
                gc.cards.markCard(@intFromPtr(field_ptr));
            }
        }
        // (b) SATB deletion barrier — gray the slot's OLD value before it is
        // overwritten. Any old-gen object that was reachable at markBegin is
        // kept alive even if all other references are removed during marking.
        if (gc.mark_phase == .marking) {
            const old_val = field_ptr.*;
            if (value_mod.isPtr(old_val)) {
                const old_tgt = value_mod.ptrVal(old_val);
                if (gc.old_gen.contains(old_tgt) and !old_tgt.marked()) {
                    old_tgt.setMark();
                    gc.gray.append(gc.allocator, old_tgt) catch {};
                }
            }
        }
    }

    // ── zepo-8ou: Incremental major GC ────────────────────────────────────────

    /// Push `obj` to the gray worklist if it is a white old-gen object.
    /// "White" means unmarked; marking it here transitions it to gray.
    fn pushGray(gc: *GC, obj: *ObjHeader) void {
        if (!gc.old_gen.contains(obj)) return;
        if (obj.marked()) return;
        obj.setMark();
        gc.gray.append(gc.allocator, obj) catch {};
    }

    /// RootVisitor callback: gray any old-gen pointer found in a root slot.
    fn grayRootSlot(ctx_raw: *anyopaque, slot: *Value) void {
        const gc: *GC = @ptrCast(@alignCast(ctx_raw));
        const v = slot.*;
        if (!value_mod.isPtr(v)) return;
        gc.pushGray(value_mod.ptrVal(v));
    }

    /// Trace the children of a gray old-gen object, pushing white old-gen
    /// children to the gray worklist. Transitions the object from gray to black.
    fn traceObjGray(gc: *GC, h: *ObjHeader) void {
        const desc = layout_mod.layoutForKind(h.kind());
        const body: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
        const nwords: usize = @intCast(h.sizeWords());
        for (desc.value_offsets) |off| {
            if (off < nwords) gc.grayValueWord(body[off]);
        }
        if (desc.all_slots_are_values) {
            var i: usize = desc.value_slots_start;
            while (i < nwords) : (i += 1) gc.grayValueWord(body[i]);
        }
    }

    inline fn grayValueWord(gc: *GC, raw: u64) void {
        const v: Value = @bitCast(raw);
        if (!value_mod.isPtr(v)) return;
        gc.pushGray(value_mod.ptrVal(v));
    }

    /// Begin an incremental major GC cycle. Runs a minor GC first (with
    /// mark_phase still .idle) to evacuate the nursery, then snapshots all
    /// roots into the gray worklist.
    pub fn markBegin(gc: *GC) !void {
        std.debug.assert(gc.mark_phase == .idle);
        // Nursery must be empty before we snapshot roots: promoted objects
        // land in old-gen where they are reachable from the root scan.
        // mark_phase is still .idle here so minor() runs unconditionally.
        try gc.minor();
        gc.mark_phase = .marking;
        gc.gray.clearRetainingCapacity();
        gc.roots.visitAll(@ptrCast(gc), grayRootSlot);
        // zepo-svu: the write barrier only fires for old-gen objects, so
        // nursery→old-gen edges are not recorded in the card table. Scan
        // every live nursery cell to gray any old-gen objects reachable
        // only through the nursery; without this, they'd be swept as
        // unreachable even though live values still reference them.
        {
            var scan: [*]u8 = gc.nursery.from_start;
            const bump = gc.nursery.bump;
            while (@intFromPtr(scan) < @intFromPtr(bump)) {
                const obj: *ObjHeader = @ptrCast(@alignCast(scan));
                gc.traceObjGray(obj);
                scan = @ptrFromInt(@intFromPtr(scan) + nursery_mod.objectSizeBytes(obj));
            }
        }
        if (gc.trace.gc) {
            std.debug.print("[gc] mark-begin  old-gen {d} bytes  gray={d}\n", .{
                gc.old_gen.usedBytes(), gc.gray.items.len,
            });
        }
    }

    /// Process up to `budget` gray objects. Returns true when the gray
    /// worklist is empty (marking complete). Call sweepAndFinish() then.
    pub fn markStep(gc: *GC, budget: usize) bool {
        std.debug.assert(gc.mark_phase == .marking);
        var i: usize = 0;
        while (i < budget and gc.gray.items.len > 0) : (i += 1) {
            const obj = gc.gray.pop().?;
            gc.traceObjGray(obj);
        }
        return gc.gray.items.len == 0;
    }

    /// Drain the gray worklist completely (emergency / pre-minor path).
    pub fn finishMark(gc: *GC) void {
        while (gc.gray.items.len > 0) {
            const obj = gc.gray.pop().?;
            gc.traceObjGray(obj);
        }
    }

    /// Sweep old-gen and reset marking state. Must be called after the gray
    /// worklist is empty (markStep returned true, or finishMark was called).
    pub fn sweepAndFinish(gc: *GC) void {
        std.debug.assert(gc.mark_phase == .marking);
        gc.old_gen.sweep();
        gc.major_count += 1;
        gc.mark_phase = .idle;
        gc.gray.clearRetainingCapacity();
        if (gc.trace.gc) {
            std.debug.print("[gc] major #{d} (incremental)  old-gen {d} bytes\n", .{
                gc.major_count, gc.old_gen.usedBytes(),
            });
        }
    }

    /// Whether old-gen has grown past the trigger threshold and a new
    /// incremental mark cycle should be started by the scheduler.
    pub fn needsMajor(gc: *const GC) bool {
        return gc.mark_phase == .idle and
            gc.old_gen.usedBytes() > oldGenTriggerBytes(gc);
    }
};
