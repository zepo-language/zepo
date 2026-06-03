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
        \\(import m) m.x
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
        \\(import math) (math.square 7)
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
        \\(import m (x bump))
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
        \\(module geom (export area-square) (import math (square)) (define (area-square s) (square s)))
    );
    const v = try rig.eval(
        \\(import geom) (geom.area-square 6)
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

test "module: macro hygiene — defmacro body refs its module's internals via qualified path" {
    // zepo-we7e: a macro defined inside a module that references a private
    // helper (a `define` that is NOT in the module's `export` list) still
    // works when expanded from outside the module — the body gets rewritten
    // at defmacro time so the helper is reached via `home/path.name`, which
    // the auto-bound namespace alias (zepo-cnj4) resolves to the home env.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module mhyg (export mac)
        \\  (define helper-counter 0)
        \\  (define (private-helper) (set! helper-counter (+ helper-counter 1)) helper-counter)
        \\  (defmacro mac () `(private-helper)))
    );
    _ = try rig.eval("(import mhyg (mac))");
    // helper-counter and private-helper are NOT exported, so they must not
    // be visible in the importer's unqualified scope:
    const leak1 = rig.eval("private-helper");
    try std.testing.expectError(error.UnboundVariable, leak1);
    // But the macro expansion still works — the (private-helper) reference
    // inside the macro body was rewritten at defmacro time to its qualified
    // form (mhyg.private-helper).
    const v1 = try rig.eval("(mac)");
    try expectInt(v1, 1);
    const v2 = try rig.eval("(mac)");
    try expectInt(v2, 2);
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

test "module: zepo-l7bk — name collision across imports errors as ImportNameConflict" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(module ca (export x) (define x 1))");
    _ = try rig.eval("(module cb (export x) (define x 2))");
    _ = try rig.eval("(import ca (x))");
    const r = rig.eval("(import cb (x))");
    try std.testing.expectError(error.ImportNameConflict, r);
    // The workaround (alias one side) succeeds and both bindings are reachable.
    _ = try rig.eval("(import cb :as cbb)");
    const ax = try rig.eval("x");
    const bx = try rig.eval("cbb.x");
    try expectInt(ax, 1);
    try expectInt(bx, 2);
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
        \\(module outer (export pub) (import inner (secret)) (define pub (+ secret 1)))
    );
    // outer can use inner's `secret` internally
    const pub_v = try rig.eval("(import outer) outer.pub");
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
    const r = try rig.eval("(import math) (math.square 9)");
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
    const v = try rig.eval("(import mylib) (mylib.add1 41)");
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
    const v = try rig.eval("(import utils) (utils.double 21)");
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
    const v = try rig.eval("tools.pi");
    try expectInt(v, 3);
}

test "import: :modules keyword form loads module by name" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval(
        \\(module math :version "1.0" (export square) (define (square x) (* x x)))
    );
    _ = try rig.eval("(import :modules (math))");
    const v = try rig.eval("(math.square 6)");
    try expectInt(v, 36);
}

test "import: mixed keyword form loads from multiple tiers" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(module modA (export a) (define a 1))");
    _ = try rig.eval("(lib  libB  (export b) (define b 2))");
    _ = try rig.eval("(import :modules (modA) :libs (libB))");
    const va = try rig.eval("modA.a");
    const vb = try rig.eval("libB.b");
    try expectInt(va, 1);
    try expectInt(vb, 2);
}

// zepo-1rbq: keyword-form import accepts selective sublist
test "import :libs selective sublist — only listed name leaks unqualified" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(lib mq (export a b) (define a 10) (define b 20))");
    _ = try rig.eval("(import :libs (mq (a)))");
    const va = try rig.eval("a");
    try expectInt(va, 10);

    // `b` should NOT be unqualified — looking it up should error.
    const b_res = rig.eval("b");
    try std.testing.expectError(error.UnboundVariable, b_res);
}

test "import :libs mixed — full module plus selective module" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(lib mq1 (export x y) (define x 1) (define y 2))");
    _ = try rig.eval("(lib mq2 (export c d) (define c 30) (define d 40))");
    _ = try rig.eval("(import :libs (mq1 mq2 (c)))");

    // mq1: bare, only namespace alias bound (post-y1a4); access via mq1.x
    const vx = try rig.eval("mq1.x");
    const vy = try rig.eval("mq1.y");
    const vc = try rig.eval("c"); // mq2: selective, c is unqualified
    try expectInt(vx, 1);
    try expectInt(vy, 2);
    try expectInt(vc, 30);

    // mq2's `d` should not be unqualified.
    try std.testing.expectError(error.UnboundVariable, rig.eval("d"));
}

test "import :libs selective sublist — namespace alias still bound" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    _ = try rig.eval("(lib mq (export a b) (define a 100) (define b 200))");
    _ = try rig.eval("(import :libs (mq (a)))");
    // namespace alias `mq` should still resolve qualified access for `b`.
    const vb = try rig.eval("mq.b");
    try expectInt(vb, 200);
}

// zepo-d5o2: runtime (in-function-body) import must auto-load from the search
// path, exactly like a top-level import. Previously doImportByName skipped
// auto-loading and raised ModuleNotFound for any not-yet-loaded module.
test "module: runtime in-function import auto-loads from search path" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "mathlite.lisp",
        .data = "(module mathlite (export answer) (define answer 42))",
    });

    const saved_fd = std.c.open(".", .{ .DIRECTORY = true }, @as(std.c.mode_t, 0));
    if (saved_fd < 0) return error.OpenCwdFailed;
    defer _ = std.c.close(saved_fd);
    if (std.c.fchdir(tmp.dir.handle) != 0) return error.FchdirFailed;
    defer _ = std.c.fchdir(saved_fd);

    const paths = [_][]const u8{"."};
    rig.ctx.module_path = &paths;

    // mathlite is NOT imported at top level — the import inside the function
    // body must trigger auto-load when get-answer is first called.
    const v = try rig.eval(
        \\(define (get-answer)
        \\  (import mathlite (only answer))
        \\  answer)
        \\(get-answer)
    );
    try expectInt(v, 42);
}
