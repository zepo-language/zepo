//! Tests for define-syntax / syntax-rules hygienic macro system.
//! Covers: basic pattern matching, ellipsis, nested ellipsis, literals,
//! hygiene (binder renaming), multi-clause dispatch, and error paths.

// zepo-c18

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
        return r.ctx.evalString(src, "<syntax_rules_test>");
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

// ── Basic pattern matching ─────────────────────────────────────────────────

test "syntax-rules: constant template" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax always-42
        \\  (syntax-rules ()
        \\    ((_ ) 42)))
    );
    try expectInt(try rig.eval("(always-42)"), 42);
}

test "syntax-rules: single pattern variable" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-identity
        \\  (syntax-rules ()
        \\    ((_ x) x)))
    );
    try expectInt(try rig.eval("(my-identity 99)"), 99);
    try expectInt(try rig.eval("(my-identity (+ 1 2))"), 3);
}

test "syntax-rules: multiple pattern variables" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-if
        \\  (syntax-rules ()
        \\    ((_ c t f) (if c t f))))
    );
    try expectInt(try rig.eval("(my-if #t 1 2)"), 1);
    try expectInt(try rig.eval("(my-if #f 1 2)"), 2);
}

test "syntax-rules: swap two values" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-swap!
        \\  (syntax-rules ()
        \\    ((_ a b)
        \\     (let ((tmp a))
        \\       (set! a b)
        \\       (set! b tmp)))))
    );
    _ = try rig.eval("(define x 1) (define y 2) (my-swap! x y)");
    try expectInt(try rig.eval("x"), 2);
    try expectInt(try rig.eval("y"), 1);
}

// ── Multi-clause dispatch ──────────────────────────────────────────────────

test "syntax-rules: multi-clause my-and" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-and
        \\  (syntax-rules ()
        \\    ((_) #t)
        \\    ((_ e) e)
        \\    ((_ e1 e2 ...)
        \\     (if e1 (my-and e2 ...) #f))))
    );
    try expectBool(try rig.eval("(my-and)"), true);
    try expectBool(try rig.eval("(my-and #t)"), true);
    try expectBool(try rig.eval("(my-and #f)"), false);
    try expectBool(try rig.eval("(my-and #t #t #t)"), true);
    try expectBool(try rig.eval("(my-and #t #f #t)"), false);
}

test "syntax-rules: multi-clause my-or" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-or
        \\  (syntax-rules ()
        \\    ((_) #f)
        \\    ((_ e) e)
        \\    ((_ e1 e2 ...)
        \\     (let ((t e1))
        \\       (if t t (my-or e2 ...))))))
    );
    try expectBool(try rig.eval("(my-or)"), false);
    try expectBool(try rig.eval("(my-or #f)"), false);
    try expectBool(try rig.eval("(my-or #t)"), true);
    try expectBool(try rig.eval("(my-or #f #f #t)"), true);
    try expectBool(try rig.eval("(my-or #f #f #f)"), false);
}

// ── Ellipsis patterns ──────────────────────────────────────────────────────

test "syntax-rules: ellipsis collects zero args" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-list
        \\  (syntax-rules ()
        \\    ((_ x ...) (list x ...))))
    );
    try expectBool(try rig.eval("(null? (my-list))"), true);
    try expectInt(try rig.eval("(length (my-list 1 2 3))"), 3);
}

test "syntax-rules: ellipsis splices into template" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-begin
        \\  (syntax-rules ()
        \\    ((_ e) e)
        \\    ((_ e1 e2 ...)
        \\     (let ((dummy e1)) (my-begin e2 ...)))))
    );
    try expectInt(try rig.eval("(my-begin 1 2 3)"), 3);
}

test "syntax-rules: ellipsis used as fixed-prefix + rest" {
    // Pattern: (_ first rest ...) — single prefix, ellipsis tail.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax first-of
        \\  (syntax-rules ()
        \\    ((_ x rest ...) x)))
    );
    try expectInt(try rig.eval("(first-of 1 2 3)"), 1);
    try expectInt(try rig.eval("(first-of 99)"), 99);
}

// zepo-bn0a: an ellipsis template may reference more than one ellipsis-bound
// variable; they are expanded together in lockstep. Previously only the first
// was substituted and the rest leaked out as unbound symbols.
test "syntax-rules: two ellipsis vars in one template group" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax sum-pairs
        \\  (syntax-rules ()
        \\    ((_ (a b) ...) (+ (* a b) ...))))
    );
    // (+ (* 2 3) (* 4 5)) = 6 + 20 = 26
    try expectInt(try rig.eval("(sum-pairs (2 3) (4 5))"), 26);
}

test "syntax-rules: three ellipsis vars in one template group" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax add3each
        \\  (syntax-rules ()
        \\    ((_ (a b c) ...) (list (+ a b c) ...))))
    );
    // (list (+ 1 2 3) (+ 10 20 30)) = (6 60)
    try expectInt(try rig.eval("(car (add3each (1 2 3) (10 20 30)))"), 6);
    try expectInt(try rig.eval("(car (cdr (add3each (1 2 3) (10 20 30))))"), 60);
}

// ── Nested ellipsis (zepo-5rr6) ────────────────────────────────────────────

// zepo-5rr6: a pattern var can be bound at depth ≥ 2 by nested ellipses, and
// the template must be able to descend one depth level per ellipsis. The old
// FLAT binding model (scalar + one-level list) dropped depth-2 structure.

test "syntax-rules: nested ellipsis — flatten via x ... ..." {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // Pattern binds x at depth 2 (one ... per nesting). Template `x ... ...`
    // must flatten both levels into a single flat list.
    _ = try rig.eval(
        \\(define-syntax flatten2
        \\  (syntax-rules ()
        \\    ((_ (x ...) ...) (list x ... ...))))
    );
    // (flatten2 (1 2) (3) (4 5 6)) → (1 2 3 4 5 6)
    try expectInt(try rig.eval("(length (flatten2 (1 2) (3) (4 5 6)))"), 6);
    try expectInt(try rig.eval("(car (flatten2 (1 2) (3) (4 5 6)))"), 1);
    try expectInt(try rig.eval("(list-ref (flatten2 (1 2) (3) (4 5 6)) 2)"), 3);
    try expectInt(try rig.eval("(list-ref (flatten2 (1 2) (3) (4 5 6)) 5)"), 6);
    // Empty inner groups collapse away.
    try expectInt(try rig.eval("(length (flatten2 () (1) () (2 3)))"), 3);
    // No groups at all → empty list.
    try expectBool(try rig.eval("(null? (flatten2))"), true);
}

test "syntax-rules: nested ellipsis — preserve structure ((x ...) ...)" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // Template re-nests: (list (list x ...) ...) rebuilds the 2-level shape.
    _ = try rig.eval(
        \\(define-syntax regroup
        \\  (syntax-rules ()
        \\    ((_ (x ...) ...) (list (list x ...) ...))))
    );
    // (regroup (1 2) (3) (4 5 6)) → ((1 2) (3) (4 5 6))
    try expectInt(try rig.eval("(length (regroup (1 2) (3) (4 5 6)))"), 3);
    try expectInt(try rig.eval("(car (car (regroup (1 2) (3) (4 5 6))))"), 1);
    try expectInt(try rig.eval("(length (car (regroup (1 2) (3) (4 5 6))))"), 2);
    try expectInt(try rig.eval("(length (car (cdr (regroup (1 2) (3) (4 5 6)))))"), 1);
    try expectInt(try rig.eval("(car (car (cdr (cdr (regroup (1 2) (3) (4 5 6))))))"), 4);
}

test "syntax-rules: nested ellipsis — depth-1 var alongside depth-2" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // `k` is depth 1 (outer only); `v` is depth 2. The outer ellipsis drives
    // both; the inner ellipsis drives only v.
    _ = try rig.eval(
        \\(define-syntax tag-groups
        \\  (syntax-rules ()
        \\    ((_ (k v ...) ...) (list (list k (+ v ...)) ...))))
    );
    // (tag-groups (10 1 2) (20 3 4 5)) → ((10 3) (20 12))
    try expectInt(try rig.eval("(car (car (tag-groups (10 1 2) (20 3 4 5))))"), 10);
    try expectInt(try rig.eval("(car (cdr (car (tag-groups (10 1 2) (20 3 4 5)))))"), 3);
    try expectInt(try rig.eval("(car (cdr (car (cdr (tag-groups (10 1 2) (20 3 4 5))))))"), 12);
}

// ── Literal matching ───────────────────────────────────────────────────────

test "syntax-rules: literal keyword dispatch" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-case-lambda
        \\  (syntax-rules (else)
        \\    ((_ (else e)) e)
        \\    ((_ (test e) rest ...)
        \\     (if test e (my-case-lambda rest ...)))))
    );
    try expectInt(try rig.eval("(my-case-lambda (#f 1) (#t 2) (else 3))"), 2);
    try expectInt(try rig.eval("(my-case-lambda (#f 1) (#f 2) (else 99))"), 99);
}

// ── Hygiene ────────────────────────────────────────────────────────────────

test "syntax-rules: hygiene — macro tmp does not capture outer tmp" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // The swap macro introduces `tmp` internally. An outer `tmp` must not be
    // affected by the macro expansion.
    _ = try rig.eval(
        \\(define-syntax hygienic-swap!
        \\  (syntax-rules ()
        \\    ((_ a b)
        \\     (let ((tmp a))
        \\       (set! a b)
        \\       (set! b tmp)))))
    );
    _ = try rig.eval("(define tmp 100) (define a 1) (define b 2)");
    _ = try rig.eval("(hygienic-swap! a b)");
    try expectInt(try rig.eval("tmp"), 100); // outer tmp unchanged
    try expectInt(try rig.eval("a"), 2);
    try expectInt(try rig.eval("b"), 1);
}

test "syntax-rules: hygiene — macro lambda binder does not escape" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // A macro that introduces a lambda with a named binder.
    // The binder must not be visible at the call site.
    _ = try rig.eval(
        \\(define-syntax make-adder
        \\  (syntax-rules ()
        \\    ((_ n)
        \\     (lambda (x) (+ x n)))))
    );
    _ = try rig.eval("(define add5 (make-adder 5))");
    try expectInt(try rig.eval("(add5 10)"), 15);
    try expectInt(try rig.eval("(add5 0)"), 5);
}

test "syntax-rules: hygiene — nested macros do not interfere" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax inc!
        \\  (syntax-rules ()
        \\    ((_ x) (set! x (+ x 1)))))
    );
    _ = try rig.eval(
        \\(define-syntax inc2!
        \\  (syntax-rules ()
        \\    ((_ x) (begin (inc! x) (inc! x)))))
    );
    _ = try rig.eval("(define counter 0)");
    _ = try rig.eval("(inc2! counter)");
    try expectInt(try rig.eval("counter"), 2);
}

// ── Real-world patterns ────────────────────────────────────────────────────

test "syntax-rules: while loop macro" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax while
        \\  (syntax-rules ()
        \\    ((_ cond body ...)
        \\     (let loop ()
        \\       (when cond body ... (loop))))))
    );
    _ = try rig.eval("(define i 0) (define sum 0)");
    _ = try rig.eval("(while (< i 5) (set! sum (+ sum i)) (set! i (+ i 1)))");
    try expectInt(try rig.eval("sum"), 10);
    try expectInt(try rig.eval("i"), 5);
}

test "syntax-rules: dotimes loop macro" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax dotimes
        \\  (syntax-rules ()
        \\    ((_ (var n) body ...)
        \\     (let loop ((var 0))
        \\       (when (< var n)
        \\         body ...
        \\         (loop (+ var 1)))))))
    );
    _ = try rig.eval("(define acc 0)");
    _ = try rig.eval("(dotimes (i 5) (set! acc (+ acc i)))");
    try expectInt(try rig.eval("acc"), 10);
}

// ── Paired ellipsis (zepo-aua) ─────────────────────────────────────────────

test "syntax-rules: paired ellipsis ((var val) ...) my-let" {
    // zepo-aua: two pattern variables collected from a single ellipsis sequence
    // must expand independently in the template.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-let
        \\  (syntax-rules ()
        \\    ((_ ((var val) ...) body)
        \\     ((lambda (var ...) body) val ...))))
    );
    try expectInt(try rig.eval("(my-let ((x 1) (y 2)) (+ x y))"), 3);
    try expectInt(try rig.eval("(my-let ((a 10) (b 20) (c 30)) (+ a b c))"), 60);
    try expectInt(try rig.eval("(my-let ((p 5)) (my-let ((q 7)) (+ p q)))"), 12);
}

test "syntax-rules: paired ellipsis preserves outer bindings (hygiene)" {
    // zepo-aua: paired-ellipsis macros must still respect outer scope.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define-syntax my-let
        \\  (syntax-rules ()
        \\    ((_ ((var val) ...) body)
        \\     ((lambda (var ...) body) val ...))))
    );
    _ = try rig.eval("(define outer 100)");
    try expectInt(try rig.eval("(my-let ((b 1)) (+ outer b))"), 101);
    try expectInt(try rig.eval("outer"), 100); // unchanged
}

test "syntax-rules: pattern in stdlib when/unless" {
    // Verify stdlib when/unless (implemented via syntax-rules) work correctly.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define x 0)");
    _ = try rig.eval("(when #t (set! x (+ x 1)) (set! x (+ x 1)))");
    try expectInt(try rig.eval("x"), 2);
    _ = try rig.eval("(unless #f (set! x (+ x 10)))");
    try expectInt(try rig.eval("x"), 12);
    _ = try rig.eval("(when #f (set! x 999))");
    try expectInt(try rig.eval("x"), 12);
}
