//! Module system — error path tests.

const std = @import("std");
const zepo = @import("zepo");

const abi = zepo.abi;
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

test "ModuleNotFound: import of unknown module" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(error.ModuleNotFound, rig.eval("(import nope)"));
}

test "ImportNameNotExported: (only ...) a non-exported name" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(module m (export a) (define a 1) (define b 2))
    );
    try std.testing.expectError(error.ImportNameNotExported, rig.eval(
        \\(import m (only b))
    ));
}

test "ExportNotDefined: exported name never bound in body" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(error.ExportNotDefined, rig.eval(
        \\(module m (export x) (define y 1))
    ));
}

test "ModuleAlreadyDefined: redefining a module errors" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(module m (export x) (define x 1))
    );
    try std.testing.expectError(error.ModuleAlreadyDefined, rig.eval(
        \\(module m (export x) (define x 2))
    ));
}

test "ModuleNotFound: import before module is defined in source" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // m is not in the registry when (import m) runs — ModuleNotFound, not ImportBeforeInitialization
    try std.testing.expectError(error.ModuleNotFound, rig.eval(
        \\(import m)
        \\(module m (export x) (define x 1))
    ));
}

test "ImportBeforeInitialization: module imports itself (circular)" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // zepo-ejo: module is in registry (initialized=false) when its own body tries to import it
    try std.testing.expectError(error.ImportBeforeInitialization, rig.eval(
        \\(module a (export x) (import a) (define x 1))
    ));
}

test "ModuleNotAtTopLevel: nested module inside lambda body" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(error.ModuleNotAtTopLevel, rig.eval(
        \\(define (f) (module m (export x) (define x 1)))
    ));
}

test "import inside lambda body compiles to IMPORT opcode and runs at call time" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(module m (export x) (define x 1))
    );
    _ = try rig.eval(
        \\(define (f) (import m (x)) x)
    );
    const result = try rig.eval("(f)");
    try std.testing.expect(result != 0);
}

test "ExportOutsideModule: export at top level" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(error.ExportOutsideModule, rig.eval(
        \\(export foo)
    ));
}

test "bare import binds exports unqualified; overlapping names conflict" {
    // zepo-hior: bare (import M) flat-binds M's EXPORTED names into the
    // importer's unqualified scope (a lazy-prototyping convenience). So
    // (import a) binds `x`=1 unqualified; a following (import b) that also
    // exports `x` collides and raises ImportNameConflict — same rule the
    // selective form enforces. Each import still also binds its namespace
    // alias (a.x, b.x) for qualified access.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(module a (export x) (define x 1))
    );
    _ = try rig.eval(
        \\(module b (export x) (define x 2))
    );
    _ = try rig.eval("(import a)");
    // Bare import bound `x` unqualified from module a.
    const x = try rig.eval("x");
    try std.testing.expect(x != 0);
    // Namespace alias still works.
    const ax = try rig.eval("a.x");
    try std.testing.expect(ax != 0);
    // Second bare import of an overlapping export collides.
    try std.testing.expectError(error.ImportNameConflict, rig.eval("(import b)"));
}

test "bare import of non-overlapping modules binds both unqualified" {
    // zepo-hior: distinct export names from two bare imports coexist.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(module a (export ax) (define ax 1))
    );
    _ = try rig.eval(
        \\(module b (export bx) (define bx 2))
    );
    _ = try rig.eval("(import a)");
    _ = try rig.eval("(import b)");
    try std.testing.expect((try rig.eval("ax")) != 0);
    try std.testing.expect((try rig.eval("bx")) != 0);
}
