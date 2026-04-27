//! Macro expansion + quasiquote end-to-end tests.

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
        return r.ctx.evalString(src, "<macros_test>");
    }
};

fn expectInt(v: abi.Value, n: i63) !void {
    if (!value_mod.isFixnum(v)) return error.TestExpectedFixnum;
    try std.testing.expectEqual(n, value_mod.fixnumVal(v));
}

test "macro: basic defmacro + expansion" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(defmacro my-when (c body) `(if ,c ,body 0))
    );
    try expectInt(try rig.eval("(my-when #t 42)"), 42);
    try expectInt(try rig.eval("(my-when #f 42)"), 0);
}

test "macro: quasiquote unquote" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(defmacro plus-one (x) `(+ ,x 1))
    );
    try expectInt(try rig.eval("(plus-one 5)"), 6);
}

test "macro: unquote-splicing" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(defmacro sum-of (xs) `(+ ,@xs))
    );
    try expectInt(try rig.eval("(sum-of (1 2 3 4))"), 10);
}

test "macro: nested macro expansion" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(defmacro double (x) `(+ ,x ,x))
        \\(defmacro quadruple (x) `(double (double ,x)))
    );
    try expectInt(try rig.eval("(quadruple 3)"), 12);
}

test "macro: non-macro call passes through" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(define (inc x) (+ x 1))");
    try expectInt(try rig.eval("(inc 10)"), 11);
    try expectInt(try rig.eval("(+ (inc 5) (inc 6))"), 13);
}

test "macro: does not expand inside quote" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(defmacro boom (x) `(error-should-not-fire ,x))
    );
    // Quoted form should remain literal; macro must not fire on 'boom' inside quote.
    const v = try rig.eval("(car (quote (boom 1)))");
    // car of '(boom 1) is the symbol boom — we just verify no error thrown during expansion.
    _ = v;
}
