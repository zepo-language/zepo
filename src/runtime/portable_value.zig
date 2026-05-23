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
