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

test "module: (import M) auto-aliases the full module path as a namespace" {
    // zepo-cnj4: every default import gets a free namespace alias bound to
    // the module's FULL path (`math/tensor` not just `tensor`), so qualified
    // access works without an explicit :as. The full path is used so the
    // alias never collides with an exported short name.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module mp/sub (export x) (define x 99))
    );
    _ = try rig.eval("(import mp/sub)");
    const x = try rig.eval("mp/sub.x");
    try expectInt(x, 99);
}

test "module: (import M (a b)) is sugar for (import M (only a b))" {
    // zepo-ug3: a bare name-list after the module is equivalent to (only ...).
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module mug (export a b c) (define a 10) (define b 20) (define c 30))
    );
    _ = try rig.eval("(import mug (a c))");
    const a = try rig.eval("a");
    try expectInt(a, 10);
    const c = try rig.eval("c");
    try expectInt(c, 30);
    const b = rig.eval("b");
    try std.testing.expectError(error.UnboundVariable, b);
}

test "module: :as binds alias to a namespace; alias.name resolves the export" {
    // zepo-aqm: (import M :as A) makes A a namespace value; A.x is a qualified
    // reference resolved through it. Both ':as' and bare 'as' accepted.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module mq (export x y) (define x 7) (define y 11))
    );
    _ = try rig.eval("(import mq :as q)");
    const x = try rig.eval("q.x");
    try expectInt(x, 7);
    const y = try rig.eval("q.y");
    try expectInt(y, 11);
}

test "module: two modules with same export name disambiguated via :as" {
    // zepo-aqm: the headline case. tensor:transpose and linear:transpose
    // coexist without collision.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module tn (export transpose) (define (transpose v) (list 'tn v)))
    );
    _ = try rig.eval(
        \\(module ln (export transpose) (define (transpose m) (list 'ln m)))
    );
    _ = try rig.eval("(import tn :as t)");
    _ = try rig.eval("(import ln :as l)");
    const tv = try rig.eval("(t.transpose 'A)");
    try std.testing.expect(!(tv == 0));
    const lv = try rig.eval("(l.transpose 'M)");
    try std.testing.expect(!(lv == 0));
}

test "module: alias.missing-name errors as UnboundVariable" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module mq2 (export a) (define a 1))
    );
    _ = try rig.eval("(import mq2 :as q)");
    const r = rig.eval("q.bogus");
    try std.testing.expectError(error.UnboundVariable, r);
}

test "module: imports are non-transitive — N's exports do not leak through M" {
    // zepo-zc0: when M (import N), importers of M see only M's declared
    // exports, never N's. Regression for the math/stats -> math/linear
    // transpose collision (zepo-cu3).
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module inner (export secret) (define secret 99))
    );
    _ = try rig.eval(
        \\(module outer (export pub) (import inner) (define pub (+ secret 1)))
    );
    // outer can use inner's `secret` internally
    const pub_v = try rig.eval("(import outer) pub");
    try expectInt(pub_v, 100);
    // but importing outer must NOT bring `secret` into the importer's scope
    const leaked = rig.eval("secret");
    try std.testing.expectError(error.UnboundVariable, leaked);
}

test "module: :keyword metadata is parsed and ignored at eval time" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    const v = try rig.eval(
        \\(module math
        \\  :version "1.0.0"
        \\  :docstring "arithmetic helpers"
        \\  :author "leslie"
        \\  (export square)
        \\  (define (square x) (* x x)))
    );
    _ = v;
    const r = try rig.eval("(import math) (square 9)");
    try expectInt(r, 81);
}

test "lib: container registers in module registry and is importable" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(lib mylib
        \\  :version "0.1.0"
        \\  :docstring "test lib"
        \\  (export add1)
        \\  (define (add1 x) (+ x 1)))
    );
    const v = try rig.eval("(import mylib) (add1 41)");
    try expectInt(v, 42);
}

test "lib: :keyword metadata does not interfere with body" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(lib utils
        \\  :version "2.0.0"
        \\  :author "test"
        \\  :license "MIT"
        \\  :depends (a b)
        \\  (export double)
        \\  (define (double x) (* x 2)))
    );
    const v = try rig.eval("(import utils) (double 21)");
    try expectInt(v, 42);
}

test "package: container registers in module registry" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(package mypkg
        \\  :version "0.1.0"
        \\  :docstring "a package")
    );
    // package should be registered
    const m = rig.ctx.registry.get("mypkg");
    try std.testing.expect(m != null);
}

test "package: body forms execute in package environment" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(package tools
        \\  :version "1.0.0"
        \\  (define pi 3))
    );
    _ = try rig.eval("(import tools)");
    const v = try rig.eval("pi");
    try expectInt(v, 3);
}

test "import: :modules keyword form loads module by name" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module math :version "1.0" (export square) (define (square x) (* x x)))
    );
    _ = try rig.eval("(import :modules (math))");
    const v = try rig.eval("(square 6)");
    try expectInt(v, 36);
}

test "import: mixed keyword form loads from multiple tiers" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(module modA (export a) (define a 1))");
    _ = try rig.eval("(lib  libB  (export b) (define b 2))");
    _ = try rig.eval("(import :modules (modA) :libs (libB))");
    const va = try rig.eval("a");
    const vb = try rig.eval("b");
    try expectInt(va, 1);
    try expectInt(vb, 2);
}
