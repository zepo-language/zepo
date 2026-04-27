//! Stdlib result-object convention tests (ok / err / ok? / err? / accessors).

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
        errdefer r.ctx.deinit();
        try runtime.loadStdlib(&r.ctx);
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
        return r.ctx.evalString(src, "<result_test>");
    }
};

fn expectInt(v: abi.Value, n: i63) !void {
    if (!value_mod.isFixnum(v)) return error.TestExpectedFixnum;
    try std.testing.expectEqual(n, value_mod.fixnumVal(v));
}

fn expectTrue(v: abi.Value) !void {
    try std.testing.expectEqual(value_mod.TRUE, v);
}

fn expectFalse(v: abi.Value) !void {
    try std.testing.expectEqual(value_mod.FALSE, v);
}

test "result: ok? recognizes ok values" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectTrue(try rig.eval("(ok? (ok 42))"));
    try expectFalse(try rig.eval("(err? (ok 42))"));
}

test "result: err? recognizes err values" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectTrue(try rig.eval("(err? (err (quote bad-arg) \"boom\"))"));
    try expectFalse(try rig.eval("(ok? (err (quote bad-arg) \"boom\"))"));
}

test "result: result-value unwraps ok" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(result-value (ok 123))"), 123);
}

test "result: err-kind + err-message accessors" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(define e (err (quote type-mismatch) \"expected int\"))");

    const kind = try rig.eval("(err-kind e)");
    try std.testing.expect(objects.isSymbol(kind));
    try std.testing.expectEqualStrings("type-mismatch", objects.symbolName(kind));

    const msg = try rig.eval("(err-message e)");
    try std.testing.expect(objects.isString(msg));
    try std.testing.expectEqualStrings("expected int", objects.stringBytes(msg));
}

test "result: predicates reject non-result values" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectFalse(try rig.eval("(ok? 5)"));
    try expectFalse(try rig.eval("(err? (quote ok))"));
    try expectFalse(try rig.eval("(ok? (list 1 2))"));
}
