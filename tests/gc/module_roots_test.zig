//! Module env values must survive GC because their slots are registered
//! via gc.roots.extra (same path as GlobalEnv.define).

const std = @import("std");
const zepo = @import("zepo");

const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;
const objects = runtime.objects;

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

fn listLength(v: abi.Value) usize {
    var n: usize = 0;
    var cur = v;
    while (!value_mod.isNil(cur)) {
        if (!objects.isPair(cur)) break;
        n += 1;
        cur = objects.pairCdr(cur).*;
    }
    return n;
}

test "module: exported cons list survives major GC" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module m (export lst)
        \\  (define lst (cons 1 (cons 2 (cons 3 (cons 4 (cons 5 (quote ()))))))))
    );
    _ = try rig.eval("(import m)");

    try rig.gc.major();

    const v = try rig.eval("lst");
    try std.testing.expectEqual(@as(usize, 5), listLength(v));

    const head = objects.pairCar(v).*;
    try expectInt(head, 1);
}

test "module: mutation of exported binding visible through importer after GC" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module m (export x bump)
        \\  (define x 100)
        \\  (define (bump) (set! x (+ x 1))))
    );
    _ = try rig.eval("(import m)");
    _ = try rig.eval("(bump)");
    try rig.gc.major();
    _ = try rig.eval("(bump)");
    const v = try rig.eval("x");
    try expectInt(v, 102);
}
