//! Arithmetic primitives with integer+float promotion.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const bignum = runtime.bignum; // zepo-nfak

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

const NumBundle = struct {
    all_int: bool,
    int_acc: i64,
    float_acc: f64,
};

fn isNum(v: Value) bool {
    return objects.isNumber(v);
}

fn toFloat(v: Value) f64 {
    if (value_mod.isFixnum(v)) return @floatFromInt(value_mod.fixnumVal(v));
    if (objects.isBignum(v)) return bignum.toFloat(v); // zepo-nfak
    return objects.floatVal(v);
}

fn makeNum(vm: *VM, is_float: bool, int_v: i64, float_v: f64) LispError!Value {
    if (is_float) {
        return objects.makeFloat(vm.gc, float_v) catch error.OutOfMemory;
    }
    // zepo-nfak: an exact integer result outside the fixnum range promotes to an
    // exact bignum (was: silently to a float, losing precision — zepo-9usm).
    if (!value_mod.fixnumFits(int_v)) {
        return bignum.fromI64(vm.gc, int_v);
    }
    return value_mod.fixnum(@intCast(int_v));
}

// zepo-nfak: exact +,-,* on two integer Values (fixnum or bignum). Fast path
// keeps both fixnums in i64 while the result fits; anything else (a bignum
// operand, or a fixnum operation that overflows i64 or the fixnum range) falls
// back to arbitrary-precision arithmetic and normalizes the result.
const ExactOp = enum { add, sub, mul };
fn exactBinop(vm: *VM, comptime op: ExactOp, a: Value, b: Value) LispError!Value {
    if (bothFixnum(a, b)) {
        const av: i64 = value_mod.fixnumVal(a);
        const bv: i64 = value_mod.fixnumVal(b);
        const r: ?i64 = switch (op) {
            .add => std.math.add(i64, av, bv) catch null,
            .sub => std.math.sub(i64, av, bv) catch null,
            .mul => std.math.mul(i64, av, bv) catch null,
        };
        if (r) |rv| {
            if (tryEncodeFixnum(rv)) |fx| return fx;
        }
        // fell through: i64 overflow or out-of-fixnum-range → bignum.
    }
    return switch (op) {
        .add => bignum.add(vm.gc, a, b),
        .sub => bignum.sub(vm.gc, a, b),
        .mul => bignum.mul(vm.gc, a, b),
    };
}

/// Classify all args; returns whether any is a float.
fn anyFloat(args: []const Value) LispError!bool {
    var any_f = false;
    for (args) |v| {
        if (!isNum(v)) return error.TypeError;
        if (objects.isFloat(v)) any_f = true;
    }
    return any_f;
}

// zepo-712: fixnum bit-pattern fast checks. Tag = 001 (Tag.fixnum=1).
// `((a ^ 1) | (b ^ 1)) & 7 == 0` is true iff BOTH a and b have low-3-bit
// tag exactly 001 — single XOR/OR/AND/CMP, faster than two isFixnum calls.
inline fn bothFixnum(a: Value, b: Value) bool {
    return ((a ^ 1) | (b ^ 1)) & 7 == 0;
}

// Encode an i64 as a fixnum if it fits the fixnum range; otherwise return null.
inline fn tryEncodeFixnum(n: i64) ?Value {
    // zepo-9usm: single source of truth for the fixnum range.
    if (!value_mod.fixnumFits(n)) return null;
    return value_mod.fixnum(@intCast(n));
}

pub fn primAdd(vm: *VM, args: []const Value) LispError!Value {
    // zepo-712/nfak: 2-arg fixnum fast path; overflow promotes to an exact bignum.
    if (args.len == 2 and bothFixnum(args[0], args[1])) {
        const av = value_mod.fixnumVal(args[0]);
        const bv = value_mod.fixnumVal(args[1]);
        const r = std.math.add(i64, @as(i64, av), @as(i64, bv)) catch
            return exactBinop(vm, .add, args[0], args[1]);
        if (tryEncodeFixnum(r)) |fx| return fx;
        return bignum.fromI64(vm.gc, r);
    }
    const any_f = try anyFloat(args);
    if (any_f) {
        var acc: f64 = 0;
        for (args) |v| acc += toFloat(v);
        return makeNum(vm, true, 0, acc);
    }
    // Exact fold (fixnum/bignum), promoting to bignum on any overflow.
    if (args.len == 0) return value_mod.fixnum(0);
    var acc: Value = args[0];
    for (args[1..]) |v| acc = try exactBinop(vm, .add, acc, v);
    return acc;
}

pub fn primSub(vm: *VM, args: []const Value) LispError!Value {
    if (args.len == 0) return error.ArityMismatch;
    // zepo-712: 2-arg fixnum fast path.
    if (args.len == 2 and bothFixnum(args[0], args[1])) {
        const av = value_mod.fixnumVal(args[0]);
        const bv = value_mod.fixnumVal(args[1]);
        const r = std.math.sub(i64, @as(i64, av), @as(i64, bv)) catch
            return exactBinop(vm, .sub, args[0], args[1]);
        if (tryEncodeFixnum(r)) |fx| return fx;
        return bignum.fromI64(vm.gc, r);
    }
    const any_f = try anyFloat(args);
    if (any_f) {
        if (args.len == 1) return makeNum(vm, true, 0, -toFloat(args[0]));
        var acc = toFloat(args[0]);
        for (args[1..]) |v| acc -= toFloat(v);
        return makeNum(vm, true, 0, acc);
    }
    // Exact (fixnum/bignum). Unary is negation: 0 - x.
    if (args.len == 1) return exactBinop(vm, .sub, value_mod.fixnum(0), args[0]);
    var acc: Value = args[0];
    for (args[1..]) |v| acc = try exactBinop(vm, .sub, acc, v);
    return acc;
}

pub fn primMul(vm: *VM, args: []const Value) LispError!Value {
    // zepo-712: 2-arg fixnum fast path.
    if (args.len == 2 and bothFixnum(args[0], args[1])) {
        const av = value_mod.fixnumVal(args[0]);
        const bv = value_mod.fixnumVal(args[1]);
        const r = std.math.mul(i64, @as(i64, av), @as(i64, bv)) catch
            return exactBinop(vm, .mul, args[0], args[1]);
        if (tryEncodeFixnum(r)) |fx| return fx;
        return bignum.fromI64(vm.gc, r);
    }
    const any_f = try anyFloat(args);
    if (any_f) {
        var acc: f64 = 1;
        for (args) |v| acc *= toFloat(v);
        return makeNum(vm, true, 0, acc);
    }
    if (args.len == 0) return value_mod.fixnum(1);
    var acc: Value = args[0];
    for (args[1..]) |v| acc = try exactBinop(vm, .mul, acc, v);
    return acc;
}

pub fn primDiv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len == 0) return error.ArityMismatch;
    // zepo-712: 2-arg fixnum fast path. Exact divide stays fixnum,
    // otherwise return float (matches Scheme's int+int → float on inexact).
    if (args.len == 2 and bothFixnum(args[0], args[1])) {
        const av = value_mod.fixnumVal(args[0]);
        const bv = value_mod.fixnumVal(args[1]);
        if (bv == 0) return error.DivisionByZero;
        if (@mod(@as(i64, av), @as(i64, bv)) == 0) {
            const r = @divTrunc(@as(i64, av), @as(i64, bv));
            if (tryEncodeFixnum(r)) |fx| return fx;
        }
        return makeNum(vm, true, 0, @as(f64, @floatFromInt(av)) / @as(f64, @floatFromInt(bv)));
    }
    // Scheme (/) with all int args still produces an int when divisible; we
    // keep it simple: if all ints and exact divides, return int; otherwise
    // return float.
    const any_f = try anyFloat(args);
    if (any_f or args.len == 1) {
        var acc: f64 = if (args.len == 1) 1 else toFloat(args[0]);
        const start: usize = if (args.len == 1) 0 else 1;
        for (args[start..]) |v| {
            // zepo-mqvc: R7RS/IEEE — this branch is inexact (some operand is a
            // float). Division by an INEXACT zero yields ±inf.0 / +nan.0 via
            // ordinary IEEE division; only division by an EXACT (fixnum) zero
            // stays an error (matching (/ 1.0 0) → error, (/ 1.0 0.0) → +inf.0).
            if (value_mod.isFixnum(v) and value_mod.fixnumVal(v) == 0) return error.DivisionByZero;
            acc /= toFloat(v);
        }
        return makeNum(vm, true, 0, acc);
    }
    // All exact integers, 2+ args. Fast path: all fixnums stay in i64.
    var all_fixnum = true;
    for (args) |v| {
        if (!value_mod.isFixnum(v)) {
            all_fixnum = false;
            break;
        }
    }
    if (all_fixnum) {
        var int_acc: i64 = value_mod.fixnumVal(args[0]);
        var float_needed = false;
        var float_acc: f64 = @floatFromInt(int_acc);
        for (args[1..]) |v| {
            const n: i64 = value_mod.fixnumVal(v);
            if (n == 0) return error.DivisionByZero;
            if (!float_needed and @mod(int_acc, n) == 0) {
                int_acc = @divTrunc(int_acc, n);
                float_acc = @floatFromInt(int_acc);
            } else {
                float_needed = true;
                float_acc /= @floatFromInt(n);
            }
        }
        if (float_needed) return makeNum(vm, true, 0, float_acc);
        return makeNum(vm, false, int_acc, 0);
    }
    // zepo-nfak: a bignum operand. 2-arg exact division is exact when divisible
    // (no rationals yet — see zepo-or1d), otherwise a float. n-ary falls to float.
    if (args.len == 2) {
        if (isExactZero(args[1])) return error.DivisionByZero;
        const rem = try bignum.remainder(vm.gc, args[0], args[1]);
        if (isExactZero(rem)) return bignum.quotient(vm.gc, args[0], args[1]);
        return makeNum(vm, true, 0, toFloat(args[0]) / toFloat(args[1]));
    }
    var acc: f64 = toFloat(args[0]);
    for (args[1..]) |v| {
        if (isExactZero(v)) return error.DivisionByZero;
        acc /= toFloat(v);
    }
    return makeNum(vm, true, 0, acc);
}

const CmpOp = enum { eq, lt, gt, lte, gte };

// zepo-nfak: compare two numbers. An exact-integer PAIR (fixnum/bignum) is
// compared EXACTLY (converting a huge bignum to f64 would lose precision and
// give wrong answers); if a float is involved, compare as f64 (NaN-correct).
fn compareOne(vm: *VM, comptime op: CmpOp, a: Value, b: Value) LispError!bool {
    if (bignum.isInteger(a) and bignum.isInteger(b)) {
        const ord: std.math.Order = if (bothFixnum(a, b))
            std.math.order(value_mod.fixnumVal(a), value_mod.fixnumVal(b))
        else
            try bignum.order(vm.gc.allocator, a, b);
        return switch (op) {
            .eq => ord == .eq,
            .lt => ord == .lt,
            .gt => ord == .gt,
            .lte => ord != .gt,
            .gte => ord != .lt,
        };
    }
    const af = toFloat(a);
    const bf = toFloat(b);
    return switch (op) {
        .eq => af == bf,
        .lt => af < bf,
        .gt => af > bf,
        .lte => af <= bf,
        .gte => af >= bf,
    };
}

fn compareAdjacent(vm: *VM, args: []const Value, comptime op: CmpOp) LispError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var prev = args[0];
    if (!isNum(prev)) return error.TypeError;
    for (args[1..]) |cur| {
        if (!isNum(cur)) return error.TypeError;
        if (!try compareOne(vm, op, prev, cur)) return value_mod.FALSE;
        prev = cur;
    }
    return value_mod.TRUE;
}

// zepo-712: 2-arg fixnum fast path for comparisons. Bit-equal Values that
// are both fixnums compare equal/less/greater on raw u64 — but signed
// comparison needs the i63 view, so we extract and compare as i64. For ==
// we can compare encoded Values directly (bit equality of fixnum tags).
inline fn cmpFastFixnum(args: []const Value, comptime op: enum { eq, lt, gt, lte, gte }) ?Value {
    if (args.len != 2 or !bothFixnum(args[0], args[1])) return null;
    if (op == .eq) {
        return if (args[0] == args[1]) value_mod.TRUE else value_mod.FALSE;
    }
    const av = value_mod.fixnumVal(args[0]);
    const bv = value_mod.fixnumVal(args[1]);
    const result = switch (op) {
        .eq => av == bv, // unreachable
        .lt => av < bv,
        .gt => av > bv,
        .lte => av <= bv,
        .gte => av >= bv,
    };
    return if (result) value_mod.TRUE else value_mod.FALSE;
}

pub fn primNumEq(vm: *VM, args: []const Value) LispError!Value {
    if (cmpFastFixnum(args, .eq)) |r| return r;
    return compareAdjacent(vm, args, .eq);
}
pub fn primLt(vm: *VM, args: []const Value) LispError!Value {
    if (cmpFastFixnum(args, .lt)) |r| return r;
    return compareAdjacent(vm, args, .lt);
}
pub fn primGt(vm: *VM, args: []const Value) LispError!Value {
    if (cmpFastFixnum(args, .gt)) |r| return r;
    return compareAdjacent(vm, args, .gt);
}
pub fn primLte(vm: *VM, args: []const Value) LispError!Value {
    if (cmpFastFixnum(args, .lte)) |r| return r;
    return compareAdjacent(vm, args, .lte);
}
pub fn primGte(vm: *VM, args: []const Value) LispError!Value {
    if (cmpFastFixnum(args, .gte)) |r| return r;
    return compareAdjacent(vm, args, .gte);
}

// zepo-nfak: a bignum is never in fixnum range, so the only integer zero is a
// fixnum 0.
inline fn isExactZero(v: Value) bool {
    return value_mod.isFixnum(v) and value_mod.fixnumVal(v) == 0;
}

pub fn primModulo(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    // Exact integer modulo (fixnum/bignum).
    if (bignum.isInteger(args[0]) and bignum.isInteger(args[1])) {
        if (isExactZero(args[1])) return error.DivisionByZero;
        if (bothFixnum(args[0], args[1])) {
            const a = value_mod.fixnumVal(args[0]);
            const b = value_mod.fixnumVal(args[1]);
            const r = @rem(a, b);
            const result: i64 = if (r == 0) 0 else if ((r > 0) == (b > 0)) r else r + b;
            return makeNum(vm, false, result, 0);
        }
        return bignum.modulo(vm.gc, args[0], args[1]);
    }
    // Float modulo (preserves the prior binaryFloatOp behavior for MOD2).
    if (!isNum(args[0]) or !isNum(args[1])) return error.TypeError;
    const fb = toFloat(args[1]);
    if (fb == 0) return error.DivisionByZero;
    const fa = toFloat(args[0]);
    const r = @rem(fa, fb);
    const result: f64 = if (r == 0) 0 else if ((r > 0) == (fb > 0)) r else r + fb;
    return makeNum(vm, true, 0, result);
}

pub fn primRemainder(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!bignum.isInteger(args[0]) or !bignum.isInteger(args[1])) return error.TypeError;
    if (isExactZero(args[1])) return error.DivisionByZero;
    if (bothFixnum(args[0], args[1])) {
        return makeNum(vm, false, @rem(value_mod.fixnumVal(args[0]), value_mod.fixnumVal(args[1])), 0);
    }
    return bignum.remainder(vm.gc, args[0], args[1]);
}

pub fn primQuotient(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!bignum.isInteger(args[0]) or !bignum.isInteger(args[1])) return error.TypeError;
    if (isExactZero(args[1])) return error.DivisionByZero;
    if (bothFixnum(args[0], args[1])) {
        return makeNum(vm, false, @divTrunc(value_mod.fixnumVal(args[0]), value_mod.fixnumVal(args[1])), 0);
    }
    return bignum.quotient(vm.gc, args[0], args[1]);
}

pub fn primFloor(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0]) or objects.isBignum(args[0])) return args[0]; // zepo-nfak
    return makeNum(vm, true, 0, @floor(objects.floatVal(args[0])));
}

pub fn primCeiling(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0]) or objects.isBignum(args[0])) return args[0]; // zepo-nfak
    return makeNum(vm, true, 0, @ceil(objects.floatVal(args[0])));
}

pub fn primRound(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0]) or objects.isBignum(args[0])) return args[0]; // zepo-nfak
    return makeNum(vm, true, 0, @round(objects.floatVal(args[0])));
}

pub fn primTruncate(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0]) or objects.isBignum(args[0])) return args[0]; // zepo-nfak
    return makeNum(vm, true, 0, @trunc(objects.floatVal(args[0])));
}

pub fn primExactToInexact(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (objects.isFloat(args[0])) return args[0];
    // fixnum or bignum → f64 (zepo-nfak)
    return objects.makeFloat(vm.gc, toFloat(args[0])) catch error.OutOfMemory;
}

pub fn primInexactToExact(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0]) or objects.isBignum(args[0])) return args[0]; // zepo-nfak
    const f = objects.floatVal(args[0]);
    const i: i64 = @intFromFloat(@trunc(f));
    return makeNum(vm, false, i, 0);
}
