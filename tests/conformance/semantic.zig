//! Semantic conformance tests: scoping, closures, mutation, equality.

const std = @import("std");
const zepo = @import("zepo");
const helpers = @import("helpers.zig");
const Rig = helpers.Rig;

const alloc = std.testing.allocator;

test "sema: lexical shadowing" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("((lambda (x) ((lambda (x) x) 2)) 1)");
    try helpers.expectInt(v, 2);
}

// zepo-3dtd: an internal define is a letrec*-scoped local, not a global.
test "sema: internal define does not leak to global" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // The function itself sees its internal binding.
    try helpers.expectInt(try r.eval("(define (f) (define secret 99) secret) (f)"), 99);
    // ...but after calling it, the name is NOT visible at top level.
    try std.testing.expectError(error.UnboundVariable, r.eval("(f) secret"));
}

test "sema: internal defines in two functions do not clobber each other" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (a) (define h 1) h)");
    _ = try r.eval("(define (b) (define h 2) h)");
    // Each call returns its own local, regardless of interleaving.
    try helpers.expectInt(try r.eval("(a)"), 1);
    try helpers.expectInt(try r.eval("(b)"), 1 + 1);
    try helpers.expectInt(try r.eval("(a)"), 1);
    // And neither leaked `h` to the global environment.
    try std.testing.expectError(error.UnboundVariable, r.eval("h"));
}

test "sema: internal define supports mutual recursion (letrec*)" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const src =
        \\(define (test)
        \\  (define (ev? n) (if (= n 0) #t (od? (- n 1))))
        \\  (define (od? n) (if (= n 0) #f (ev? (- n 1))))
        \\  (ev? 10))
        \\(test)
    ;
    try helpers.expectTrue(try r.eval(src));
}

test "sema: internal define initializer sees an earlier internal define" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // letrec* is sequential: b's initializer may reference a.
    try helpers.expectInt(try r.eval("(define (h) (define a 10) (define b (+ a 5)) b) (h)"), 15);
}

test "sema: nested helper via internal define" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(define (g) (define (helper x) (* x 2)) (helper 21)) (g)"), 42);
}

test "sema: closure captures an internal define" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(define (make) (define n 7) (lambda () n)) ((make))"), 7);
}

test "sema: internal define in a let body does not leak" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(let () (define x 5) (+ x 1))"), 6);
    try std.testing.expectError(error.UnboundVariable, r.eval("(let () (define leaky 7) leaky) leaky"));
}

test "sema: let shadowing" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(let ((x 1)) (let ((x 2)) x))");
    try helpers.expectInt(v, 2);
}

test "sema: closure captures outer binding" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (make-adder n) (lambda (x) (+ x n)))");
    try helpers.expectInt(try r.eval("((make-adder 5) 3)"), 8);
}

test "sema: set! mutates global binding" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define x 1)");
    _ = try r.eval("(set! x 42)");
    try helpers.expectInt(try r.eval("x"), 42);
}

test "sema: closure sees set! mutation" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define counter (let ((n 0)) (lambda () (set! n (+ n 1)) n)))");
    try helpers.expectInt(try r.eval("(counter)"), 1);
    try helpers.expectInt(try r.eval("(counter)"), 2);
    try helpers.expectInt(try r.eval("(counter)"), 3);
}

test "sema: fixed arity procedure" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (f x y) (+ x y))");
    try helpers.expectInt(try r.eval("(f 3 4)"), 7);
}

test "sema: rest argument" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (f x . rest) rest)");
    const v = try r.eval("(f 1 2 3)");
    try std.testing.expect(helpers.objects.isPair(v));
    try helpers.expectInt(helpers.objects.pairCar(v).*, 2);
    const rest = helpers.objects.pairCdr(v).*;
    try std.testing.expect(helpers.objects.isPair(rest));
    try helpers.expectInt(helpers.objects.pairCar(rest).*, 3);
}

test "sema: truthiness — only #f is false" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(if 0 1 2)"), 1);
    try helpers.expectInt(try r.eval("(if \"\" 1 2)"), 1);
    try helpers.expectInt(try r.eval("(if #f 1 2)"), 2);
}

test "sema: eq? vs equal? on fresh pairs" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define a (cons 1 2))");
    _ = try r.eval("(define b (cons 1 2))");
    try helpers.expectFalse(try r.eval("(eq? a b)"));
    try helpers.expectTrue(try r.eval("(equal? a b)"));
}

test "sema: eq? on interned symbols" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(eq? 'foo 'foo)"));
}

test "sema: let binds as expected" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(let ((x 1) (y 2)) (+ x y))"), 3);
}

test "sema: let* binds sequentially" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(let* ((x 1) (y (+ x 1))) (+ x y))"), 3);
}

test "sema: letrec allows mutual recursion" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
        \\         (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
        \\  (even? 10))
    );
    try helpers.expectTrue(v);
}

test "sema: and short-circuits" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(and)"));
    try helpers.expectFalse(try r.eval("(and #f (error))"));
    try helpers.expectInt(try r.eval("(and 1 2 3)"), 3);
}

test "sema: or short-circuits" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectFalse(try r.eval("(or)"));
    try helpers.expectInt(try r.eval("(or 1 (error))"), 1);
    try helpers.expectInt(try r.eval("(or #f 2 3)"), 2);
}

test "sema: named let basic loop" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(let loop ((i 0) (acc 0)) (if (= i 5) acc (loop (+ i 1) (+ acc i))))");
    try helpers.expectInt(v, 10);
}

test "sema: named let captures outer" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define result (let loop ((n 3) (acc 1)) (if (= n 0) acc (loop (- n 1) (* acc n)))))");
    try helpers.expectInt(try r.eval("result"), 6);
}
