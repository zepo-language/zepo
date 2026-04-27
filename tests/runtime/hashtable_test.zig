//! First-class hash table tests.

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
        return r.ctx.evalString(src, "<hashtable_test>");
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

test "hash: make + size + predicate" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define h (make-hash-table))");
    try expectTrue(try rig.eval("(hash-table? h)"));
    try expectFalse(try rig.eval("(hash-table? 42)"));
    try expectInt(try rig.eval("(hash-size h)"), 0);
}

test "hash: set! + get + contains?" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define h (make-hash-table))");
    _ = try rig.eval("(hash-set! h \"name\" 123)");
    try expectTrue(try rig.eval("(hash-contains? h \"name\")"));
    try expectInt(try rig.eval("(hash-get h \"name\")"), 123);
    try expectInt(try rig.eval("(hash-size h)"), 1);

    // Update existing key — size unchanged.
    _ = try rig.eval("(hash-set! h \"name\" 456)");
    try expectInt(try rig.eval("(hash-get h \"name\")"), 456);
    try expectInt(try rig.eval("(hash-size h)"), 1);

    try expectFalse(try rig.eval("(hash-contains? h \"missing\")"));
    try expectFalse(try rig.eval("(hash-get h \"missing\")")); // default false
    try expectInt(try rig.eval("(hash-get h \"missing\" 99)"), 99);
}

test "hash: delete!" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define h (make-hash-table))");
    _ = try rig.eval("(hash-set! h \"a\" 1)");
    _ = try rig.eval("(hash-set! h \"b\" 2)");
    try expectTrue(try rig.eval("(hash-delete! h \"a\")"));
    try expectInt(try rig.eval("(hash-size h)"), 1);
    try expectFalse(try rig.eval("(hash-contains? h \"a\")"));
    try expectInt(try rig.eval("(hash-get h \"b\")"), 2);

    // Deleting absent key returns #f.
    try expectFalse(try rig.eval("(hash-delete! h \"missing\")"));
}

test "hash: heterogeneous key types" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define h (make-hash-table))");
    _ = try rig.eval("(hash-set! h 42 \"int-key\")");
    _ = try rig.eval("(hash-set! h (quote foo) \"sym-key\")");
    _ = try rig.eval("(hash-set! h \"s\" \"str-key\")");
    _ = try rig.eval("(hash-set! h #t \"true-key\")");
    try expectInt(try rig.eval("(hash-size h)"), 4);
    try std.testing.expectEqualStrings(
        "int-key",
        objects.stringBytes(try rig.eval("(hash-get h 42)")),
    );
    try std.testing.expectEqualStrings(
        "sym-key",
        objects.stringBytes(try rig.eval("(hash-get h (quote foo))")),
    );
}

test "hash: resize triggers correctly past load factor" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // INITIAL_CAPACITY=8; load factor 0.75 → resize after ~6 inserts.
    // Insert 40 to force multiple resizes.
    _ = try rig.eval(
        \\(define h (make-hash-table))
    );
    _ = try rig.eval(
        \\(define (fill n i)
        \\  (if (= i n)
        \\      n
        \\      (begin (hash-set! h i (* i 10)) (fill n (+ i 1)))))
    );
    _ = try rig.eval("(fill 40 0)");
    try expectInt(try rig.eval("(hash-size h)"), 40);
    try expectInt(try rig.eval("(hash-get h 0)"), 0);
    try expectInt(try rig.eval("(hash-get h 17)"), 170);
    try expectInt(try rig.eval("(hash-get h 39)"), 390);
    try expectFalse(try rig.eval("(hash-contains? h 40)"));
}

test "hash: hash-keys / hash-values return vectors" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define h (make-hash-table))
        \\(hash-set! h "a" 1)
        \\(hash-set! h "b" 2)
        \\(hash-set! h "c" 3)
    );
    try expectInt(try rig.eval("(vector-length (hash-keys h))"), 3);
    try expectInt(try rig.eval("(vector-length (hash-values h))"), 3);
}

test "hash: hash->alist + alist->hash round-trip" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define h1 (make-hash-table))
        \\(hash-set! h1 "a" 1)
        \\(hash-set! h1 "b" 2)
    );
    _ = try rig.eval("(define al (hash->alist h1))");
    _ = try rig.eval("(define h2 (alist->hash al))");
    try expectInt(try rig.eval("(hash-size h2)"), 2);
    try expectInt(try rig.eval("(hash-get h2 \"a\")"), 1);
    try expectInt(try rig.eval("(hash-get h2 \"b\")"), 2);
}

test "hash: hash-for-each visits every entry" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define h (make-hash-table))
        \\(hash-set! h "a" 10)
        \\(hash-set! h "b" 20)
        \\(hash-set! h "c" 30)
        \\(define total 0)
        \\(hash-for-each (lambda (k v) (set! total (+ total v))) h)
    );
    try expectInt(try rig.eval("total"), 60);
}

test "hash: nil key rejected" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define h (make-hash-table))");
    try std.testing.expectError(
        error.ContractViolation,
        rig.eval("(hash-set! h (quote ()) 1)"),
    );
}
