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

// zepo-hlz
test "putDistinct: inserts distinct keys without a VM" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    const hashtable = runtime.hashtable;
    const ht = try hashtable.make(&rig.gc);
    const k1 = try objects.makeString(&rig.gc, "a");
    const k2 = try objects.makeString(&rig.gc, "b");
    try hashtable.putDistinct(&rig.gc, ht, k1, value_mod.fixnum(1));
    try hashtable.putDistinct(&rig.gc, ht, k2, value_mod.fixnum(2));
    try std.testing.expectEqual(@as(usize, 2), hashtable.size(ht));
}

// zepo-hlz
test "putDistinct: forces a resize and keeps all entries" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    const hashtable = runtime.hashtable;

    var scope = zepo.gc.HandleScope{};
    rig.gc.roots.pushHandleScope(&scope);
    defer rig.gc.roots.popHandleScope();

    const ht_slot = scope.push(try hashtable.make(&rig.gc));

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable;
        const key = try objects.makeString(&rig.gc, name);
        try hashtable.putDistinct(&rig.gc, ht_slot.*, key, value_mod.fixnum(@intCast(i)));
    }

    try std.testing.expectEqual(@as(usize, 20), hashtable.size(ht_slot.*));
    try std.testing.expect(hashtable.capacity(ht_slot.*) >= 20);

    // Read back specific entries so a key/value swap or slot collision is
    // caught, not just the count. Bootstrap the rig's VM (hashtable.get needs
    // one for structural key equality), then look up by fresh equal? keys.
    _ = try rig.eval("(+ 1 1)"); // lazily initializes ctx.vm
    const vm = &rig.ctx.vm.?;
    const k7 = try objects.makeString(&rig.gc, "k7");
    const k0 = try objects.makeString(&rig.gc, "k0");
    try expectInt(try hashtable.get(vm, ht_slot.*, k7, value_mod.FALSE), 7);
    try expectInt(try hashtable.get(vm, ht_slot.*, k0, value_mod.FALSE), 0);
}

// zepo-jnk: GC-pressure integrity exercise for set(). Each set() that triggers
// a resize allocates a new backing vector; the churn vector below pushes the
// nursery so those resizes coincide with moving minor collections. set() now
// roots ht/key/val across the resize so the post-GC (forwarded) pointers are
// used. NOTE: this is NOT a pre-fix crash repro — the unrooted code is masked
// in practice by Cheney forwarding-pointer self-healing (the next GC heals the
// backing's stale key slots), so it passes with or without the fix. This guards
// integrity of the insert path under heavy GC and documents the intended
// behaviour; the fix itself is defensive against that self-healing assumption.
test "set: insert path stays intact under resize-coincident GC (zepo-jnk)" {
    const hashtable = runtime.hashtable;
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(+ 1 1)"); // lazily initializes ctx.vm
    const vm = &rig.ctx.vm.?;
    const gc = &rig.gc;

    var scope = zepo.gc.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const ht_slot = scope.push(try hashtable.make(gc));

    const N: i63 = 300;
    var i: i63 = 0;
    while (i < N) : (i += 1) {
        // Push the nursery bump near the end so the next allocation (the
        // resize's backing vector, or makeString) forces a moving collect.
        _ = try objects.makeVector(gc, 20000, value_mod.NIL);
        var kbuf: [16]u8 = undefined;
        const ks = try std.fmt.bufPrint(&kbuf, "k{d}", .{i});
        const key = try objects.makeString(gc, ks);
        _ = try hashtable.set(gc, vm, ht_slot.*, key, value_mod.fixnum(i));
    }
    try std.testing.expectEqual(@as(usize, @intCast(N)), hashtable.size(ht_slot.*));

    // Every key must read back by a fresh equal? string.
    i = 0;
    while (i < N) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const ks = try std.fmt.bufPrint(&kbuf, "k{d}", .{i});
        const key = try objects.makeString(gc, ks);
        try expectInt(try hashtable.get(vm, ht_slot.*, key, value_mod.FALSE), i);
    }
}
