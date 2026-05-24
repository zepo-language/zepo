//! Tests for individual primitive modules (src/prims/).
//! Covers arithmetic edge cases, pairs/list ops, string primitives,
//! type predicates, equality, and bitwise operations.
//! Channel and process primitives are covered by vm_test.zig and integration tests.

// zepo-1hw

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
        return r.ctx.evalString(src, "<prims_test>");
    }
};

fn expectInt(v: abi.Value, n: i63) !void {
    try std.testing.expect(value_mod.isFixnum(v));
    try std.testing.expectEqual(n, value_mod.fixnumVal(v));
}

fn expectBool(v: abi.Value, b: bool) !void {
    if (b) try std.testing.expect(!value_mod.isFalse(v))
    else   try std.testing.expect(value_mod.isFalse(v));
}

fn expectStr(v: abi.Value, s: []const u8) !void {
    const obj = zepo.runtime.objects;
    try std.testing.expect(obj.isString(v));
    try std.testing.expectEqualStrings(s, obj.stringBytes(v));
}

// ── Arithmetic (src/prims/arith.zig) ──────────────────────────────────────

test "arith: addition identity and commutativity" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(+)"), 0);
    try expectInt(try rig.eval("(+ 5)"), 5);
    try expectInt(try rig.eval("(+ 1 2 3 4 5)"), 15);
    try expectInt(try rig.eval("(+ -3 3)"), 0);
}

test "arith: subtraction and negation" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(- 10 3)"), 7);
    try expectInt(try rig.eval("(- 10 3 2 1)"), 4);
    try expectInt(try rig.eval("(- 5)"), -5);
}

test "arith: multiplication identity" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(*)"), 1);
    try expectInt(try rig.eval("(* 6)"), 6);
    try expectInt(try rig.eval("(* 2 3 4)"), 24);
    try expectInt(try rig.eval("(* -1 5)"), -5);
}

test "arith: integer division truncates toward zero" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(quotient 10 3)"), 3);
    try expectInt(try rig.eval("(quotient -10 3)"), -3);
    try expectInt(try rig.eval("(remainder 10 3)"), 1);
    try expectInt(try rig.eval("(remainder -10 3)"), -1);
    try expectInt(try rig.eval("(modulo 10 3)"), 1);
    try expectInt(try rig.eval("(modulo -10 3)"), 2); // modulo follows sign of divisor
}

test "arith: min and max" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(min 3 1 4 1 5 9)"), 1);
    try expectInt(try rig.eval("(max 3 1 4 1 5 9)"), 9);
    try expectInt(try rig.eval("(min -5 0 5)"), -5);
}

test "arith: abs" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(abs -7)"), 7);
    try expectInt(try rig.eval("(abs 7)"), 7);
    try expectInt(try rig.eval("(abs 0)"), 0);
}

test "arith: comparison chain" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectBool(try rig.eval("(< 1 2 3 4)"), true);
    try expectBool(try rig.eval("(< 1 2 2 4)"), false);
    try expectBool(try rig.eval("(<= 1 2 2 4)"), true);
    try expectBool(try rig.eval("(> 4 3 2 1)"), true);
    try expectBool(try rig.eval("(>= 4 3 3 1)"), true);
    try expectBool(try rig.eval("(= 5 5 5)"), true);
    try expectBool(try rig.eval("(= 5 5 6)"), false);
}

// ── Pairs and lists (src/prims/pairs.zig) ──────────────────────────────────

test "pairs: cons / car / cdr basics" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(car (cons 1 2))"), 1);
    const cdr = try rig.eval("(cdr (cons 1 2))");
    try expectInt(cdr, 2);
}

test "pairs: list construction and length" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(length '())"), 0);
    try expectInt(try rig.eval("(length '(1 2 3))"), 3);
    try expectInt(try rig.eval("(length (list 1 2 3 4 5))"), 5);
}

test "pairs: append" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(length (append '(1 2) '(3 4)))"), 4);
    try expectInt(try rig.eval("(car (append '(1 2) '(3 4)))"), 1);
    // append with empty
    try expectInt(try rig.eval("(length (append '() '(1 2 3)))"), 3);
}

test "pairs: reverse" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(car (reverse '(1 2 3)))"), 3);
    try expectInt(try rig.eval("(length (reverse '(1 2 3)))"), 3);
}

test "pairs: list-ref and list-tail" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(list-ref '(a b c 42) 3)"), 42);
    try expectInt(try rig.eval("(length (list-tail '(1 2 3 4 5) 2))"), 3);
}

test "pairs: assoc / assv / assq" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define al '((a 1) (b 2) (c 3)))");
    try expectBool(try rig.eval("(pair? (assq 'b al))"), true);
    try expectBool(try rig.eval("(not (assq 'd al))"), true);
}

// ── Type predicates (src/prims/predicates.zig) ─────────────────────────────

test "predicates: type discrimination" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectBool(try rig.eval("(number? 42)"), true);
    try expectBool(try rig.eval("(number? #t)"), false);
    try expectBool(try rig.eval("(string? \"hi\")"), true);
    try expectBool(try rig.eval("(string? 42)"), false);
    try expectBool(try rig.eval("(symbol? 'foo)"), true);
    try expectBool(try rig.eval("(symbol? \"foo\")"), false);
    try expectBool(try rig.eval("(pair? '(1 2))"), true);
    try expectBool(try rig.eval("(pair? '())"), false);
    try expectBool(try rig.eval("(null? '())"), true);
    try expectBool(try rig.eval("(null? '(1))"), false);
    try expectBool(try rig.eval("(boolean? #t)"), true);
    try expectBool(try rig.eval("(boolean? 1)"), false);
    try expectBool(try rig.eval("(procedure? car)"), true);
    try expectBool(try rig.eval("(procedure? 42)"), false);
}

test "predicates: zero? positive? negative?" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectBool(try rig.eval("(zero? 0)"), true);
    try expectBool(try rig.eval("(zero? 1)"), false);
    try expectBool(try rig.eval("(positive? 1)"), true);
    try expectBool(try rig.eval("(positive? -1)"), false);
    try expectBool(try rig.eval("(negative? -1)"), true);
    try expectBool(try rig.eval("(negative? 0)"), false);
}

// ── Equality (src/prims/equality.zig) ─────────────────────────────────────

test "equality: eq? and equal?" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // eq? — identity for symbols, booleans, nil, and fixnums
    try expectBool(try rig.eval("(eq? 'a 'a)"), true);
    try expectBool(try rig.eval("(eq? 'a 'b)"), false);
    try expectBool(try rig.eval("(eq? '() '())"), true);
    try expectBool(try rig.eval("(eq? #t #t)"), true);
    try expectBool(try rig.eval("(eq? #f #t)"), false);
    // equal? — structural equality for lists and strings
    try expectBool(try rig.eval("(equal? '(1 2 3) '(1 2 3))"), true);
    try expectBool(try rig.eval("(equal? '(1 2 3) '(1 2 4))"), false);
    try expectBool(try rig.eval("(equal? \"abc\" \"abc\")"), true);
    try expectBool(try rig.eval("(equal? \"abc\" \"def\")"), false);
    // equal? on numbers
    try expectBool(try rig.eval("(equal? 42 42)"), true);
    try expectBool(try rig.eval("(equal? 42 43)"), false);
}

// ── Strings (src/prims/io.zig + stdlib) ───────────────────────────────────

test "strings: basic operations" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(string-length \"hello\")"), 5);
    try expectInt(try rig.eval("(string-length \"\")"), 0);
    try expectStr(try rig.eval("(string-append \"foo\" \"bar\")"), "foobar");
    try expectStr(try rig.eval("(substring \"hello\" 1 3)"), "el");
    try expectBool(try rig.eval("(string=? \"abc\" \"abc\")"), true);
    try expectBool(try rig.eval("(string<? \"abc\" \"abd\")"), true);
}

test "strings: number conversions" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(string->number \"42\")"), 42);
    try expectBool(try rig.eval("(not (string->number \"abc\"))"), true);
    try expectStr(try rig.eval("(number->string 42)"), "42");
}

test "strings: symbol conversions" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectStr(try rig.eval("(symbol->string 'hello)"), "hello");
    try expectBool(try rig.eval("(eq? (string->symbol \"world\") 'world)"), true);
}

// ── Bitwise (src/prims/bitwise.zig) ───────────────────────────────────────

test "bitwise: and / or / xor / not" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    try expectInt(try rig.eval("(bitwise-and 12 10)"), 8);  // 1100 & 1010 = 1000
    try expectInt(try rig.eval("(bitwise-or  12 10)"), 14); // 1100 | 1010 = 1110
    try expectInt(try rig.eval("(bitwise-xor 12 10)"), 6);  // 1100 ^ 1010 = 0110
    try expectInt(try rig.eval("(arithmetic-shift 1 4)"), 16);
    try expectInt(try rig.eval("(arithmetic-shift 16 -2)"), 4);
}
