//! Type-predicate primitives.

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

fn unary(args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return args[0];
}

pub fn primSymbolQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    return boolVal(objects.isSymbol(v));
}

pub fn primBooleanQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    return boolVal(v == value_mod.TRUE or v == value_mod.FALSE);
}

fn isRealNum(v: Value) bool {
    if (v == value_mod.NIL or v == value_mod.TRUE or v == value_mod.FALSE) return false;
    return value_mod.isFixnum(v) or objects.isFloat(v);
}

pub fn primNumberQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    return boolVal(isRealNum(v));
}

pub fn primIntegerQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    if (v == value_mod.NIL or v == value_mod.TRUE or v == value_mod.FALSE) return value_mod.FALSE;
    return boolVal(value_mod.isFixnum(v));
}

pub fn primFloatQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    return boolVal(objects.isFloat(v));
}

pub fn primCharQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    return boolVal(value_mod.isChar(v));
}

pub fn primStringQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    return boolVal(objects.isString(v));
}

pub fn primProcedureQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const v = try unary(args);
    return boolVal(objects.isProcedure(v));
}
