//! zepo-nfak: arbitrary-precision exact integer arithmetic, backed by
//! std.math.big.int. Bignums are stored as a GC object (see objects.makeBignum);
//! all operations copy their operands into host-allocator std.math.big.int.Managed
//! values, compute, and normalize the result back to a fixnum when it fits or a
//! fresh bignum otherwise. This is the SLOW path (only reached when a fixnum
//! operation overflows), so the extra copies are not on the hot path.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const objects = @import("objects.zig");
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;

const Managed = std.math.big.int.Managed;

/// True if `v` is an exact integer (a fixnum or a bignum).
pub fn isInteger(v: Value) bool {
    return value_mod.isFixnum(v) or objects.isBignum(v);
}

/// An i64 → fixnum-or-bignum (for a fixnum-range overflow that still fits i64).
pub fn fromI64(gc: *GC, i: i64) !Value {
    var m = try Managed.initSet(gc.allocator, @as(i128, i));
    defer m.deinit();
    return fromManaged(gc, &m);
}

/// A bignum → f64 (for mixed-with-float arithmetic and exact->inexact).
pub fn toFloat(v: Value) f64 {
    return objects.bignumConst(v).toFloat(f64, .nearest_even)[0];
}

/// Copy an integer Value (fixnum or bignum) into a host-allocated Managed.
/// pub so the ratio module (zepo-or1d) can lift integer parts to big-int.
pub fn toManaged(alloc: std.mem.Allocator, v: Value) !Managed {
    if (objects.isBignum(v)) {
        var m = try Managed.init(alloc);
        errdefer m.deinit();
        try m.copy(objects.bignumConst(v));
        return m;
    }
    // fixnum
    return Managed.initSet(alloc, @as(i128, value_mod.fixnumVal(v)));
}

/// Normalize a big-int result: return a fixnum if it fits the fixnum range,
/// otherwise a fresh bignum object. Errors narrow to OutOfMemory so callers in
/// the LispError world (arith prims) can propagate them directly.
/// pub so the ratio module (zepo-or1d) can normalize its num/den parts.
pub fn fromManaged(gc: *GC, r: *Managed) error{OutOfMemory}!Value {
    const c = r.toConst();
    if (c.toInt(i64)) |i| {
        if (value_mod.fixnumFits(i)) return value_mod.fixnum(@intCast(i));
    } else |_| {}
    return objects.makeBignum(gc, c.positive, c.limbs) catch return error.OutOfMemory;
}

pub fn add(gc: *GC, a: Value, b: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    var mb = try toManaged(gc.allocator, b);
    defer mb.deinit();
    var r = try Managed.init(gc.allocator);
    defer r.deinit();
    try r.add(&ma, &mb);
    return fromManaged(gc, &r);
}

pub fn sub(gc: *GC, a: Value, b: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    var mb = try toManaged(gc.allocator, b);
    defer mb.deinit();
    var r = try Managed.init(gc.allocator);
    defer r.deinit();
    try r.sub(&ma, &mb);
    return fromManaged(gc, &r);
}

pub fn mul(gc: *GC, a: Value, b: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    var mb = try toManaged(gc.allocator, b);
    defer mb.deinit();
    var r = try Managed.init(gc.allocator);
    defer r.deinit();
    try r.mul(&ma, &mb);
    return fromManaged(gc, &r);
}

pub fn negate(gc: *GC, a: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    ma.negate();
    return fromManaged(gc, &ma);
}

pub fn absValue(gc: *GC, a: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    ma.abs();
    return fromManaged(gc, &ma);
}

/// Truncating division: quotient. (Matches R7RS `quotient`.)
pub fn quotient(gc: *GC, a: Value, b: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    var mb = try toManaged(gc.allocator, b);
    defer mb.deinit();
    var q = try Managed.init(gc.allocator);
    defer q.deinit();
    var r = try Managed.init(gc.allocator);
    defer r.deinit();
    try q.divTrunc(&r, &ma, &mb);
    return fromManaged(gc, &q);
}

/// Truncating division: remainder. (Matches R7RS `remainder`.)
pub fn remainder(gc: *GC, a: Value, b: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    var mb = try toManaged(gc.allocator, b);
    defer mb.deinit();
    var q = try Managed.init(gc.allocator);
    defer q.deinit();
    var r = try Managed.init(gc.allocator);
    defer r.deinit();
    try q.divTrunc(&r, &ma, &mb);
    return fromManaged(gc, &r);
}

/// Flooring division remainder. (Matches R7RS `modulo`.)
pub fn modulo(gc: *GC, a: Value, b: Value) !Value {
    var ma = try toManaged(gc.allocator, a);
    defer ma.deinit();
    var mb = try toManaged(gc.allocator, b);
    defer mb.deinit();
    var q = try Managed.init(gc.allocator);
    defer q.deinit();
    var r = try Managed.init(gc.allocator);
    defer r.deinit();
    try q.divFloor(&r, &ma, &mb);
    return fromManaged(gc, &r);
}

/// Order two integer Values (each fixnum or bignum). Since a bignum is never in
/// fixnum range, a fixnum and a bignum compare purely by magnitude/sign.
pub fn order(alloc: std.mem.Allocator, a: Value, b: Value) !std.math.Order {
    var ma = try toManaged(alloc, a);
    defer ma.deinit();
    var mb = try toManaged(alloc, b);
    defer mb.deinit();
    return ma.toConst().order(mb.toConst());
}

/// Value equality of two bignums (both must be bignums).
pub fn eql(a: Value, b: Value) bool {
    return objects.bignumConst(a).order(objects.bignumConst(b)) == .eq;
}

/// Render a bignum as a base-10 string (caller frees).
pub fn toString(alloc: std.mem.Allocator, v: Value) ![]u8 {
    var m = try toManaged(alloc, v);
    defer m.deinit();
    return m.toString(alloc, 10, .lower);
}

/// Parse a base-10 integer string (optional leading '-') into a fixnum or
/// bignum. Used by the reader for over-range integer literals.
pub fn fromDecimal(gc: *GC, str: []const u8) !Value {
    var m = try Managed.init(gc.allocator);
    defer m.deinit();
    try m.setString(10, str);
    return fromManaged(gc, &m);
}
