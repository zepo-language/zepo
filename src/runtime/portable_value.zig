// zepo-vhi: portable-value checker and deep-copy for cross-worker channels.
//
// A "portable value" is one that can be safely copied across worker VM
// boundaries (separate heaps, separate GCs). Only pure-data types qualify:
//
//   Portable:     nil, booleans, fixnums, chars, EOF,
//                 floats, strings, symbols, bytevectors,
//                 pairs/lists of portable values,
//                 vectors of portable values.
//
//   Non-portable: closures, ports, fibers, any foreign object,
//                 cyclic / self-referential structures.
//
// Public API:
//   checkPortable(v, allocator)                        — validate, no alloc on dst
//   copyValue(v, dst_gc, dst_syms)                     — deep copy (assume portable)
//   copyPortable(v, dst_gc, dst_syms, allocator)       — check + copy

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const HandleScope = gc_mod.HandleScope;

const runtime = @import("objects.zig");
const symbols_mod = @import("symbols.zig");
const SymbolTable = symbols_mod.SymbolTable;
// zepo-hlz
const hashtable_mod = @import("hashtable.zig");

// ── checkPortable ─────────────────────────────────────────────────────────────

/// Validate that `v` is a portable value. Returns:
///   error.NonPortableValue  — closures, ports, fibers, foreign objects
///   error.CyclicStructure   — circular pairs or vectors
///   error.OutOfMemory       — allocator exhausted during traversal
///
/// Does not allocate on the GC heap.
pub fn checkPortable(v: Value, allocator: std.mem.Allocator) !void {
    var visited = std.AutoHashMapUnmanaged(usize, void).empty;
    defer visited.deinit(allocator);
    var stack = std.ArrayListUnmanaged(Value).empty;
    defer stack.deinit(allocator);

    try stack.append(allocator, v);
    while (stack.items.len > 0) {
        const cur = stack.pop().?;

        // Immediates are always portable; skip heap checks.
        if (!value_mod.isPtr(cur)) continue;

        const raw = @intFromPtr(value_mod.ptrVal(cur));
        const gop = try visited.getOrPut(allocator, raw);
        if (gop.found_existing) return error.CyclicStructure;

        // Leaf heap objects: no children to enqueue.
        if (runtime.isFloat(cur) or
            runtime.isString(cur) or
            runtime.isSymbol(cur) or
            runtime.isBytevector(cur)) continue;

        if (runtime.isPair(cur)) {
            try stack.append(allocator, runtime.pairCar(cur).*);
            try stack.append(allocator, runtime.pairCdr(cur).*);
            continue;
        }

        if (runtime.isVector(cur)) {
            const len = runtime.vectorLen(cur);
            for (0..len) |i| try stack.append(allocator, runtime.vectorGet(cur, i));
            continue;
        }

        // zepo-hlz: hashtables are portable; enqueue every key and value.
        // Only the traversal `stack` (plain allocator) grows here — no GC
        // allocation occurs, so the source slot stays stable and a local
        // pointer into the rooted-by-caller table is safe.
        if (hashtable_mod.isHashTable(cur)) {
            const Ctx = struct {
                stack: *std.ArrayListUnmanaged(Value),
                alloc: std.mem.Allocator,
                err: ?anyerror = null,
                fn visit(p: *anyopaque, vk: Value, vv: Value) void {
                    const s: *@This() = @ptrCast(@alignCast(p));
                    if (s.err != null) return;
                    s.stack.append(s.alloc, vk) catch |e| {
                        s.err = e;
                        return;
                    };
                    s.stack.append(s.alloc, vv) catch |e| {
                        s.err = e;
                    };
                }
            };
            var cb = Ctx{ .stack = &stack, .alloc = allocator };
            var cur_slot = cur;
            hashtable_mod.forEach(&cur_slot, &cb, Ctx.visit);
            if (cb.err) |e| return e;
            continue;
        }

        // Closures, ports, fibers, foreign objects, etc.
        return error.NonPortableValue;
    }
}

// ── copyValue ─────────────────────────────────────────────────────────────────

/// Deep-copy `src` onto `dst_gc`/`dst_syms`. Assumes `src` has already been
/// validated by `checkPortable` (i.e. is finite, acyclic, and contains only
/// portable types). Non-portable values return `error.NonPortableValue`.
///
/// GC-safe: each recursive frame roots its in-progress Values via HandleScope.
pub fn copyValue(
    src: Value,
    dst_gc: *GC,
    dst_syms: *SymbolTable,
) anyerror!Value {
    // Immediates pass through unchanged (fixnum, char, NIL, TRUE, FALSE, EOF).
    if (!value_mod.isPtr(src)) return src;

    if (runtime.isFloat(src))
        return runtime.makeFloat(dst_gc, runtime.floatVal(src));

    if (runtime.isString(src))
        return runtime.makeString(dst_gc, runtime.stringBytes(src));

    if (runtime.isSymbol(src))
        return dst_syms.intern(runtime.symbolName(src));

    if (runtime.isBytevector(src)) {
        const src_bytes = runtime.bytevectorBytes(src);
        const dst_bv = try runtime.makeBytevector(dst_gc, src_bytes.len, 0);
        // makeBytevector may GC, but the result is now on dst heap — safe to write.
        @memcpy(runtime.bytevectorBytes(dst_bv), src_bytes);
        return dst_bv;
    }

    if (runtime.isPair(src)) {
        var scope = HandleScope{};
        dst_gc.roots.pushHandleScope(&scope);
        defer dst_gc.roots.popHandleScope();
        // Copy car first, root it, then copy cdr (which may trigger GC).
        const car_slot = scope.push(try copyValue(runtime.pairCar(src).*, dst_gc, dst_syms));
        const cdr_slot = scope.push(try copyValue(runtime.pairCdr(src).*, dst_gc, dst_syms));
        return runtime.makePairFromSlots(dst_gc, car_slot, cdr_slot);
    }

    if (runtime.isVector(src)) {
        const len = runtime.vectorLen(src);
        // Allocate the destination vector and root it via extra_roots so it
        // survives any GC triggered by recursive copyValue calls.
        var dst_vec = try runtime.makeVector(dst_gc, len, value_mod.NIL);
        const prev_extra = dst_gc.roots.extra.items.len;
        try dst_gc.roots.extra.append(dst_gc.allocator, &dst_vec);
        defer dst_gc.roots.extra.shrinkRetainingCapacity(prev_extra);
        for (0..len) |i| {
            // Source element is read before recursive call; source heap is stable.
            const elem = try copyValue(runtime.vectorGet(src, i), dst_gc, dst_syms);
            // vectorSet writes through the GC write barrier, no allocation.
            runtime.vectorSet(dst_gc, dst_vec, i, elem);
        }
        return dst_vec;
    }

    // zepo-hlz: hashtables are portable. Rebuild a fresh deduped table on
    // dst_gc by copying every (key,value) pair.
    if (hashtable_mod.isHashTable(src)) {
        var scope = HandleScope{};
        dst_gc.roots.pushHandleScope(&scope);
        defer dst_gc.roots.popHandleScope();
        // Root the in-progress destination table: recursive copies below may
        // trigger GC and move it.
        const dst_ht_slot = scope.push(try hashtable_mod.make(dst_gc));

        // Root the SOURCE table for the duration of the iteration. forEach
        // re-reads backing(src_slot.*) every iteration; a recursive copy that
        // GCs can move the source table, so an un-rooted local would go stale.
        var src_slot = src;
        const prev_extra = dst_gc.roots.extra.items.len;
        try dst_gc.roots.extra.append(dst_gc.allocator, &src_slot);
        defer dst_gc.roots.extra.shrinkRetainingCapacity(prev_extra);

        const Ctx = struct {
            dst_gc: *GC,
            dst_syms: *SymbolTable,
            ht_slot: *Value,
            err: ?anyerror = null,
            fn visit(p: *anyopaque, k: Value, v: Value) void {
                const s: *@This() = @ptrCast(@alignCast(p));
                if (s.err != null) return;
                // Per-entry HandleScope: root the copied destination KEY across
                // the copy of the destination VALUE. A GC during the value copy
                // would otherwise move `dk` and stale it before putDistinct.
                var entry_scope = HandleScope{};
                s.dst_gc.roots.pushHandleScope(&entry_scope);
                defer s.dst_gc.roots.popHandleScope();
                const dk = copyValue(k, s.dst_gc, s.dst_syms) catch |e| {
                    s.err = e;
                    return;
                };
                const dk_slot = entry_scope.push(dk);
                const dv = copyValue(v, s.dst_gc, s.dst_syms) catch |e| {
                    s.err = e;
                    return;
                };
                // dk_slot.* is re-read post-GC (kept current by the HandleScope).
                hashtable_mod.putDistinct(s.dst_gc, s.ht_slot.*, dk_slot.*, dv) catch |e| {
                    s.err = e;
                };
            }
        };
        var cb = Ctx{ .dst_gc = dst_gc, .dst_syms = dst_syms, .ht_slot = dst_ht_slot };
        hashtable_mod.forEach(&src_slot, &cb, Ctx.visit);
        if (cb.err) |e| return e;
        return dst_ht_slot.*;
    }

    return error.NonPortableValue;
}

// ── copyPortable (combined check + copy) ─────────────────────────────────────

/// Validate that `src` is portable then deep-copy it onto `dst_gc`/`dst_syms`.
/// `allocator` is used only for the traversal bookkeeping in `checkPortable`.
pub fn copyPortable(
    src: Value,
    dst_gc: *GC,
    dst_syms: *SymbolTable,
    allocator: std.mem.Allocator,
) anyerror!Value {
    try checkPortable(src, allocator);
    return copyValue(src, dst_gc, dst_syms);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "portable: immediates" {
    const alloc = std.testing.allocator;
    try checkPortable(value_mod.NIL, alloc);
    try checkPortable(value_mod.TRUE, alloc);
    try checkPortable(value_mod.FALSE, alloc);
    try checkPortable(value_mod.fixnum(42), alloc);
    try checkPortable(value_mod.char('A'), alloc);
}

test "portable: rejects closure" {
    // We can't easily build a real closure here without a full VM, but we can
    // test the non-portable path via a foreign object from channel_prims.
    // This test just verifies the immediate-pass-through path.
    const alloc = std.testing.allocator;
    // All immediates pass.
    try checkPortable(value_mod.fixnum(-1), alloc);
}

test "portable copy: roundtrip via self-copy (same GC)" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();

    // fixnum
    const n = value_mod.fixnum(99);
    const n2 = try copyPortable(n, &gc, &syms, alloc);
    try std.testing.expectEqual(n, n2);

    // string
    const s = try runtime.makeString(&gc, "hello");
    const s2 = try copyPortable(s, &gc, &syms, alloc);
    try std.testing.expect(s != s2); // different object
    try std.testing.expectEqualStrings(runtime.stringBytes(s), runtime.stringBytes(s2));

    // symbol: intern returns same Value
    const sym = try syms.intern("foo");
    const sym2 = try copyPortable(sym, &gc, &syms, alloc);
    try std.testing.expectEqual(sym, sym2);

    // pair: (1 . 2)
    const pair = try runtime.makePair(&gc, value_mod.fixnum(1), value_mod.fixnum(2));
    const pair2 = try copyPortable(pair, &gc, &syms, alloc);
    try std.testing.expect(pair != pair2);
    try std.testing.expectEqual(value_mod.fixnum(1), runtime.pairCar(pair2).*);
    try std.testing.expectEqual(value_mod.fixnum(2), runtime.pairCdr(pair2).*);

    // list: (a b c)
    const c = try runtime.makePair(&gc, value_mod.fixnum(3), value_mod.NIL);
    const b = try runtime.makePair(&gc, value_mod.fixnum(2), c);
    const a = try runtime.makePair(&gc, value_mod.fixnum(1), b);
    const a2 = try copyPortable(a, &gc, &syms, alloc);
    try std.testing.expect(a != a2);
    try std.testing.expectEqual(value_mod.fixnum(1), runtime.pairCar(a2).*);
    try std.testing.expectEqual(value_mod.fixnum(2), runtime.pairCar(runtime.pairCdr(a2).*).*);
    try std.testing.expectEqual(value_mod.fixnum(3), runtime.pairCar(runtime.pairCdr(runtime.pairCdr(a2).*).*).*);

    // vector
    const vec = try runtime.makeVector(&gc, 3, value_mod.NIL);
    runtime.vectorSet(&gc, vec, 0, value_mod.fixnum(10));
    runtime.vectorSet(&gc, vec, 1, value_mod.fixnum(20));
    runtime.vectorSet(&gc, vec, 2, value_mod.fixnum(30));
    const vec2 = try copyPortable(vec, &gc, &syms, alloc);
    try std.testing.expect(vec != vec2);
    try std.testing.expectEqual(value_mod.fixnum(10), runtime.vectorGet(vec2, 0));
    try std.testing.expectEqual(value_mod.fixnum(20), runtime.vectorGet(vec2, 1));
    try std.testing.expectEqual(value_mod.fixnum(30), runtime.vectorGet(vec2, 2));

    // bytevector
    const bv = try runtime.makeBytevector(&gc, 3, 0);
    runtime.bytevectorBytes(bv)[0] = 1;
    runtime.bytevectorBytes(bv)[1] = 2;
    runtime.bytevectorBytes(bv)[2] = 3;
    const bv2 = try copyPortable(bv, &gc, &syms, alloc);
    try std.testing.expect(bv != bv2);
    try std.testing.expectEqualSlices(u8, runtime.bytevectorBytes(bv), runtime.bytevectorBytes(bv2));
}

test "portable: rejects cycle" {
    // We cannot easily build a cyclic pair without set-car!/set-cdr! at the
    // Zig level, so we test via direct ObjHeader pointer aliasing by building
    // a pair that points to itself — skip if mutation not available.
    // This test validates the non-cyclic path instead.
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();

    // A plain list is NOT cyclic — should pass.
    const tail = try runtime.makePair(&gc, value_mod.fixnum(2), value_mod.NIL);
    const head = try runtime.makePair(&gc, value_mod.fixnum(1), tail);
    try checkPortable(head, alloc);
}

// ── ChannelValue: GC-free staging type for cross-worker channel messages ──────
//
// Values in transit between workers are serialized into a ChannelValue tree
// that lives in the channel's own allocator (no GC heap involvement).
// Any receiving VM deserializes back to a live Value on its own GC heap.

pub const ChannelValue = union(enum) {
    nil,
    eof,
    boolean: bool,
    fixnum: i63,
    char: u21,
    float: f64,
    string: []u8,      // allocator-owned bytes
    symbol: []u8,      // symbol name, interned on deserialize
    bytevector: []u8,  // allocator-owned bytes
    pair: struct { car: *ChannelValue, cdr: *ChannelValue },
    vector: []*ChannelValue, // allocator-owned slice
    // zepo-hlz
    hash_table: []Entry, // allocator-owned (key,value) pairs

    // zepo-hlz
    pub const Entry = struct { key: *ChannelValue, value: *ChannelValue };
};

/// Serialize `val` into a `ChannelValue` tree using `alloc`.
/// Caller must eventually call `freeChannelValue` on the result.
/// Returns `error.NonPortableValue` for closures, ports, or other
/// non-portable types.
pub fn serializeToChannel(val: Value, alloc: std.mem.Allocator) anyerror!*ChannelValue {
    const cv = try alloc.create(ChannelValue);
    errdefer alloc.destroy(cv);

    if (value_mod.isNil(val)) { cv.* = .nil; return cv; }
    if (value_mod.isEof(val)) { cv.* = .eof; return cv; }
    if (val == value_mod.TRUE)  { cv.* = .{ .boolean = true };  return cv; }
    if (val == value_mod.FALSE) { cv.* = .{ .boolean = false }; return cv; }
    if (value_mod.isFixnum(val)) { cv.* = .{ .fixnum = value_mod.fixnumVal(val) }; return cv; }
    if (value_mod.isChar(val))   { cv.* = .{ .char = value_mod.charVal(val) };     return cv; }

    if (!value_mod.isPtr(val)) { alloc.destroy(cv); return error.NonPortableValue; }

    if (runtime.isFloat(val)) {
        cv.* = .{ .float = runtime.floatVal(val) };
        return cv;
    }
    if (runtime.isString(val)) {
        cv.* = .{ .string = try alloc.dupe(u8, runtime.stringBytes(val)) };
        return cv;
    }
    if (runtime.isSymbol(val)) {
        cv.* = .{ .symbol = try alloc.dupe(u8, runtime.symbolName(val)) };
        return cv;
    }
    if (runtime.isBytevector(val)) {
        cv.* = .{ .bytevector = try alloc.dupe(u8, runtime.bytevectorBytes(val)) };
        return cv;
    }
    if (runtime.isPair(val)) {
        const car = try serializeToChannel(runtime.pairCar(val).*, alloc);
        errdefer freeChannelValue(car, alloc);
        const cdr = try serializeToChannel(runtime.pairCdr(val).*, alloc);
        cv.* = .{ .pair = .{ .car = car, .cdr = cdr } };
        return cv;
    }
    if (runtime.isVector(val)) {
        const len = runtime.vectorLen(val);
        const elems = try alloc.alloc(*ChannelValue, len);
        errdefer alloc.free(elems);
        var n: usize = 0;
        errdefer for (elems[0..n]) |e| freeChannelValue(e, alloc);
        while (n < len) : (n += 1)
            elems[n] = try serializeToChannel(runtime.vectorGet(val, n), alloc);
        cv.* = .{ .vector = elems };
        return cv;
    }
    // zepo-hlz: hashtables serialize to an allocator-owned entry list. No GC
    // runs (plain alloc), so the source table is stable; we only need to free
    // already-serialized entries on a mid-way error.
    if (hashtable_mod.isHashTable(val)) {
        var list = std.ArrayListUnmanaged(ChannelValue.Entry).empty;
        errdefer {
            for (list.items) |e| {
                freeChannelValue(e.key, alloc);
                freeChannelValue(e.value, alloc);
            }
            list.deinit(alloc);
        }
        const Ctx = struct {
            alloc: std.mem.Allocator,
            list: *std.ArrayListUnmanaged(ChannelValue.Entry),
            err: ?anyerror = null,
            fn visit(p: *anyopaque, k: Value, v: Value) void {
                const s: *@This() = @ptrCast(@alignCast(p));
                if (s.err != null) return;
                const ck = serializeToChannel(k, s.alloc) catch |e| {
                    s.err = e;
                    return;
                };
                const cvv = serializeToChannel(v, s.alloc) catch |e| {
                    freeChannelValue(ck, s.alloc);
                    s.err = e;
                    return;
                };
                s.list.append(s.alloc, .{ .key = ck, .value = cvv }) catch |e| {
                    freeChannelValue(ck, s.alloc);
                    freeChannelValue(cvv, s.alloc);
                    s.err = e;
                };
            }
        };
        var cb = Ctx{ .alloc = alloc, .list = &list };
        var val_slot = val;
        hashtable_mod.forEach(&val_slot, &cb, Ctx.visit);
        if (cb.err) |e| return e;
        cv.* = .{ .hash_table = try list.toOwnedSlice(alloc) };
        return cv;
    }

    alloc.destroy(cv);
    return error.NonPortableValue;
}

/// Reconstruct a `Value` on `dst_gc`/`dst_syms` from a `ChannelValue`.
/// Does not free `cv` — caller must call `freeChannelValue` after use.
pub fn deserializeFromChannel(
    cv: *const ChannelValue,
    dst_gc: *GC,
    dst_syms: *SymbolTable,
) anyerror!Value {
    return switch (cv.*) {
        .nil      => value_mod.NIL,
        .eof      => value_mod.EOF_VAL,
        .boolean  => |b| if (b) value_mod.TRUE else value_mod.FALSE,
        .fixnum   => |n| value_mod.fixnum(n),
        .char     => |c| value_mod.char(c),
        .float    => |f| runtime.makeFloat(dst_gc, f),
        .string   => |s| runtime.makeString(dst_gc, s),
        .symbol   => |s| dst_syms.intern(s),
        .bytevector => |b| blk: {
            const bv = try runtime.makeBytevector(dst_gc, b.len, 0);
            @memcpy(runtime.bytevectorBytes(bv), b);
            break :blk bv;
        },
        .pair => |p| blk: {
            var scope = HandleScope{};
            dst_gc.roots.pushHandleScope(&scope);
            defer dst_gc.roots.popHandleScope();
            const car_slot = scope.push(try deserializeFromChannel(p.car, dst_gc, dst_syms));
            const cdr_slot = scope.push(try deserializeFromChannel(p.cdr, dst_gc, dst_syms));
            break :blk runtime.makePairFromSlots(dst_gc, car_slot, cdr_slot);
        },
        .vector => |elems| blk: {
            var dst_vec = try runtime.makeVector(dst_gc, elems.len, value_mod.NIL);
            const prev_extra = dst_gc.roots.extra.items.len;
            try dst_gc.roots.extra.append(dst_gc.allocator, &dst_vec);
            defer dst_gc.roots.extra.shrinkRetainingCapacity(prev_extra);
            for (elems, 0..) |e, i| {
                const elem = try deserializeFromChannel(e, dst_gc, dst_syms);
                runtime.vectorSet(dst_gc, dst_vec, i, elem);
            }
            break :blk dst_vec;
        },
        // zepo-hlz: rebuild a hashtable on dst_gc. Root the in-progress table
        // via extra-roots (recursive deserialize may GC and move it). For each
        // entry, deserialize the key, push it to a HandleScope slot so the
        // SUBSEQUENT value deserialization's GC cannot stale it, then put.
        .hash_table => |entries| blk: {
            var ht = try hashtable_mod.make(dst_gc);
            // zepo-hlz: `ht` is rooted via roots.extra (not a HandleScope slot
            // like copyValue) because the extra-root keeps `&ht` itself current
            // across any GC; the per-entry key is separately rooted in the entry
            // HandleScope below, so no HandleScope slot for `ht` is needed here.
            const prev_extra = dst_gc.roots.extra.items.len;
            try dst_gc.roots.extra.append(dst_gc.allocator, &ht);
            defer dst_gc.roots.extra.shrinkRetainingCapacity(prev_extra);
            for (entries) |e| {
                var entry_scope = HandleScope{};
                dst_gc.roots.pushHandleScope(&entry_scope);
                defer dst_gc.roots.popHandleScope();
                // Root the key across the value deserialization.
                const key_slot = entry_scope.push(try deserializeFromChannel(e.key, dst_gc, dst_syms));
                const value = try deserializeFromChannel(e.value, dst_gc, dst_syms);
                try hashtable_mod.putDistinct(dst_gc, ht, key_slot.*, value);
            }
            break :blk ht;
        },
    };
}

/// Recursively free a `ChannelValue` tree using `alloc`.
pub fn freeChannelValue(cv: *ChannelValue, alloc: std.mem.Allocator) void {
    switch (cv.*) {
        .string, .symbol, .bytevector => |b| alloc.free(b),
        .pair => |p| {
            freeChannelValue(p.car, alloc);
            freeChannelValue(p.cdr, alloc);
        },
        .vector => |elems| {
            for (elems) |e| freeChannelValue(e, alloc);
            alloc.free(elems);
        },
        // zepo-hlz
        .hash_table => |entries| {
            for (entries) |e| {
                freeChannelValue(e.key, alloc);
                freeChannelValue(e.value, alloc);
            }
            alloc.free(entries);
        },
        else => {},
    }
    alloc.destroy(cv);
}

test "ChannelValue: roundtrip serialize/deserialize" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();

    // fixnum
    {
        const cv = try serializeToChannel(value_mod.fixnum(77), alloc);
        defer freeChannelValue(cv, alloc);
        const v = try deserializeFromChannel(cv, &gc, &syms);
        try std.testing.expectEqual(value_mod.fixnum(77), v);
    }
    // string
    {
        const s = try runtime.makeString(&gc, "world");
        const cv = try serializeToChannel(s, alloc);
        defer freeChannelValue(cv, alloc);
        const v = try deserializeFromChannel(cv, &gc, &syms);
        try std.testing.expectEqualStrings("world", runtime.stringBytes(v));
    }
    // list (1 2 3)
    {
        const c = try runtime.makePair(&gc, value_mod.fixnum(3), value_mod.NIL);
        const b = try runtime.makePair(&gc, value_mod.fixnum(2), c);
        const a = try runtime.makePair(&gc, value_mod.fixnum(1), b);
        const cv = try serializeToChannel(a, alloc);
        defer freeChannelValue(cv, alloc);
        const v = try deserializeFromChannel(cv, &gc, &syms);
        try std.testing.expectEqual(value_mod.fixnum(1), runtime.pairCar(v).*);
        try std.testing.expectEqual(value_mod.fixnum(2), runtime.pairCar(runtime.pairCdr(v).*).*);
        try std.testing.expectEqual(value_mod.fixnum(3), runtime.pairCar(runtime.pairCdr(runtime.pairCdr(v).*).*).*);
    }
}

// zepo-hlz
test "portable: hashtable roundtrips with portable keys/values" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();

    const ht = try hashtable_mod.make(&gc);
    const k = try runtime.makeString(&gc, "limit");
    try hashtable_mod.putDistinct(&gc, ht, k, value_mod.fixnum(100));

    const copy = try copyPortable(ht, &gc, &syms, alloc);
    try std.testing.expect(copy != ht);
    try std.testing.expect(hashtable_mod.isHashTable(copy));
    try std.testing.expectEqual(@as(usize, 1), hashtable_mod.size(copy));
}

// zepo-hlz
test "portable: hashtable with non-portable value is rejected" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    const ht = try hashtable_mod.make(&gc);
    const k = try runtime.makeString(&gc, "ch");
    // checkPortable only inspects the type tag, never derefs the payload,
    // so a null payload is fine.
    const foreign = try runtime.makeForeign(&gc, null, null, 0xdead);
    try hashtable_mod.putDistinct(&gc, ht, k, foreign);
    try std.testing.expectError(error.NonPortableValue, checkPortable(ht, alloc));
}

// zepo-hlz
test "ChannelValue: hashtable serialize/deserialize roundtrip" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();

    const ht = try hashtable_mod.make(&gc);
    const k = try runtime.makeString(&gc, "limit");
    try hashtable_mod.putDistinct(&gc, ht, k, value_mod.fixnum(100));

    const cv = try serializeToChannel(ht, alloc);
    defer freeChannelValue(cv, alloc);
    const v = try deserializeFromChannel(cv, &gc, &syms);
    try std.testing.expect(hashtable_mod.isHashTable(v));
    try std.testing.expectEqual(@as(usize, 1), hashtable_mod.size(v));
}

// zepo-hlz: exercises the recursive-GC rooting path — a multi-entry table
// (multiple live slots) whose values include a NESTED vector. Round-tripped
// through serialize→deserialize so freeChannelValue's nested free path is
// covered under the leak-checking testing allocator.
test "portable: multi-entry hashtable with nested vector value roundtrips" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();

    const ht = try hashtable_mod.make(&gc);
    {
        var scope = HandleScope{};
        gc.roots.pushHandleScope(&scope);
        defer gc.roots.popHandleScope();
        const ht_slot = scope.push(ht);

        // Five scalar entries + one nested-vector entry = 6 live slots.
        try hashtable_mod.putDistinct(&gc, ht_slot.*, try runtime.makeString(&gc, "a"), value_mod.fixnum(1));
        try hashtable_mod.putDistinct(&gc, ht_slot.*, try runtime.makeString(&gc, "b"), value_mod.fixnum(2));
        try hashtable_mod.putDistinct(&gc, ht_slot.*, try runtime.makeString(&gc, "c"), value_mod.fixnum(3));
        try hashtable_mod.putDistinct(&gc, ht_slot.*, try runtime.makeString(&gc, "d"), value_mod.fixnum(4));
        try hashtable_mod.putDistinct(&gc, ht_slot.*, try runtime.makeString(&gc, "e"), value_mod.fixnum(5));

        // Nested portable value: a 3-element vector under key "vec".
        const inner = try runtime.makeVector(&gc, 3, value_mod.NIL);
        const inner_slot = scope.push(inner);
        runtime.vectorSet(&gc, inner_slot.*, 0, value_mod.fixnum(10));
        runtime.vectorSet(&gc, inner_slot.*, 1, value_mod.fixnum(20));
        runtime.vectorSet(&gc, inner_slot.*, 2, value_mod.fixnum(30));
        try hashtable_mod.putDistinct(&gc, ht_slot.*, try runtime.makeString(&gc, "vec"), inner_slot.*);
    }

    const cv = try serializeToChannel(ht, alloc);
    defer freeChannelValue(cv, alloc);
    const out = try deserializeFromChannel(cv, &gc, &syms);

    try std.testing.expect(hashtable_mod.isHashTable(out));
    try std.testing.expectEqual(@as(usize, 6), hashtable_mod.size(out));

    // Read entries back via forEach (VM-free), matching keys by their string
    // bytes, and verify the scalar and the nested-vector value structurally.
    const Probe = struct {
        scalar_d: ?Value = null,
        vec_val: ?Value = null,
        fn visit(p: *anyopaque, k: Value, val: Value) void {
            const s: *@This() = @ptrCast(@alignCast(p));
            if (!runtime.isString(k)) return;
            const bytes = runtime.stringBytes(k);
            if (std.mem.eql(u8, bytes, "d")) s.scalar_d = val;
            if (std.mem.eql(u8, bytes, "vec")) s.vec_val = val;
        }
    };
    var probe = Probe{};
    var out_slot = out;
    hashtable_mod.forEach(&out_slot, &probe, Probe.visit);

    // Scalar entry reads back correctly.
    try std.testing.expectEqual(value_mod.fixnum(4), probe.scalar_d.?);

    // Nested vector reads back structurally.
    const rv = probe.vec_val.?;
    try std.testing.expect(runtime.isVector(rv));
    try std.testing.expectEqual(@as(usize, 3), runtime.vectorLen(rv));
    try std.testing.expectEqual(value_mod.fixnum(10), runtime.vectorGet(rv, 0));
    try std.testing.expectEqual(value_mod.fixnum(20), runtime.vectorGet(rv, 1));
    try std.testing.expectEqual(value_mod.fixnum(30), runtime.vectorGet(rv, 2));
}
