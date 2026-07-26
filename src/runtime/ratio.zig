//! zepo-or1d: exact rational arithmetic. A ratio (see objects.makeRatio) stores
//! a numerator and denominator, each an exact integer (fixnum or bignum). A
//! well-formed ratio is always reduced (gcd(|num|,den)=1), has den > 0, and
//! den != 1 (a denominator of 1 normalizes to a plain integer).
//!
//! Operations lift their operands to std.math.big.int.Managed pairs, compute,
//! and normalize the result back to a fixnum/bignum (when den reduces to 1) or a
//! fresh ratio. This is the slow, exact path — floats bypass it entirely.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const objects = @import("objects.zig");
const bignum = @import("bignum.zig");
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;

const Managed = std.math.big.int.Managed;

/// True if `v` is an exact rational: a fixnum, a bignum, or a ratio.
pub fn isRational(v: Value) bool {
    return bignum.isInteger(v) or objects.isRatio(v);
}

// An operand decomposed into (num, den) big-ints, den > 0.
const Parts = struct {
    num: Managed,
    den: Managed,
    fn deinit(self: *Parts) void {
        self.num.deinit();
        self.den.deinit();
    }
};

fn toParts(alloc: std.mem.Allocator, v: Value) !Parts {
    if (objects.isRatio(v)) {
        var num = try bignum.toManaged(alloc, objects.ratioNum(v));
        errdefer num.deinit();
        const den = try bignum.toManaged(alloc, objects.ratioDen(v));
        return .{ .num = num, .den = den };
    }
    // exact integer -> num/1
    var num = try bignum.toManaged(alloc, v);
    errdefer num.deinit();
    const den = try Managed.initSet(alloc, 1);
    return .{ .num = num, .den = den };
}

/// Convert an exact-integer Value (fixnum or bignum) to f64.
fn intToFloat(v: Value) f64 {
    if (value_mod.isFixnum(v)) return @floatFromInt(value_mod.fixnumVal(v));
    return bignum.toFloat(v);
}

/// Reduce a (num, den) big-int pair into a canonical Value: an integer when the
/// reduced denominator is 1, otherwise a fresh ratio. `num`/`den` are consumed
/// (mutated). Caller must ensure den != 0.
fn normalize(gc: *GC, num: *Managed, den: *Managed) !Value {
    const alloc = gc.allocator;
    // Force den > 0 (carry any sign onto num).
    if (!den.isPositive()) {
        num.negate();
        den.negate();
    }
    // g = gcd(|num|, den) (always > 0 since den > 0).
    var an = try num.clone();
    defer an.deinit();
    an.abs();
    var g = try Managed.init(alloc);
    defer g.deinit();
    try g.gcd(&an, den);
    // Reduce: num/=g, den/=g (both exact — g divides each).
    var rnum = try Managed.init(alloc);
    defer rnum.deinit();
    var rden = try Managed.init(alloc);
    defer rden.deinit();
    var rem = try Managed.init(alloc);
    defer rem.deinit();
    try rnum.divTrunc(&rem, num, &g);
    try rden.divTrunc(&rem, den, &g);
    // den == 1 -> plain integer.
    if (rden.toConst().orderAgainstScalar(1) == .eq) {
        return bignum.fromManaged(gc, &rnum);
    }
    // Build the ratio, rooting the numerator across the denominator allocation.
    var scope = gc_mod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const nslot = scope.push(try bignum.fromManaged(gc, &rnum));
    const dv = try bignum.fromManaged(gc, &rden);
    // Narrow gc.alloc's broad inferred error set so callers in the LispError
    // world can coerce (mirrors bignum.fromManaged — zepo-nfak).
    return objects.makeRatio(gc, nslot.*, dv) catch return error.OutOfMemory;
}

/// Build a reduced rational from two exact-integer Values. den == 0 errors.
pub fn make(gc: *GC, num_v: Value, den_v: Value) !Value {
    if (value_mod.isFixnum(den_v) and value_mod.fixnumVal(den_v) == 0) return error.DivisionByZero;
    var num = try bignum.toManaged(gc.allocator, num_v);
    defer num.deinit();
    var den = try bignum.toManaged(gc.allocator, den_v);
    defer den.deinit();
    return normalize(gc, &num, &den);
}

pub const RatOp = enum { add, sub, mul, div };

/// Exact +,-,*,/ over two rational Values (fixnum/bignum/ratio). Division by an
/// exact zero errors.
pub fn binop(gc: *GC, comptime op: RatOp, a: Value, b: Value) !Value {
    const alloc = gc.allocator;
    var pa = try toParts(alloc, a);
    defer pa.deinit();
    var pb = try toParts(alloc, b);
    defer pb.deinit();
    var num = try Managed.init(alloc);
    defer num.deinit();
    var den = try Managed.init(alloc);
    defer den.deinit();
    switch (op) {
        .mul => {
            try num.mul(&pa.num, &pb.num);
            try den.mul(&pa.den, &pb.den);
        },
        .div => {
            if (pb.num.eqlZero()) return error.DivisionByZero;
            try num.mul(&pa.num, &pb.den);
            try den.mul(&pa.den, &pb.num);
        },
        .add, .sub => {
            var t1 = try Managed.init(alloc);
            defer t1.deinit();
            var t2 = try Managed.init(alloc);
            defer t2.deinit();
            try t1.mul(&pa.num, &pb.den);
            try t2.mul(&pb.num, &pa.den);
            if (op == .add) try num.add(&t1, &t2) else try num.sub(&t1, &t2);
            try den.mul(&pa.den, &pb.den);
        },
    }
    return normalize(gc, &num, &den);
}

pub fn add(gc: *GC, a: Value, b: Value) !Value {
    return binop(gc, .add, a, b);
}
pub fn sub(gc: *GC, a: Value, b: Value) !Value {
    return binop(gc, .sub, a, b);
}
pub fn mul(gc: *GC, a: Value, b: Value) !Value {
    return binop(gc, .mul, a, b);
}
pub fn div(gc: *GC, a: Value, b: Value) !Value {
    return binop(gc, .div, a, b);
}

/// Order two rational Values (each fixnum/bignum/ratio). Cross-multiplies with
/// positive denominators, so the sign of the comparison is preserved.
pub fn order(alloc: std.mem.Allocator, a: Value, b: Value) !std.math.Order {
    var pa = try toParts(alloc, a);
    defer pa.deinit();
    var pb = try toParts(alloc, b);
    defer pb.deinit();
    var l = try Managed.init(alloc);
    defer l.deinit();
    var r = try Managed.init(alloc);
    defer r.deinit();
    try l.mul(&pa.num, &pb.den);
    try r.mul(&pb.num, &pa.den);
    return l.toConst().order(r.toConst());
}

/// Value equality of two integer Values (fixnum or bignum).
fn intEql(a: Value, b: Value) bool {
    if (value_mod.isFixnum(a) and value_mod.isFixnum(b)) return a == b;
    if (objects.isBignum(a) and objects.isBignum(b)) return bignum.eql(a, b);
    return false; // a fixnum is never in bignum range
}

/// Value equality of two ratios (both canonical, so compare num and den).
pub fn eql(a: Value, b: Value) bool {
    return intEql(objects.ratioNum(a), objects.ratioNum(b)) and
        intEql(objects.ratioDen(a), objects.ratioDen(b));
}

/// A ratio -> f64.
pub fn toFloat(v: Value) f64 {
    return intToFloat(objects.ratioNum(v)) / intToFloat(objects.ratioDen(v));
}

/// -x for a rational Value (integer or ratio).
pub fn negate(gc: *GC, v: Value) !Value {
    return sub(gc, value_mod.fixnum(0), v);
}

fn ratioNumIsNegative(v: Value) bool {
    const n = objects.ratioNum(v);
    if (value_mod.isFixnum(n)) return value_mod.fixnumVal(n) < 0;
    return !objects.bignumConst(n).positive;
}

/// |x| for a rational Value.
pub fn absValue(gc: *GC, v: Value) !Value {
    if (objects.isRatio(v)) return if (ratioNumIsNegative(v)) negate(gc, v) else v;
    return bignum.absValue(gc, v);
}

fn managedIsOdd(m: Managed) bool {
    const c = m.toConst();
    if (c.limbs.len == 0) return false;
    return (c.limbs[0] & 1) == 1;
}

pub const RoundMode = enum { floor, ceiling, truncate, round };

/// floor/ceiling/truncate/round of a rational Value to an exact integer. An
/// integer operand is returned unchanged. `round` uses round-half-to-even.
pub fn roundToInteger(gc: *GC, comptime mode: RoundMode, v: Value) !Value {
    if (!objects.isRatio(v)) return v; // an integer is its own floor/ceiling/etc.
    const alloc = gc.allocator;
    var num = try bignum.toManaged(alloc, objects.ratioNum(v));
    defer num.deinit();
    var den = try bignum.toManaged(alloc, objects.ratioDen(v)); // den > 0
    defer den.deinit();
    var q = try Managed.init(alloc);
    defer q.deinit();
    var r = try Managed.init(alloc);
    defer r.deinit();
    switch (mode) {
        .truncate => try q.divTrunc(&r, &num, &den),
        .floor => try q.divFloor(&r, &num, &den),
        .ceiling => {
            // ceil(n/d) = -floor(-n/d)
            num.negate();
            try q.divFloor(&r, &num, &den);
            q.negate();
        },
        .round => {
            // floor, then compare the remainder's double to the denominator;
            // ties (2r == d) round to even.
            try q.divFloor(&r, &num, &den); // r in [0, den)
            var two_r = try Managed.init(alloc);
            defer two_r.deinit();
            var two = try Managed.initSet(alloc, 2);
            defer two.deinit();
            try two_r.mul(&r, &two);
            const ord = two_r.order(den);
            const bump = ord == .gt or (ord == .eq and managedIsOdd(q));
            if (bump) {
                var q1 = try Managed.init(alloc);
                defer q1.deinit();
                try q1.addScalar(&q, 1);
                q.swap(&q1);
            }
        },
    }
    return bignum.fromManaged(gc, &q);
}

/// The numerator of a rational Value as an exact integer (an integer's own value).
pub fn numerator(v: Value) Value {
    if (objects.isRatio(v)) return objects.ratioNum(v);
    return v;
}

/// The denominator of a rational Value as an exact integer (1 for an integer).
pub fn denominator(v: Value) Value {
    if (objects.isRatio(v)) return objects.ratioDen(v);
    return value_mod.fixnum(1);
}

/// Render a ratio as "num/den" (base 10). Caller frees.
pub fn toString(alloc: std.mem.Allocator, v: Value) ![]u8 {
    const ns = try bignum.toString(alloc, objects.ratioNum(v));
    defer alloc.free(ns);
    const ds = try bignum.toString(alloc, objects.ratioDen(v));
    defer alloc.free(ds);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ ns, ds });
}

// 10^k as a big-int (built from the string "1" + k zeros — exact, no aliasing).
fn pow10(alloc: std.mem.Allocator, k: usize) !Managed {
    const buf = try alloc.alloc(u8, k + 1);
    defer alloc.free(buf);
    buf[0] = '1';
    @memset(buf[1..], '0');
    var m = try Managed.init(alloc);
    errdefer m.deinit();
    try m.setString(10, buf);
    return m;
}

/// The EXACT rational value of a base-10 decimal literal like "-12.34" or
/// "1.5e3" (as written, not the nearest float). Used by the reader's #e prefix.
/// So #e0.1 is exactly 1/10, not the float approximation.
pub fn fromDecimalExact(gc: *GC, text: []const u8) !Value {
    const alloc = gc.allocator;
    var digits: std.ArrayListUnmanaged(u8) = .empty;
    defer digits.deinit(alloc);
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var frac_len: i64 = 0; // digits after the decimal point
    var exp10: i64 = 0; // explicit e-notation exponent
    var seen_dot = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '.') {
            seen_dot = true;
            continue;
        }
        if (c == 'e' or c == 'E') {
            i += 1;
            var esign: i64 = 1;
            if (i < text.len and (text[i] == '+' or text[i] == '-')) {
                if (text[i] == '-') esign = -1;
                i += 1;
            }
            var ev: i64 = 0;
            while (i < text.len) : (i += 1) ev = ev * 10 + @as(i64, text[i] - '0');
            exp10 = esign * ev;
            break;
        }
        try digits.append(alloc, c);
        if (seen_dot) frac_len += 1;
    }
    if (digits.items.len == 0) try digits.append(alloc, '0');
    var num = try Managed.init(alloc);
    defer num.deinit();
    try num.setString(10, digits.items);
    if (negative) num.negate();
    var den = try Managed.initSet(alloc, 1);
    defer den.deinit();
    // value = num * 10^(exp10 - frac_len)
    const p = exp10 - frac_len;
    if (p >= 0) {
        var pw = try pow10(alloc, @intCast(p));
        defer pw.deinit();
        var t = try Managed.init(alloc);
        defer t.deinit();
        try t.mul(&num, &pw);
        num.swap(&t);
    } else {
        var pw = try pow10(alloc, @intCast(-p));
        den.swap(&pw); // den = 10^|p|, pw = old den (1)
        pw.deinit();
    }
    return normalize(gc, &num, &den);
}

/// Exact rational equal to a finite float `f` (f == m * 2^e exactly). Used by
/// inexact->exact.
pub fn fromFloat(gc: *GC, f: f64) !Value {
    const alloc = gc.allocator;
    const fr = std.math.frexp(f);
    // significand in [0.5, 1); scale by 2^53 to an integer mantissa.
    const scaled = fr.significand * 9007199254740992.0; // 2^53
    const m: i64 = @intFromFloat(scaled);
    const shift: i32 = fr.exponent - 53;
    var num = try Managed.initSet(alloc, @as(i128, m));
    defer num.deinit();
    var den = try Managed.initSet(alloc, 1);
    defer den.deinit();
    if (shift >= 0) {
        try num.shiftLeft(&num, @intCast(shift));
    } else {
        try den.shiftLeft(&den, @intCast(-shift));
    }
    return normalize(gc, &num, &den);
}
