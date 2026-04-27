//! Comptime Zig-to-Zepo FFI generator.
//!
//! `expose(Module, cfg)` reads the Zig `@typeInfo` of each named declaration
//! in `cfg` and emits Zepo primitive wrappers. The returned type exposes
//! `register` (into globals) and `registerIntoModule` (into a Module).
//!
//! Phase-3 scope: primitive Zig types as params/returns — ints, floats,
//! bool, []const u8. Error unions surface as (err <kind-symbol> <message>)
//! result objects. Complex types and opaque handles land in Phase 4.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;
const GlobalEnv = runtime.GlobalEnv;

const module_mod = @import("../runtime/module.zig");
const Module = module_mod.Module;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const PrimFn = vm_mod.PrimFn;

const errors = @import("../runtime/errors.zig");
const LispError = errors.LispError;

pub const tags = @import("tags.zig");

/// Heap payload for FFI string handles — an owned byte slice plus an
/// allocator handle so the finalizer can free both the bytes and self.
pub const StringPayload = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(opaque_self: ?*anyopaque) callconv(.c) void {
        const self: *StringPayload = @ptrCast(@alignCast(opaque_self.?));
        const a = self.allocator;
        a.free(self.bytes);
        a.destroy(self);
    }
};

pub const ReturnLifetime = enum { copy, owned, borrow_until_next_call };

pub const FnConfig = struct {
    return_lifetime: ReturnLifetime = .copy,
};

pub const Binding = struct {
    name: []const u8,
    prim_fn: PrimFn,
    arity: i64,
};

/// Build a wrapper type that registers a set of Zig functions as Zepo prims.
/// `cfg` is a struct literal keyed by the target fn name; each value is an
/// `FnConfig` (or a bare `.{}` for defaults).
pub fn expose(comptime Mod: type, comptime cfg: anytype) type {
    const CfgT = @TypeOf(cfg);
    const cfg_fields = std.meta.fields(CfgT);
    comptime var bindings_buf: [cfg_fields.len]Binding = undefined;
    comptime {
        for (cfg_fields, 0..) |cf, i| {
            const target = @field(Mod, cf.name);
            const TargetT = @TypeOf(target);
            const ti = @typeInfo(TargetT);
            if (ti != .@"fn") @compileError("FFI: " ++ cf.name ++ " is not a function");
            const fn_info = ti.@"fn";
            bindings_buf[i] = .{
                .name = cf.name,
                .prim_fn = makeWrapper(target),
                .arity = @intCast(fn_info.params.len),
            };
        }
    }
    const final = bindings_buf;
    return struct {
        pub const all: []const Binding = &final;

        /// Register each binding as a top-level global.
        pub fn register(gc: *GC, globals: *GlobalEnv, symbols: *SymbolTable) !void {
            inline for (final) |b| {
                const sym = try symbols.intern(b.name);
                const raw_ptr: u64 = @intCast(@intFromPtr(b.prim_fn));
                const prim = try objects.makePrim(gc, raw_ptr, b.arity);
                try globals.define(sym, prim);
            }
        }

        /// Register each binding into the given module's env and mark exported.
        pub fn registerIntoModule(gc: *GC, symbols: *SymbolTable, mod: *Module) !void {
            inline for (final) |b| {
                const sym = try symbols.intern(b.name);
                const raw_ptr: u64 = @intCast(@intFromPtr(b.prim_fn));
                const prim = try objects.makePrim(gc, raw_ptr, b.arity);
                try mod.env.define(sym, prim);
                try mod.markExport(b.name);
            }
        }
    };
}

fn makeWrapper(comptime target: anytype) PrimFn {
    const TargetT = @TypeOf(target);
    const fn_info = @typeInfo(TargetT).@"fn";
    return struct {
        fn call(vm: *VM, args: []const Value) LispError!Value {
            if (args.len != fn_info.params.len) return error.ArityMismatch;

            const ArgsTuple = std.meta.ArgsTuple(TargetT);
            var tuple: ArgsTuple = undefined;
            inline for (fn_info.params, 0..) |p, i| {
                const PT = p.type.?;
                @field(tuple, std.fmt.comptimePrint("{d}", .{i})) = try unmarshal(PT, args[i]);
            }

            const RetT = fn_info.return_type.?;
            const ret_info = @typeInfo(RetT);
            switch (ret_info) {
                .error_union => {
                    const result = @call(.auto, target, tuple) catch |e| {
                        return marshalErr(vm, e);
                    };
                    return marshal(vm, result);
                },
                else => {
                    const result = @call(.auto, target, tuple);
                    return marshal(vm, result);
                },
            }
        }
    }.call;
}

fn unmarshal(comptime T: type, v: Value) LispError!T {
    if (T == bool) {
        if (v == value_mod.TRUE) return true;
        if (v == value_mod.FALSE) return false;
        return error.TypeError;
    }
    if (T == []const u8) {
        if (!objects.isString(v)) return error.TypeError;
        return objects.stringBytes(v);
    }
    switch (@typeInfo(T)) {
        .int => {
            if (!value_mod.isFixnum(v)) return error.TypeError;
            const n: i63 = value_mod.fixnumVal(v);
            return @intCast(n);
        },
        .float => {
            if (value_mod.isFixnum(v)) return @floatFromInt(value_mod.fixnumVal(v));
            if (!objects.isFloat(v)) return error.TypeError;
            return @floatCast(objects.floatVal(v));
        },
        else => @compileError("FFI unmarshal: unsupported type " ++ @typeName(T)),
    }
}

fn marshal(vm: *VM, x: anytype) LispError!Value {
    const T = @TypeOf(x);
    if (T == void) {
        return objects.makeForeignRaw(vm.gc, 0, null, tags.VOID) catch return error.OutOfMemory;
    }
    if (T == bool) {
        const bits: u64 = if (x) 1 else 0;
        return objects.makeForeignRaw(vm.gc, bits, null, tags.BOOL) catch return error.OutOfMemory;
    }
    if (T == []const u8) {
        const a = vm.gc.allocator;
        const payload = a.create(StringPayload) catch return error.OutOfMemory;
        errdefer a.destroy(payload);
        const bytes_copy = a.dupe(u8, x) catch return error.OutOfMemory;
        payload.* = .{ .allocator = a, .bytes = bytes_copy };
        return objects.makeForeignRaw(
            vm.gc,
            @intFromPtr(payload),
            &StringPayload.deinit,
            tags.STRING,
        ) catch {
            a.free(bytes_copy);
            a.destroy(payload);
            return error.OutOfMemory;
        };
    }
    switch (@typeInfo(T)) {
        .int => {
            const n: i64 = @intCast(x);
            const bits: u64 = @bitCast(n);
            return objects.makeForeignRaw(vm.gc, bits, null, tags.I64) catch return error.OutOfMemory;
        },
        .float => {
            const f: f64 = @floatCast(x);
            const bits: u64 = @bitCast(f);
            return objects.makeForeignRaw(vm.gc, bits, null, tags.F64) catch return error.OutOfMemory;
        },
        else => @compileError("FFI marshal: unsupported type " ++ @typeName(T)),
    }
}

/// Build (err <kind-symbol> <message-string>) from a Zig error.
fn marshalErr(vm: *VM, e: anyerror) LispError!Value {
    const err_tag = try vm.symbols.intern("err");
    const kind_sym = try vm.symbols.intern(@errorName(e));
    const msg = objects.makeString(vm.gc, @errorName(e)) catch return error.OutOfMemory;
    const inner2 = objects.makePair(vm.gc, msg, value_mod.NIL) catch return error.OutOfMemory;
    const inner1 = objects.makePair(vm.gc, kind_sym, inner2) catch return error.OutOfMemory;
    return objects.makePair(vm.gc, err_tag, inner1) catch return error.OutOfMemory;
}
