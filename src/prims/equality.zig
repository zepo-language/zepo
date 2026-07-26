//! Equality primitives: eq? (identity) and equal? (structural).

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

pub fn primEqQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    return if (args[0] == args[1]) value_mod.TRUE else value_mod.FALSE;
}

// zepo-rddw: eqv? — identity, plus value equality for numbers WITHOUT crossing
// the exact/inexact boundary. Two distinct boxed floats are eqv? iff they have
// the same bit pattern; this matches hashValue (which hashes floats by bits),
// so equal-keys-hash-equally holds. Fixnums/chars/booleans/nil/interned symbols
// are immediates, so identity (a == b) already decides them.
pub fn eqv(a: Value, b: Value) bool {
    if (a == b) return true;
    if (value_mod.isPtr(a) and value_mod.isPtr(b)) {
        if (objects.isFloat(a) and objects.isFloat(b)) {
            return @as(u64, @bitCast(objects.floatVal(a))) == @as(u64, @bitCast(objects.floatVal(b)));
        }
        // zepo-nfak: two distinct bignum objects of equal value are eqv?.
        if (objects.isBignum(a) and objects.isBignum(b)) {
            return runtime.bignum.eql(a, b);
        }
    }
    return false;
}

pub fn primEqvQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    return if (eqv(args[0], args[1])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primEqualQ(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    var visited = std.AutoHashMap([2]usize, void).init(vm.allocator);
    defer visited.deinit();
    const eq = structuralEqual(vm, args[0], args[1], &visited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return if (eq) value_mod.TRUE else value_mod.FALSE;
}

pub fn structuralEqual(vm: *VM, a: Value, b: Value, visited: *std.AutoHashMap([2]usize, void)) error{OutOfMemory}!bool {
    if (a == b) return true;
    // zepo-rddw: equal? on numbers reduces to eqv? — exactness-aware, NOT f64
    // promotion, so (equal? 1 1.0) is #f and equal? agrees with the hasher.
    if (objects.isNumber(a) and objects.isNumber(b)) {
        return eqv(a, b);
    }
    if (!value_mod.isPtr(a) or !value_mod.isPtr(b)) return false;

    if (objects.isPair(a) and objects.isPair(b)) {
        // Cycle detection: if we've already recursed into (a, b), treat them
        // as equal (co-inductive interpretation). Prevents infinite recursion
        // on cyclic lists.
        const key = [2]usize{ @intFromPtr(value_mod.ptrVal(a)), @intFromPtr(value_mod.ptrVal(b)) };
        if (visited.contains(key)) return true;
        try visited.put(key, {});
        return (try structuralEqual(vm, objects.pairCar(a).*, objects.pairCar(b).*, visited)) and
            (try structuralEqual(vm, objects.pairCdr(a).*, objects.pairCdr(b).*, visited));
    }
    if (objects.isString(a) and objects.isString(b)) {
        return std.mem.eql(u8, objects.stringBytes(a), objects.stringBytes(b));
    }
    if (objects.isSymbol(a) and objects.isSymbol(b)) {
        // Interned → identity already matches above; fall back to name.
        return std.mem.eql(u8, objects.symbolName(a), objects.symbolName(b));
    }
    // zepo-aqwc: equal? recurses into vectors (same length + elementwise equal?),
    // now that #(...) literals make vectors easy to compare. Same co-inductive
    // cycle handling as pairs — vector-set! can make a vector self-referential.
    if (objects.isVector(a) and objects.isVector(b)) {
        const len = objects.vectorLen(a);
        if (len != objects.vectorLen(b)) return false;
        const key = [2]usize{ @intFromPtr(value_mod.ptrVal(a)), @intFromPtr(value_mod.ptrVal(b)) };
        if (visited.contains(key)) return true;
        try visited.put(key, {});
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (!try structuralEqual(vm, objects.vectorGet(a, i), objects.vectorGet(b, i), visited)) return false;
        }
        return true;
    }
    return false;
}
