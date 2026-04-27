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
    // Numbers: compare int/float with promotion.
    if (objects.isNumber(a) and objects.isNumber(b)) {
        const af = toFloat(a);
        const bf = toFloat(b);
        return af == bf;
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
    return false;
}

fn toFloat(v: Value) f64 {
    if (value_mod.isFixnum(v)) return @floatFromInt(value_mod.fixnumVal(v));
    return objects.floatVal(v);
}
