//! Module system — happy-path tests.

const std = @import("std");
const zepo = @import("zepo");

const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;

const Rig = struct {
    gc: zepo.GC,
    syms: runtime.SymbolTable,
    globals: runtime.GlobalEnv,
    ctx: runtime.EvalContext,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !*Rig {
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

    fn deinit(r: *Rig) void {
        const a = r.allocator;
        r.ctx.deinit();
        r.globals.deinit();
        r.syms.deinit();
        r.gc.deinit();
        a.destroy(r);
    }

    fn eval(r: *Rig, src: []const u8) !abi.Value {
        return r.ctx.evalString(src, "<test>");
    }
};

fn expectInt(v: abi.Value, n: i63) !void {
    if (!value_mod.isFixnum(v)) return error.TestExpectedFixnum;
    try std.testing.expectEqual(n, value_mod.fixnumVal(v));
}

test "module: define and import single value" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module m (export x) (define x 42))
    );
    const v = try rig.eval(
        \\(import m) x
    );
    try expectInt(v, 42);
}

test "module: import with (only ...) selection" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module m (export a b) (define a 1) (define b 2))
    );
    const v = try rig.eval(
        \\(import m (only a)) a
    );
    try expectInt(v, 1);
}

test "module: exported function callable" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module math (export square) (define (square x) (* x x)))
    );
    const v = try rig.eval(
        \\(import math) (square 7)
    );
    try expectInt(v, 49);
}

test "module: slot aliasing — set! in defining module visible to importer" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module m (export x bump) (define x 10) (define (bump) (set! x (+ x 1))))
    );
    _ = try rig.eval(
        \\(import m)
    );
    _ = try rig.eval("(bump)");
    _ = try rig.eval("(bump)");
    const v = try rig.eval("x");
    try expectInt(v, 12);
}

test "module: two modules cross-import" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module math (export square) (define (square x) (* x x)))
    );
    _ = try rig.eval(
        \\(module geom (export area-square) (import math) (define (area-square s) (square s)))
    );
    const v = try rig.eval(
        \\(import geom) (area-square 6)
    );
    try expectInt(v, 36);
}

test "module: selective import does not import unlisted names" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module m (export a b) (define a 1) (define b 2))
    );
    _ = try rig.eval(
        \\(import m (only a))
    );
    const v = rig.eval("b");
    try std.testing.expectError(error.UnboundVariable, v);
}
