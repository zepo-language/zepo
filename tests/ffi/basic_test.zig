//! FFI phase-3/4 end-to-end test: zig_ffi.expose wraps Zig fns so Lisp can
//! call them; every return is an opaque handle that accessors unwrap.

const std = @import("std");
const zepo = @import("zepo");

const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;
const objects = runtime.objects;

// Target Zig module: primitive-typed fns.
const target = struct {
    pub fn add_i(a: i64, b: i64) i64 {
        return a + b;
    }
    pub fn neg_b(x: bool) bool {
        return !x;
    }
    pub fn muladd_f(a: f64, b: f64, c: f64) f64 {
        return a * b + c;
    }
    pub fn strlen_s(s: []const u8) i64 {
        return @intCast(s.len);
    }
    pub fn upper_s(s: []const u8) []const u8 {
        // Allocator-free reverse: just return the same bytes (FFI will copy
        // into an owned StringPayload). Good enough to exercise string-out.
        return s;
    }
    pub fn parse_u32(s: []const u8) !i64 {
        const n = try std.fmt.parseInt(u32, s, 10);
        return @intCast(n);
    }
};

const Bindings = zepo.ffi.expose(target, .{
    .add_i = .{},
    .neg_b = .{},
    .muladd_f = .{},
    .strlen_s = .{},
    .upper_s = .{},
    .parse_u32 = .{},
});

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
        try Bindings.register(&r.gc, &r.globals, &r.syms);
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
        return r.ctx.evalString(src, "<ffi_basic_test>");
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
fn expectFloatApprox(v: abi.Value, expected: f64, tol: f64) !void {
    if (!objects.isFloat(v)) return error.TestExpectedFloat;
    try std.testing.expectApproxEqAbs(expected, objects.floatVal(v), tol);
}

test "ffi: integer accessor unwraps handle" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(ffi-int (add_i 10 32))"), 42);
    try expectInt(try rig.eval("(ffi-int (add_i (ffi-int (add_i 1 2)) 3))"), 6);
}

test "ffi: bool accessor unwraps handle" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectFalse(try rig.eval("(ffi-bool (neg_b #t))"));
    try expectTrue(try rig.eval("(ffi-bool (neg_b #f))"));
}

test "ffi: float accessor unwraps handle" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectFloatApprox(
        try rig.eval("(ffi-float (muladd_f 2.0 3.0 1.0))"),
        7.0,
        1e-9,
    );
}

test "ffi: string accessor unwraps handle" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(ffi-int (strlen_s \"hello\"))"), 5);

    const s = try rig.eval("(ffi-string (upper_s \"abc\"))");
    try std.testing.expect(objects.isString(s));
    try std.testing.expectEqualStrings("abc", objects.stringBytes(s));
}

test "ffi: ffi-to-lisp dispatches on tag" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(ffi-to-lisp (add_i 7 8))"), 15);
    try expectTrue(try rig.eval("(ffi-to-lisp (neg_b #f))"));
    try expectFloatApprox(try rig.eval("(ffi-to-lisp (muladd_f 1.0 1.0 0.5))"), 1.5, 1e-9);
}

test "ffi: accessor rejects wrong-tag handle" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // add_i returns an int handle; ffi-string expects string tag.
    try std.testing.expectError(error.TypeError, rig.eval("(ffi-string (add_i 1 2))"));
}

test "ffi: error union surfaces as err result object" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();

    try expectInt(try rig.eval("(ffi-int (parse_u32 \"1234\"))"), 1234);

    // Failure path returns (err <kind> <msg>) — NOT a handle.
    _ = try rig.eval("(define r (parse_u32 \"nope\"))");
    try expectTrue(try rig.eval("(err? r)"));
    const kind = try rig.eval("(err-kind r)");
    try std.testing.expect(objects.isSymbol(kind));
    try std.testing.expectEqualStrings("InvalidCharacter", objects.symbolName(kind));
}

test "ffi: arity mismatch surfaces" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try std.testing.expectError(error.ArityMismatch, rig.eval("(add_i 1)"));
}
