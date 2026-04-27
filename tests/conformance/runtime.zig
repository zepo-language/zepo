//! Runtime conformance tests: recursion, GC durability, tail calls.

const std = @import("std");
const zepo = @import("zepo");
const helpers = @import("helpers.zig");
const Rig = helpers.Rig;

const alloc = std.testing.allocator;

test "runtime: fibonacci(15) via recursion" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))");
    try helpers.expectInt(try r.eval("(fib 15)"), 610);
}

test "runtime: factorial via iteration" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval(
        \\(define (fact n)
        \\  (define (go i acc)
        \\    (if (> i n) acc (go (+ i 1) (* acc i))))
        \\  (go 1 1))
    );
    try helpers.expectInt(try r.eval("(fact 10)"), 3628800);
}

test "runtime: iota list construction forces GC" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval(
        \\(define (iota n)
        \\  (define (go i acc) (if (= i 0) acc (go (- i 1) (cons i acc))))
        \\  (go n (quote ())))
    );
    const v = try r.eval("(iota 2000)");
    try std.testing.expect(helpers.objects.isPair(v));
    try helpers.expectInt(helpers.objects.pairCar(v).*, 1);
}

test "runtime: closure survives allocation pressure" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (make-adder n) (lambda (x) (+ x n)))");
    _ = try r.eval("(define add5 (make-adder 5))");
    _ = try r.eval(
        \\(define (iota n)
        \\  (define (go i acc) (if (= i 0) acc (go (- i 1) (cons i acc))))
        \\  (go n (quote ())))
    );
    _ = try r.eval("(iota 1500)");
    try helpers.expectInt(try r.eval("(add5 10)"), 15);
}

test "runtime: symbol identity stable across GC" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define sym 'mysymbol)");
    _ = try r.eval(
        \\(define (iota n)
        \\  (define (go i acc) (if (= i 0) acc (go (- i 1) (cons i acc))))
        \\  (go n (quote ())))
    );
    _ = try r.eval("(iota 1500)");
    try helpers.expectTrue(try r.eval("(eq? sym 'mysymbol)"));
}

test "runtime: proper tail calls deep (1,000,000)" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (loop n) (if (= n 0) #t (loop (- n 1))))");
    try helpers.expectTrue(try r.eval("(loop 1000000)"));
}

test "runtime: mutual tail recursion" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (my-even? n) (if (= n 0) #t (my-odd? (- n 1))))");
    _ = try r.eval("(define (my-odd? n) (if (= n 0) #f (my-even? (- n 1))))");
    try helpers.expectTrue(try r.eval("(my-even? 10000)"));
    try helpers.expectFalse(try r.eval("(my-odd? 10000)"));
}

test "runtime: vector primitives" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define v (make-vector 3 0))");
    try helpers.expectInt(try r.eval("(vector-length v)"), 3);
    try helpers.expectInt(try r.eval("(vector-ref v 1)"), 0);
    _ = try r.eval("(vector-set! v 1 99)");
    try helpers.expectInt(try r.eval("(vector-ref v 1)"), 99);
    try helpers.expectTrue(try r.eval("(vector? v)"));
}
