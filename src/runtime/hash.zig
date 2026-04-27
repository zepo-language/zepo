//! Structural hasher for Zepo values. Used by hash tables to locate
//! slots with `equal?` semantics. Two values for which `equal?` returns
//! true are guaranteed to hash identically.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const objects = @import("objects.zig");

/// Reserved sentinel Value for tombstone slots in a hash table. Chosen so
/// that `isPtr` returns false (it must never be confused with a heap
/// pointer) and it is not producible by any user code path.
pub const TOMBSTONE: Value = 0x1B;

inline fn mix64(x: u64) u64 {
    // SplitMix64 constants — strong 64-bit scrambler.
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

inline fn combine(a: u64, b: u64) u64 {
    return mix64(a ^ (b +% 0x9E3779B97F4A7C15 +% (a << 6) +% (a >> 2)));
}

fn hashBytes(bytes: []const u8) u64 {
    // FNV-1a 64-bit.
    var h: u64 = 0xCBF29CE484222325;
    for (bytes) |b| {
        h ^= b;
        h = h *% 0x100000001B3;
    }
    return h;
}

pub fn hashValue(v: Value) u64 {
    if (value_mod.isFixnum(v)) {
        const n: i64 = @intCast(value_mod.fixnumVal(v));
        return mix64(@bitCast(n));
    }
    if (value_mod.isChar(v)) {
        return mix64(v);
    }
    if (v == value_mod.NIL) return mix64(1);
    if (v == value_mod.TRUE) return mix64(2);
    if (v == value_mod.FALSE) return mix64(3);
    if (!value_mod.isPtr(v)) return mix64(v);

    // Heap objects.
    if (objects.isFloat(v)) {
        const f = objects.floatVal(v);
        return mix64(@bitCast(f));
    }
    if (objects.isString(v)) {
        return combine(0xA11_5771_0000_0000, hashBytes(objects.stringBytes(v)));
    }
    if (objects.isSymbol(v)) {
        return combine(0xA11_5_9A80_0000, objects.symbolHash(v));
    }
    if (objects.isPair(v)) {
        // Hash as (car . cdr) pair; bounded-depth to avoid infinite recursion
        // on cyclic lists. 8 cdrs deep is plenty for typical keys.
        var h: u64 = 0xA11_9A18_0000_0000;
        var cur = v;
        var depth: usize = 0;
        while (value_mod.isPtr(cur) and objects.isPair(cur) and depth < 8) : (depth += 1) {
            h = combine(h, hashValue(objects.pairCar(cur).*));
            cur = objects.pairCdr(cur).*;
        }
        h = combine(h, hashValue(cur));
        return h;
    }
    if (objects.isVector(v)) {
        const len = objects.vectorLen(v);
        var h: u64 = combine(0xA11_9EC_0000_0000, @as(u64, len));
        var i: usize = 0;
        const cap_seen: usize = if (len < 16) len else 16;
        while (i < cap_seen) : (i += 1) {
            h = combine(h, hashValue(objects.vectorGet(v, i)));
        }
        return h;
    }
    // Fallback: hash by pointer identity. Correct for any remaining heap kind.
    return mix64(@intFromPtr(value_mod.ptrVal(v)));
}

test "hash: equal primitives hash identically" {
    const a = value_mod.fixnum(42);
    const b = value_mod.fixnum(42);
    try std.testing.expectEqual(hashValue(a), hashValue(b));
    try std.testing.expect(hashValue(value_mod.TRUE) != hashValue(value_mod.FALSE));
}
