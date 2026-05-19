//! Shared rig + assertion helpers for conformance tests.

const std = @import("std");
const zepo = @import("zepo");

pub const abi = zepo.abi;
pub const value_mod = abi.value;
pub const Value = abi.Value;
pub const runtime = zepo.runtime;
pub const objects = runtime.objects;

pub const Rig = struct {
    gpa_state: std.heap.DebugAllocator(.{}) = .{},
    gc: zepo.GC,
    syms: runtime.SymbolTable,
    globals: runtime.GlobalEnv,
    ctx: runtime.EvalContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Rig {
        const r = try allocator.create(Rig);
        errdefer allocator.destroy(r);
        r.allocator = allocator;
        r.gc = try zepo.GC.init(allocator);
        errdefer r.gc.deinit();
        r.syms = try runtime.SymbolTable.init(&r.gc, allocator);
        errdefer r.syms.deinit();
        r.globals = try runtime.GlobalEnv.init(&r.gc, allocator);
        errdefer r.globals.deinit();
        try zepo.prims.registerAll(&r.gc, &r.globals, &r.syms);
        r.ctx = try runtime.EvalContext.init(&r.gc, &r.syms, &r.globals, allocator);
        return r;
    }

    pub fn initWithPrelude(allocator: std.mem.Allocator) !*Rig {
        const r = try Rig.init(allocator);
        errdefer r.deinit();
        try runtime.loadStdlib(&r.ctx);
        return r;
    }

    pub fn deinit(r: *Rig) void {
        const a = r.allocator;
        r.ctx.deinit();
        r.globals.deinit();
        r.syms.deinit();
        r.gc.deinit();
        a.destroy(r);
    }

    pub fn eval(r: *Rig, src: []const u8) !Value {
        return r.ctx.evalString(src, "<test>");
    }
};

pub fn expectInt(v: Value, n: i63) !void {
    if (!value_mod.isFixnum(v)) return error.TestExpectedFixnum;
    try std.testing.expectEqual(n, value_mod.fixnumVal(v));
}

pub fn expectTrue(v: Value) !void {
    try std.testing.expectEqual(value_mod.TRUE, v);
}

pub fn expectFalse(v: Value) !void {
    try std.testing.expectEqual(value_mod.FALSE, v);
}

pub fn expectNil(v: Value) !void {
    try std.testing.expectEqual(value_mod.NIL, v);
}

pub fn expectFloat(v: Value, expected: f64, tol: f64) !void {
    if (!objects.isFloat(v)) return error.TestExpectedFloat;
    try std.testing.expectApproxEqAbs(expected, objects.floatVal(v), tol);
}

pub fn expectString(v: Value, expected: []const u8) !void {
    if (!objects.isString(v)) return error.TestExpectedString;
    try std.testing.expectEqualStrings(expected, objects.stringBytes(v));
}
