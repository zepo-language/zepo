//! FFI accessor primitives: unwrap a foreign handle's payload into a native
//! Zepo value. Each accessor type-checks the handle's tag before reading.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

const errors = @import("../runtime/errors.zig");
const LispError = errors.LispError;

const tags = @import("tags.zig");
const zig_ffi = @import("zig_ffi.zig");

fn requireForeign(v: Value, expected_tag: u64) LispError!u64 {
    if (!objects.isForeign(v)) return error.TypeError;
    if (objects.foreignTypeTag(v) != expected_tag) return error.TypeError;
    return objects.foreignPayloadRaw(v);
}

pub fn primFfiInt(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const bits = try requireForeign(args[0], tags.I64);
    const n: i64 = @bitCast(bits);
    // zepo-9usm: an i64 from FFI can exceed the fixnum range; promote it to a
    // float (as json marshalling and arithmetic overflow do) rather than
    // erroring or silently wrapping.
    if (!value_mod.fixnumFits(n)) {
        return objects.makeFloat(vm.gc, @floatFromInt(n)) catch return error.OutOfMemory;
    }
    return value_mod.fixnum(@intCast(n));
}

pub fn primFfiFloat(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const bits = try requireForeign(args[0], tags.F64);
    const f: f64 = @bitCast(bits);
    return objects.makeFloat(vm.gc, f) catch return error.OutOfMemory;
}

pub fn primFfiBool(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const bits = try requireForeign(args[0], tags.BOOL);
    return if (bits != 0) value_mod.TRUE else value_mod.FALSE;
}

pub fn primFfiString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const bits = try requireForeign(args[0], tags.STRING);
    const payload: *zig_ffi.StringPayload = @ptrFromInt(@as(usize, @intCast(bits)));
    return objects.makeString(vm.gc, payload.bytes) catch return error.OutOfMemory;
}

pub fn primFfiToLisp(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isForeign(args[0])) return error.TypeError;
    const tag = objects.foreignTypeTag(args[0]);
    return switch (tag) {
        tags.VOID => value_mod.NIL,
        tags.I64 => primFfiInt(vm, args),
        tags.F64 => primFfiFloat(vm, args),
        tags.BOOL => primFfiBool(vm, args),
        tags.STRING => primFfiString(vm, args),
        else => error.TypeError,
    };
}
