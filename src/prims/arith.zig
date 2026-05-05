//! Arithmetic primitives with integer+float promotion.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;

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
    return objects.floatVal(v);
}

fn makeNum(vm: *VM, is_float: bool, int_v: i64, float_v: f64) LispError!Value {
    if (is_float) {
        return objects.makeFloat(vm.gc, float_v) catch error.OutOfMemory;
    }
    // Fit into i63.
    if (int_v > (@as(i64, 1) << 62) - 1 or int_v < -(@as(i64, 1) << 62)) {
        // Overflow: promote to float.
        return objects.makeFloat(vm.gc, @floatFromInt(int_v)) catch error.OutOfMemory;
    }
    return value_mod.fixnum(@intCast(int_v));
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

// Encode an i64 as fixnum if it fits in i63 range; otherwise return null.
inline fn tryEncodeFixnum(n: i64) ?Value {
    const max_i63: i64 = (@as(i64, 1) << 62) - 1;
    const min_i63: i64 = -(@as(i64, 1) << 62);
    if (n > max_i63 or n < min_i63) return null;
    return value_mod.fixnum(@intCast(n));
}

pub fn primAdd(vm: *VM, args: []const Value) LispError!Value {
    // zepo-712: 2-arg fixnum fast path.
    if (args.len == 2 and bothFixnum(args[0], args[1])) {
        const av = value_mod.fixnumVal(args[0]);
        const bv = value_mod.fixnumVal(args[1]);
        const r = std.math.add(i64, @as(i64, av), @as(i64, bv)) catch
            return makeNum(vm, true, 0, @as(f64, @floatFromInt(av)) + @as(f64, @floatFromInt(bv)));
        if (tryEncodeFixnum(r)) |fx| return fx;
        return makeNum(vm, true, 0, @floatFromInt(r));
    }
    const any_f = try anyFloat(args);
    if (any_f) {
        var acc: f64 = 0;
        for (args) |v| acc += toFloat(v);
        return makeNum(vm, true, 0, acc);
    } else {
        var acc: i64 = 0;
        for (args) |v| {
            const n: i64 = value_mod.fixnumVal(v);
            acc = std.math.add(i64, acc, n) catch return error.ContractViolation;
        }
        return makeNum(vm, false, acc, 0);
    }
}

pub fn primSub(vm: *VM, args: []const Value) LispError!Value {
    if (args.len == 0) return error.ArityMismatch;
    // zepo-712: 2-arg fixnum fast path.
    if (args.len == 2 and bothFixnum(args[0], args[1])) {
        const av = value_mod.fixnumVal(args[0]);
        const bv = value_mod.fixnumVal(args[1]);
        const r = std.math.sub(i64, @as(i64, av), @as(i64, bv)) catch
            return makeNum(vm, true, 0, @as(f64, @floatFromInt(av)) - @as(f64, @floatFromInt(bv)));
        if (tryEncodeFixnum(r)) |fx| return fx;
        return makeNum(vm, true, 0, @floatFromInt(r));
    }
    const any_f = try anyFloat(args);
    if (any_f) {
        if (args.len == 1) return makeNum(vm, true, 0, -toFloat(args[0]));
        var acc = toFloat(args[0]);
        for (args[1..]) |v| acc -= toFloat(v);
        return makeNum(vm, true, 0, acc);
    } else {
        if (args.len == 1) {
            const n: i64 = value_mod.fixnumVal(args[0]);
            const neg = std.math.negate(n) catch return error.ContractViolation;
            return makeNum(vm, false, neg, 0);
        }
        var acc: i64 = value_mod.fixnumVal(args[0]);
        for (args[1..]) |v| {
            const n: i64 = value_mod.fixnumVal(v);
            acc = std.math.sub(i64, acc, n) catch return error.ContractViolation;
        }
        return makeNum(vm, false, acc, 0);
    }
}

pub fn primMul(vm: *VM, args: []const Value) LispError!Value {
    // zepo-712: 2-arg fixnum fast path.
    if (args.len == 2 and bothFixnum(args[0], args[1])) {
        const av = value_mod.fixnumVal(args[0]);
        const bv = value_mod.fixnumVal(args[1]);
        const r = std.math.mul(i64, @as(i64, av), @as(i64, bv)) catch
            return makeNum(vm, true, 0, @as(f64, @floatFromInt(av)) * @as(f64, @floatFromInt(bv)));
        if (tryEncodeFixnum(r)) |fx| return fx;
        return makeNum(vm, true, 0, @floatFromInt(r));
    }
    const any_f = try anyFloat(args);
    if (any_f) {
        var acc: f64 = 1;
        for (args) |v| acc *= toFloat(v);
        return makeNum(vm, true, 0, acc);
    } else {
        var acc: i64 = 1;
        for (args) |v| {
            const n: i64 = value_mod.fixnumVal(v);
            acc = std.math.mul(i64, acc, n) catch return error.ContractViolation;
        }
        return makeNum(vm, false, acc, 0);
    }
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
            const vf = toFloat(v);
            if (vf == 0) return error.DivisionByZero;
            acc /= vf;
        }
        return makeNum(vm, true, 0, acc);
    }
    // All ints, 2+ args.
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

fn compareAdjacent(args: []const Value, op: fn (f64, f64) bool) LispError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var prev = args[0];
    if (!isNum(prev)) return error.TypeError;
    for (args[1..]) |cur| {
        if (!isNum(cur)) return error.TypeError;
        if (!op(toFloat(prev), toFloat(cur))) return value_mod.FALSE;
        prev = cur;
    }
    return value_mod.TRUE;
}

fn fEq(a: f64, b: f64) bool {
    return a == b;
}
fn fLt(a: f64, b: f64) bool {
    return a < b;
}
fn fGt(a: f64, b: f64) bool {
    return a > b;
}
fn fLte(a: f64, b: f64) bool {
    return a <= b;
}
fn fGte(a: f64, b: f64) bool {
    return a >= b;
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
    _ = vm;
    if (cmpFastFixnum(args, .eq)) |r| return r;
    return compareAdjacent(args, fEq);
}
pub fn primLt(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (cmpFastFixnum(args, .lt)) |r| return r;
    return compareAdjacent(args, fLt);
}
pub fn primGt(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (cmpFastFixnum(args, .gt)) |r| return r;
    return compareAdjacent(args, fGt);
}
pub fn primLte(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (cmpFastFixnum(args, .lte)) |r| return r;
    return compareAdjacent(args, fLte);
}
pub fn primGte(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (cmpFastFixnum(args, .gte)) |r| return r;
    return compareAdjacent(args, fGte);
}

pub fn primModulo(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0]) or !value_mod.isFixnum(args[1])) return error.TypeError;
    const a = value_mod.fixnumVal(args[0]);
    const b = value_mod.fixnumVal(args[1]);
    if (b == 0) return error.DivisionByZero;
    const r = @rem(a, b);
    const result: i64 = if (r == 0) 0 else if ((r > 0) == (b > 0)) r else r + b;
    return makeNum(vm, false, result, 0);
}

pub fn primRemainder(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0]) or !value_mod.isFixnum(args[1])) return error.TypeError;
    const a = value_mod.fixnumVal(args[0]);
    const b = value_mod.fixnumVal(args[1]);
    if (b == 0) return error.DivisionByZero;
    return makeNum(vm, false, @rem(a, b), 0);
}

pub fn primQuotient(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0]) or !value_mod.isFixnum(args[1])) return error.TypeError;
    const a = value_mod.fixnumVal(args[0]);
    const b = value_mod.fixnumVal(args[1]);
    if (b == 0) return error.DivisionByZero;
    return makeNum(vm, false, @divTrunc(a, b), 0);
}

pub fn primFloor(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0])) return args[0];
    return makeNum(vm, true, 0, @floor(objects.floatVal(args[0])));
}

pub fn primCeiling(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0])) return args[0];
    return makeNum(vm, true, 0, @ceil(objects.floatVal(args[0])));
}

pub fn primRound(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0])) return args[0];
    return makeNum(vm, true, 0, @round(objects.floatVal(args[0])));
}

pub fn primTruncate(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0])) return args[0];
    return makeNum(vm, true, 0, @trunc(objects.floatVal(args[0])));
}

pub fn primExactToInexact(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (objects.isFloat(args[0])) return args[0];
    const i = value_mod.fixnumVal(args[0]);
    return objects.makeFloat(vm.gc, @floatFromInt(i)) catch error.OutOfMemory;
}

pub fn primInexactToExact(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isNum(args[0])) return error.TypeError;
    if (value_mod.isFixnum(args[0])) return args[0];
    const f = objects.floatVal(args[0]);
    const i: i64 = @intFromFloat(@trunc(f));
    return makeNum(vm, false, i, 0);
}
