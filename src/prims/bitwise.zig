//! Bitwise integer primitives.

// zepo-qny
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

/// Extract an i64 from a fixnum or float Value. Floats are truncated to integer.
fn toInt(v: Value) LispError!i64 {
    if (value_mod.isFixnum(v)) return @as(i64, value_mod.fixnumVal(v));
    if (objects.isFloat(v)) return @intFromFloat(@trunc(objects.floatVal(v)));
    return error.TypeError;
}

/// Encode an i64 result back as a fixnum when it fits the fixnum range,
/// otherwise box it as a float.
fn fromInt(vm: *VM, n: i64) LispError!Value {
    // zepo-9usm: single source of truth for the fixnum range.
    if (value_mod.fixnumFits(n)) {
        return value_mod.fixnum(@intCast(n));
    }
    // Overflow: store as float boxed object.
    return objects.makeFloat(vm.gc, @floatFromInt(n)) catch error.OutOfMemory;
}

// zepo-qny
pub fn primBitwiseAnd(vm: *VM, args: []const Value) LispError!Value {
    var acc: i64 = -1; // identity for AND
    for (args) |v| {
        const n = try toInt(v);
        acc &= n;
    }
    return fromInt(vm, acc);
}

// zepo-qny
pub fn primBitwiseOr(vm: *VM, args: []const Value) LispError!Value {
    var acc: i64 = 0; // identity for OR
    for (args) |v| {
        const n = try toInt(v);
        acc |= n;
    }
    return fromInt(vm, acc);
}

// zepo-qny
pub fn primBitwiseXor(vm: *VM, args: []const Value) LispError!Value {
    var acc: i64 = 0; // identity for XOR
    for (args) |v| {
        const n = try toInt(v);
        acc ^= n;
    }
    return fromInt(vm, acc);
}

// zepo-qny
pub fn primBitwiseNot(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const n = try toInt(args[0]);
    return fromInt(vm, ~n);
}

// zepo-qny
pub fn primArithmeticShift(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const n = try toInt(args[0]);
    const shift = try toInt(args[1]);
    if (shift >= 0) {
        // Left shift; cap at 63 to avoid UB.
        const s: u6 = @intCast(@min(shift, 63));
        return fromInt(vm, n << s);
    } else {
        // Right shift (arithmetic — sign-extending).
        const s: u6 = @intCast(@min(-shift, 63));
        return fromInt(vm, n >> s);
    }
}

// zepo-qny
pub fn primBitCount(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const n = try toInt(args[0]);
    // popcount on the unsigned bit pattern.
    const bits: u64 = @bitCast(n);
    const count: i64 = @intCast(@popCount(bits));
    return fromInt(vm, count);
}
