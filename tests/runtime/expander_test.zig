//! Tests for the macro expander (src/expand/).
//! Covers gaps not in macros_test.zig: recursive defmacro, rest-arg macros,
//! gensym hygiene, nested quasiquote, macro-generating macros, and
//! quasiquote edge cases (empty splicing, deeply nested unquote).

// zepo-xx8

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
        return r.ctx.evalString(src, "<expander_test>");
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

// ── Recursive defmacro ─────────────────────────────────────────────────────

test "expander: recursive defmacro (my-or variadic)" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(defmacro my-or args
        \\  (if (null? args)
        \\      #f
        \\      (if (null? (cdr args))
        \\          (car args)
        \\          `(let ((t ,(car args)))
        \\             (if t t (my-or ,@(cdr args)))))))
    );
    try expectBool(try rig.eval("(my-or)"), false);
    try expectBool(try rig.eval("(my-or #f)"), false);
    try expectBool(try rig.eval("(my-or #t)"), true);
    try expectBool(try rig.eval("(my-or #f #f #t)"), true);
    try expectBool(try rig.eval("(my-or #f #f #f)"), false);
}

test "expander: recursive defmacro (my-and variadic)" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(defmacro my-and args
        \\  (cond
        \\    ((null? args) #t)
        \\    ((null? (cdr args)) (car args))
        \\    (else `(if ,(car args) (my-and ,@(cdr args)) #f))))
    );
    try expectBool(try rig.eval("(my-and)"), true);
    try expectBool(try rig.eval("(my-and #t #t #t)"), true);
    try expectBool(try rig.eval("(my-and #t #f #t)"), false);
}

// ── Rest-arg defmacro ──────────────────────────────────────────────────────

test "expander: defmacro with rest args collects remaining forms" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(defmacro my-begin (first . rest)
        \\  (if (null? rest)
        \\      first
        \\      `(let ((dummy ,first)) (my-begin ,@rest))))
    );
    try expectInt(try rig.eval("(my-begin 1)"), 1);
    try expectInt(try rig.eval("(my-begin 1 2 3)"), 3);
}

test "expander: defmacro rest args empty when no extra forms" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(defmacro first-or-zero (x . rest)
        \\  (if (null? rest) x (car rest)))
    );
    try expectInt(try rig.eval("(first-or-zero 99)"), 99);
    try expectInt(try rig.eval("(first-or-zero 99 42)"), 42);
}

// ── Gensym prevents capture ────────────────────────────────────────────────

test "expander: gensym creates unique symbols across calls" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define g1 (gensym))
        \\(define g2 (gensym))
    );
    // g1 and g2 must be distinct symbols.
    try expectBool(try rig.eval("(eq? g1 g2)"), false);
}

test "expander: gensym-based swap! does not clobber outer tmp" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(defmacro safe-swap! (a b)
        \\  (let ((tmp (gensym)))
        \\    `(let ((,tmp ,a))
        \\       (set! ,a ,b)
        \\       (set! ,b ,tmp))))
    );
    _ = try rig.eval("(define tmp 100) (define a 1) (define b 2)");
    _ = try rig.eval("(safe-swap! a b)");
    try expectInt(try rig.eval("tmp"), 100); // outer tmp untouched
    try expectInt(try rig.eval("a"), 2);
    try expectInt(try rig.eval("b"), 1);
}

// ── Quasiquote edge cases ──────────────────────────────────────────────────

test "expander: quasiquote with empty splice produces no elements" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define empty '())");
    // `(1 ,@empty 2) should be (1 2).
    const v = try rig.eval("(length `(1 ,@empty 2))");
    try expectInt(v, 2);
}

test "expander: quasiquote multiple splices" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define xs '(1 2)) (define ys '(3 4))");
    const v = try rig.eval("(length `(,@xs ,@ys))");
    try expectInt(v, 4);
}

test "expander: quasiquote nested unquote reaches correct level" {
    // `(a ,(+ 1 2)) — the inner unquote evaluates immediately.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // car is symbol 'result', cadr is 15.
    const cadr = try rig.eval("(cadr `(result ,(+ 10 5)))");
    try expectInt(cadr, 15);
}

// ── Macro-generating macros ────────────────────────────────────────────────

test "expander: macro that generates a define" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(defmacro def-adder (name n)
        \\  `(define (,name x) (+ x ,n)))
        \\(def-adder add10 10)
        \\(def-adder add100 100)
    );
    try expectInt(try rig.eval("(add10 5)"), 15);
    try expectInt(try rig.eval("(add100 1)"), 101);
}

test "expander: macro generates multiple defines" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(defmacro def-pair (name a b)
        \\  `(begin
        \\     (define ,(string->symbol (string-append (symbol->string name) "-first")) ,a)
        \\     (define ,(string->symbol (string-append (symbol->string name) "-second")) ,b)))
        \\(def-pair point 3 7)
    );
    try expectInt(try rig.eval("point-first"), 3);
    try expectInt(try rig.eval("point-second"), 7);
}

// ── Expansion does not fire on literal data ────────────────────────────────

test "expander: macro name in quoted list is not expanded" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(defmacro sentinel-macro (x) (error \"should not expand\"))");
    // The macro must NOT fire inside a quoted form.
    const len = try rig.eval("(length '(sentinel-macro 1 2 3))");
    try expectInt(len, 4);
}
