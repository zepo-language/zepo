//! Transcendental and advanced math primitives.

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

fn boolVal(b: bool) Value {
    return if (b) value_mod.TRUE else value_mod.FALSE;
}

fn asFloat(v: Value) ?f64 {
    if (value_mod.isFixnum(v)) return @floatFromInt(value_mod.fixnumVal(v));
    if (objects.isFloat(v)) return objects.floatVal(v);
    return null;
}

fn mkf(vm: *VM, f: f64) LispError!Value {
    return objects.makeFloat(vm.gc, f) catch error.OutOfMemory;
}

// ── Unary float→float ──────────────────────────────────────────────────────

pub fn primSqrt(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @sqrt(x));
}

pub fn primCbrt(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, std.math.cbrt(x));
}

pub fn primExp(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @exp(x));
}

pub fn primLn(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @log(x));
}

pub fn primLog10(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @log10(x));
}

pub fn primLog2(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @log2(x));
}

pub fn primSin(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @sin(x));
}

pub fn primCos(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @cos(x));
}

pub fn primTan(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, @tan(x));
}

pub fn primAsin(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, std.math.asin(x));
}

pub fn primAcos(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, std.math.acos(x));
}

pub fn primAtan(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, std.math.atan(x));
}

pub fn primSinh(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, std.math.sinh(x));
}

pub fn primCosh(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, std.math.cosh(x));
}

pub fn primTanh(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    return mkf(vm, std.math.tanh(x));
}

// ── abs (fixnum-aware) ─────────────────────────────────────────────────────

pub fn primAbs(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    if (value_mod.isFixnum(v)) {
        const n = value_mod.fixnumVal(v);
        return value_mod.fixnum(@intCast(if (n < 0) -n else n));
    }
    if (objects.isFloat(v)) return mkf(vm, @abs(objects.floatVal(v)));
    return error.TypeError;
}

// ── Binary float→float ─────────────────────────────────────────────────────

pub fn primPow(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    const y = asFloat(args[1]) orelse return error.TypeError;
    return mkf(vm, std.math.pow(f64, x, y));
}

pub fn primAtan2(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const y = asFloat(args[0]) orelse return error.TypeError;
    const x = asFloat(args[1]) orelse return error.TypeError;
    return mkf(vm, std.math.atan2(y, x));
}

pub fn primCopysign(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    const y = asFloat(args[1]) orelse return error.TypeError;
    return mkf(vm, std.math.copysign(x, y));
}

pub fn primHypot(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    const y = asFloat(args[1]) orelse return error.TypeError;
    return mkf(vm, std.math.hypot(x, y));
}

pub fn primFmod(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const x = asFloat(args[0]) orelse return error.TypeError;
    const y = asFloat(args[1]) orelse return error.TypeError;
    return mkf(vm, @rem(x, y));
}

// ── Zero-arity special float constants ────────────────────────────────────

pub fn primInf(vm: *VM, args: []const Value) LispError!Value {
    _ = args;
    return mkf(vm, std.math.inf(f64));
}

pub fn primNegInf(vm: *VM, args: []const Value) LispError!Value {
    _ = args;
    return mkf(vm, -std.math.inf(f64));
}

pub fn primNan(vm: *VM, args: []const Value) LispError!Value {
    _ = args;
    return mkf(vm, std.math.nan(f64));
}

// ── Float predicates ───────────────────────────────────────────────────────

pub fn primNanQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    if (value_mod.isFixnum(v)) return value_mod.FALSE;
    if (objects.isFloat(v)) return boolVal(std.math.isNan(objects.floatVal(v)));
    return error.TypeError;
}

pub fn primFiniteQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    if (value_mod.isFixnum(v)) return value_mod.TRUE;
    if (objects.isFloat(v)) return boolVal(std.math.isFinite(objects.floatVal(v)));
    return error.TypeError;
}

pub fn primInfiniteQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    if (value_mod.isFixnum(v)) return value_mod.FALSE;
    if (objects.isFloat(v)) return boolVal(std.math.isInf(objects.floatVal(v)));
    return error.TypeError;
}
