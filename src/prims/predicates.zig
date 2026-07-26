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

// zepo-gz21: (type-of x) → a symbol naming x's type, in O(1). Drives
// single-dispatch generics (defgeneric/defmethod). A defstruct value is a
// vector tagged #( %struct <type-sym> field... ); type-of returns <type-sym>.
// Numbers report the specific type (integer/float), not a coarse "number".
pub fn primTypeOf(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    const name: []const u8 = blk: {
        if (value_mod.isFixnum(v)) break :blk "integer";
        if (value_mod.isNil(v)) break :blk "null";
        if (v == value_mod.TRUE or v == value_mod.FALSE) break :blk "boolean";
        if (value_mod.isChar(v)) break :blk "char";
        if (objects.isFloat(v)) break :blk "float";
        if (objects.isVector(v)) {
            // %struct-tagged vector → its declared type symbol.
            if (objects.vectorLen(v) >= 2) {
                const tag = objects.vectorGet(v, 0);
                if (objects.isSymbol(tag) and std.mem.eql(u8, objects.symbolName(tag), "%struct")) {
                    return objects.vectorGet(v, 1);
                }
            }
            break :blk "vector";
        }
        if (objects.isPair(v)) break :blk "pair";
        if (objects.isString(v)) break :blk "string";
        if (objects.isSymbol(v)) break :blk "symbol";
        if (objects.isClosure(v) or objects.isPrim(v) or objects.isParameter(v)) break :blk "procedure";
        if (objects.isBytevector(v)) break :blk "bytevector";
        if (objects.isFiber(v)) break :blk "fiber";
        if (objects.isParameter(v)) break :blk "parameter";
        if (objects.isKind(v, .hash_table)) break :blk "hash-table";
        if (objects.isForeign(v)) break :blk "foreign";
        break :blk "unknown";
    };
    return vm.symbols.intern(name) catch error.OutOfMemory;
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
    return value_mod.isFixnum(v) or objects.isFloat(v) or objects.isBignum(v); // zepo-nfak
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
    return boolVal(value_mod.isFixnum(v) or objects.isBignum(v)); // zepo-nfak
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
