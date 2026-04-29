//! FFI phase-5 test: std.json binding via zepo. Validates parse + stringify
//! round-trip and error-result shape.

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
        return r.ctx.evalString(src, "<json_test>");
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

test "json: parse integer returns ok + fixnum" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define r (json-parse \"42\"))");
    try expectTrue(try rig.eval("(ok? r)"));
    try expectInt(try rig.eval("(result-value r)"), 42);
}

test "json: parse bool + null" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectTrue(try rig.eval("(result-value (json-parse \"true\"))"));
    try expectFalse(try rig.eval("(result-value (json-parse \"false\"))"));
    // null → 'null symbol, recognized by json-null?
    try expectTrue(try rig.eval("(json-null? (result-value (json-parse \"null\")))"));
}

test "json: parse string" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    const s = try rig.eval("(result-value (json-parse \"\\\"hello\\\"\"))");
    try std.testing.expect(objects.isString(s));
    try std.testing.expectEqualStrings("hello", objects.stringBytes(s));
}

test "json: parse array yields vector" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define arr (result-value (json-parse \"[10,20,30]\")))");
    try expectInt(try rig.eval("(vector-length arr)"), 3);
    try expectInt(try rig.eval("(vector-ref arr 0)"), 10);
    try expectInt(try rig.eval("(vector-ref arr 2)"), 30);
}

test "json: parse object yields hash table" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define obj (result-value (json-parse \"{\\\"a\\\":1,\\\"b\\\":2}\")))");
    try expectTrue(try rig.eval("(hash-table? obj)"));
    try expectInt(try rig.eval("(hash-get obj \"a\")"), 1);
    try expectInt(try rig.eval("(hash-get obj \"b\")"), 2);
}

test "json: parse error returns err result" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define r (json-parse \"{ not json }\"))");
    try expectTrue(try rig.eval("(err? r)"));
    const kind = try rig.eval("(err-kind r)");
    try std.testing.expect(objects.isSymbol(kind));
}

test "json: stringify round-trips primitives" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    const s42 = try rig.eval("(result-value (json-stringify 42))");
    try std.testing.expectEqualStrings("42", objects.stringBytes(s42));
    const strue = try rig.eval("(result-value (json-stringify #t))");
    try std.testing.expectEqualStrings("true", objects.stringBytes(strue));
    const snull = try rig.eval("(result-value (json-stringify (quote null)))");
    try std.testing.expectEqualStrings("null", objects.stringBytes(snull));
    const sstr = try rig.eval("(result-value (json-stringify \"hi\"))");
    try std.testing.expectEqualStrings("\"hi\"", objects.stringBytes(sstr));
}

test "json: parse then stringify round-trips an object" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define obj (result-value (json-parse \"{\\\"a\\\":1,\\\"b\\\":2}\")))");
    const s = try rig.eval("(result-value (json-stringify obj))");
    // Accept either key order — verify it parses back equivalently.
    _ = try rig.eval("(define r2 (result-value (json-parse (result-value (json-stringify obj)))))");
    try expectInt(try rig.eval("(hash-get r2 \"a\")"), 1);
    try expectInt(try rig.eval("(hash-get r2 \"b\")"), 2);
    _ = s;
}
