//! Primitive conformance tests.

const std = @import("std");
const zepo = @import("zepo");
const helpers = @import("helpers.zig");
const Rig = helpers.Rig;

const alloc = std.testing.allocator;

test "prims: +, -, *, /" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(+ 1 2 3)"), 6);
    try helpers.expectInt(try r.eval("(- 10 3)"), 7);
    try helpers.expectInt(try r.eval("(- 5)"), -5);
    try helpers.expectInt(try r.eval("(* 2 3 4)"), 24);
    try helpers.expectInt(try r.eval("(/ 10 2)"), 5);
}

test "prims: float promotion" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(+ 1 1.5)");
    try helpers.expectFloat(v, 2.5, 1e-9);
}

// zepo-9usm/nfak: fixnum payload is a 61-bit field (range [-2^60, 2^60-1]).
// Arithmetic inside the range stays an exact fixnum; stepping outside now
// promotes to an EXACT BIGNUM (zepo-nfak — previously a lossy float), never a
// silently-wrapped fixnum.
test "prims: fixnum overflow promotes to an exact bignum, no silent wrap" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // 2^60-1 is the largest fixnum — reaching it exactly stays a fixnum.
    try helpers.expectInt(try r.eval("(+ 1152921504606846974 1)"), 1152921504606846975);
    // One past the top is an exact bignum (was corrupting to -2^60, then a float).
    try helpers.expectString(try r.eval("(display-to-string (+ 1152921504606846975 1))"), "1152921504606846976");
    try helpers.expectTrue(try r.eval("(> (+ 1152921504606846975 1) 0)"));
    // MUL2 fast path: 2^30 * 2^30 = 2^60 overflows the fixnum range.
    try helpers.expectString(try r.eval("(display-to-string (* 1073741824 1073741824))"), "1152921504606846976");
    // Below the floor (-2^60).
    try helpers.expectString(try r.eval("(display-to-string (- -1152921504606846976 1))"), "-1152921504606846977");
    // abs / negate of the most-negative fixnum (-2^60) is +2^60, one past the top.
    try helpers.expectString(try r.eval("(display-to-string (abs -1152921504606846976))"), "1152921504606846976");
    try helpers.expectString(try r.eval("(display-to-string (- -1152921504606846976))"), "1152921504606846976");
    // Exact: the bignum minus itself-less-42 is exactly 42 (normalizes to fixnum).
    try helpers.expectInt(try r.eval("(- (* 1073741824 1073741824) (- (* 1073741824 1073741824) 42))"), 42);
}

// zepo-9usm/nfak: an integer literal wider than the fixnum range now reads as
// an exact bignum (previously rejected as OverflowInt — there was no bignum
// tower). Both a value in [2^60, 2^63) and one wider than i64 read exactly.
test "reader: over-range integer literal reads as an exact bignum" {
    const r = try Rig.initWithPrelude(alloc); // uses exact?
    defer r.deinit();
    try helpers.expectString(try r.eval("(display-to-string 1152921504606846976)"), "1152921504606846976");
    try helpers.expectString(try r.eval("(display-to-string 4611686018427387903)"), "4611686018427387903");
    try helpers.expectString(try r.eval("(display-to-string 123456789012345678901234567890)"), "123456789012345678901234567890");
    try helpers.expectTrue(try r.eval("(exact? 1152921504606846976)"));
}

// zepo-s2o4: rendering a cyclic or pathologically deep structure must not
// overflow the native stack (it used to SIGBUS). Cycles render as a marker;
// json-stringify errors rather than crash.
test "prims: display of a self-referential vector terminates with a marker" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(define v (make-vector 1 0)) (vector-set! v 0 v) (display-to-string v)"),
        "#(...)",
    );
}

test "prims: cycle through vector+list renders the back-edge as a marker" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(define v (make-vector 1 0)) (vector-set! v 0 (list 1 v 3)) (display-to-string v)"),
        "#((1 ... 3))",
    );
}

test "prims: shared (acyclic) structure is rendered fully, not truncated" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // `x` appears twice as siblings — the guard tracks ancestors on the path,
    // not a global seen-set, so a DAG is not mistaken for a cycle.
    try helpers.expectString(
        try r.eval("(define x (list 1 2)) (display-to-string (list x x))"),
        "((1 2) (1 2))",
    );
}

test "prims: a long flat list renders fully (spine is iterated, not recursed)" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const src =
        \\(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))
        \\(> (string-length (display-to-string (build 10000 (list)))) 40000)
    ;
    try helpers.expectTrue(try r.eval(src));
}

test "prims: json-stringify of a cyclic structure errors, does not crash" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // json-stringify returns a result object; a cycle yields an (err ...) tag,
    // and — the point — eval completes instead of overflowing the stack.
    try helpers.expectString(
        try r.eval("(define v (make-vector 1 0)) (vector-set! v 0 v) (display-to-string (car (json-stringify v)))"),
        "err",
    );
}

// zepo-mckx: inexact reals render with a decimal point (so 1.0 is not shown as
// the integer 1 and round-trips), and non-finite values use R7RS syntax.
test "prims: float external representation" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectString(try r.eval("(display-to-string 1.0)"), "1.0");
    try helpers.expectString(try r.eval("(display-to-string 100.0)"), "100.0");
    try helpers.expectString(try r.eval("(display-to-string 3.14)"), "3.14");
    try helpers.expectString(try r.eval("(display-to-string -0.5)"), "-0.5");
    try helpers.expectString(try r.eval("(number->string 2.0)"), "2.0");
    try helpers.expectString(try r.eval("(display-to-string (prim-inf))"), "+inf.0");
    try helpers.expectString(try r.eval("(display-to-string (prim-neg-inf))"), "-inf.0");
    try helpers.expectString(try r.eval("(display-to-string (prim-nan))"), "+nan.0");
}

// zepo-7mwa: R7RS stdlib absentees added in lib/stdlib.lisp + open-input-string.
test "prims: R7RS stdlib additions — predicates and list/exactness ops" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    // eqv?-based membership / association.
    try helpers.expectInt(try r.eval("(car (memv 2 (list 1 2 3)))"), 2);
    try helpers.expectInt(try r.eval("(cdr (assv 2 (list (cons 1 10) (cons 2 20))))"), 20);
    try helpers.expectFalse(try r.eval("(memv 9 (list 1 2 3))"));
    // make-list / list-copy.
    try helpers.expectInt(try r.eval("(length (make-list 4 0))"), 4);
    try helpers.expectInt(try r.eval("(car (make-list 3 7))"), 7);
    try helpers.expectInt(try r.eval("(car (list-copy (list 5 6)))"), 5);
    // Identity-based equality predicates.
    try helpers.expectTrue(try r.eval("(symbol=? 'a 'a 'a)"));
    try helpers.expectFalse(try r.eval("(symbol=? 'a 'b)"));
    try helpers.expectTrue(try r.eval("(boolean=? #t #t)"));
    try helpers.expectFalse(try r.eval("(boolean=? #t #f)"));
    // Case-insensitive comparisons.
    try helpers.expectTrue(try r.eval("(char-ci=? #\\A #\\a)"));
    try helpers.expectTrue(try r.eval("(string-ci=? \"FoO\" \"foo\")"));
    // Exactness.
    try helpers.expectTrue(try r.eval("(exact? 5)"));
    try helpers.expectFalse(try r.eval("(exact? 5.0)"));
    try helpers.expectTrue(try r.eval("(inexact? 5.0)"));
    try helpers.expectTrue(try r.eval("(exact-integer? 5)"));
    try helpers.expectFalse(try r.eval("(exact-integer? 5.0)"));
    try helpers.expectInt(try r.eval("(exact 3.0)"), 3);
    try helpers.expectFloat(try r.eval("(inexact 3)"), 3.0, 1e-9);
}

test "prims: R7RS stdlib additions — division, sqrt, string ops, input string" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    // Multiple-value division consumed via call-with-values.
    try helpers.expectInt(try r.eval("(call-with-values (lambda () (floor/ 7 2)) (lambda (q r) q))"), 3);
    try helpers.expectInt(try r.eval("(call-with-values (lambda () (floor/ 7 2)) (lambda (q r) r))"), 1);
    try helpers.expectInt(try r.eval("(call-with-values (lambda () (floor/ -7 2)) (lambda (q r) q))"), -4);
    try helpers.expectInt(try r.eval("(call-with-values (lambda () (truncate/ -7 2)) (lambda (q r) q))"), -3);
    try helpers.expectInt(try r.eval("(call-with-values (lambda () (exact-integer-sqrt 17)) (lambda (s r) s))"), 4);
    try helpers.expectInt(try r.eval("(call-with-values (lambda () (exact-integer-sqrt 17)) (lambda (s r) r))"), 1);
    try helpers.expectInt(try r.eval("(call-with-values (lambda () (exact-integer-sqrt 16)) (lambda (s r) s))"), 4);
    // String helpers.
    try helpers.expectString(try r.eval("(string-copy \"hello\" 1 4)"), "ell");
    try helpers.expectString(try r.eval("(string-map char-upcase \"abc\")"), "ABC");
    try helpers.expectInt(try r.eval("(vector-length (string->vector \"hi\"))"), 2);
    try helpers.expectString(try r.eval("(vector->string (vector #\\y #\\o))"), "yo");
    // open-input-string reads characters, then EOF.
    try helpers.expectInt(try r.eval("(char->integer (read-char (open-input-string \"A\")))"), 65);
    try helpers.expectTrue(try r.eval("(let ((p (open-input-string \"\"))) (eof-object? (read-char p)))"));
}

// zepo-qaxw: R7RS special forms added as macros in lib/stdlib.lisp.
test "special forms: case, do, delay/force" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    // case: datum lists + else + => clause.
    try helpers.expectInt(try r.eval("(case 3 ((1) 10) ((2 3) 23) (else 99))"), 23);
    try helpers.expectInt(try r.eval("(case 5 ((1) 10) (else 99))"), 99);
    try helpers.expectInt(try r.eval("(case 7 ((7) => (lambda (k) (* k 2))) (else 0))"), 14);
    // do: iterative sum 0..4 = 10.
    try helpers.expectInt(try r.eval("(do ((i 0 (+ i 1)) (s 0 (+ s i))) ((= i 5) s))"), 10);
    // delay/force: forced once, memoized. A counter proves single evaluation.
    try helpers.expectInt(
        try r.eval("(define n 0) (define p (delay (begin (set! n (+ n 1)) 42))) (force p) (force p) n"),
        1,
    );
    try helpers.expectInt(try r.eval("(force (delay (* 6 7)))"), 42);
    try helpers.expectInt(try r.eval("(force 5)"), 5); // non-promise passes through
}

test "special forms: let-values, define-values, case-lambda, dynamic-wind" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    // let-values consumes multiple values.
    try helpers.expectInt(try r.eval("(let-values (((q rr) (floor/ 7 2))) (+ (* q 10) rr))"), 31);
    // define-values binds each name.
    try helpers.expectInt(try r.eval("(define-values (a b) (values 4 5)) (+ (* a 10) b)"), 45);
    // case-lambda dispatches on arity, including a rest clause.
    try helpers.expectString(
        try r.eval("(define f (case-lambda ((x) \"one\") ((x y) \"two\") ((x . r) \"many\"))) (f 1)"),
        "one",
    );
    try helpers.expectString(try r.eval("(f 1 2)"), "two");
    try helpers.expectString(try r.eval("(f 1 2 3)"), "many");
    // dynamic-wind runs after on both normal return and non-local (raise) exit.
    try helpers.expectInt(
        try r.eval("(define c 0) (dynamic-wind (lambda () (set! c (+ c 1))) (lambda () 0) (lambda () (set! c (+ c 10)))) c"),
        11,
    );
    try helpers.expectInt(
        try r.eval("(define d 0) (guard (e (#t d)) (dynamic-wind (lambda () (set! d 1)) (lambda () (raise 'x)) (lambda () (set! d (+ d 100)))))"),
        101,
    );
}

// zepo-k5pp: escape (upward) continuations. call/ec's escape unwinds through
// dynamic-wind (running `after`) and passes through exception handlers, but is
// caught by its own call/ec.
test "control: call/ec escape continuations" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    // Basic escape skips the surrounding computation.
    try helpers.expectInt(try r.eval("(call/ec (lambda (k) (+ 1 (k 42))))"), 42);
    // No escape → normal result.
    try helpers.expectInt(try r.eval("(call/ec (lambda (k) 10))"), 10);
    // Early exit from an iteration.
    try helpers.expectInt(
        try r.eval("(call/ec (lambda (ret) (for-each (lambda (x) (when (> x 3) (ret x))) (list 1 2 3 4 5)) 0))"),
        4,
    );
    // Escape to the OUTER of two nested call/ec, past the inner one.
    try helpers.expectString(
        try r.eval("(symbol->string (call/ec (lambda (o) (call/ec (lambda (i) (o 'A))) 'B)))"),
        "A",
    );
    // dynamic-wind `after` runs on escape (nested, correct order).
    try helpers.expectString(
        try r.eval(
            \\(define lg (list))
            \\(call/ec (lambda (k)
            \\  (dynamic-wind (lambda () (set! lg (cons 'ai lg)))
            \\    (lambda () (dynamic-wind (lambda () (set! lg (cons 'bi lg)))
            \\                 (lambda () (k 0))
            \\                 (lambda () (set! lg (cons 'bo lg)))))
            \\    (lambda () (set! lg (cons 'ao lg))))))
            \\(display-to-string (reverse lg))
        ),
        "(ai bi bo ao)",
    );
    // An intervening catch-all guard does NOT swallow the escape.
    try helpers.expectString(
        try r.eval("(symbol->string (call/ec (lambda (k) (guard (e (#t 'caught)) (k 'escaped)))))"),
        "escaped",
    );
    // A real condition IS still caught by guard.
    try helpers.expectString(
        try r.eval("(symbol->string (call/ec (lambda (k) (guard (e (#t 'caught)) (raise 'boom)))))"),
        "caught",
    );
    // Multiple values through the escape.
    try helpers.expectInt(
        try r.eval("(call-with-values (lambda () (call/ec (lambda (k) (k 3 4)))) (lambda (a b) (+ a b)))"),
        7,
    );
}

// zepo-nfak: arbitrary-precision exact integers. Overflow promotes to an exact
// bignum instead of an imprecise float; literals, arithmetic, comparison,
// predicates, equality, and string conversions all work at full precision.
test "bignum: literals, predicates, and string conversion" {
    const r = try Rig.initWithPrelude(alloc); // uses exact?/inexact?
    defer r.deinit();
    // A literal wider than the fixnum range reads as an exact integer.
    try helpers.expectString(try r.eval("(display-to-string 123456789012345678901234567890)"), "123456789012345678901234567890");
    try helpers.expectString(try r.eval("(display-to-string -99999999999999999999999999999999)"), "-99999999999999999999999999999999");
    try helpers.expectTrue(try r.eval("(number? 123456789012345678901234567890)"));
    try helpers.expectTrue(try r.eval("(integer? 123456789012345678901234567890)"));
    try helpers.expectTrue(try r.eval("(exact? 123456789012345678901234567890)"));
    try helpers.expectFalse(try r.eval("(inexact? 123456789012345678901234567890)"));
    // number->string / string->number round-trip at full precision.
    try helpers.expectString(try r.eval("(number->string 123456789012345678901234567890)"), "123456789012345678901234567890");
    try helpers.expectString(try r.eval("(display-to-string (string->number \"123456789012345678901234567890\"))"), "123456789012345678901234567890");
    // eqv?/equal? by value.
    try helpers.expectTrue(try r.eval("(eqv? 123456789012345678901234567890 123456789012345678901234567890)"));
    try helpers.expectFalse(try r.eval("(eqv? 123456789012345678901234567890 5)"));
    try helpers.expectTrue(try r.eval("(equal? 123456789012345678901234567890 123456789012345678901234567890)"));
}

test "bignum: exact arithmetic (no overflow→float) and comparison" {
    const r = try Rig.initWithPrelude(alloc); // uses expt
    defer r.deinit();
    // Multiplication that overflows a fixnum stays exact.
    try helpers.expectString(try r.eval("(display-to-string (* 1000000000000000000 1000000000000000000))"), "1000000000000000000000000000000000000");
    try helpers.expectString(try r.eval("(display-to-string (expt 2 100))"), "1267650600228229401496703205376");
    try helpers.expectString(try r.eval("(display-to-string (+ 999999999999999999999999 1))"), "1000000000000000000000000");
    try helpers.expectString(try r.eval("(display-to-string (- 0 123456789012345678901234567890))"), "-123456789012345678901234567890");
    try helpers.expectString(try r.eval("(display-to-string (abs (- (expt 2 90))))"), "1237940039285380274899124224");
    // quotient / remainder / modulo on bignums.
    try helpers.expectString(try r.eval("(display-to-string (quotient (expt 10 30) 7))"), "142857142857142857142857142857");
    try helpers.expectInt(try r.eval("(remainder (expt 10 30) 7)"), 1);
    try helpers.expectInt(try r.eval("(modulo (- (expt 10 30)) 7)"), 6);
    // exact division: divisible → exact, indivisible → float.
    try helpers.expectString(try r.eval("(display-to-string (/ (expt 10 30) (expt 10 15)))"), "1000000000000000");
    // comparison, including bignum vs fixnum (a bignum is never fixnum-range).
    try helpers.expectTrue(try r.eval("(= (expt 2 100) (expt 2 100))"));
    try helpers.expectTrue(try r.eval("(< (expt 2 100) (expt 2 101))"));
    try helpers.expectTrue(try r.eval("(> (expt 10 50) 999999999)"));
    try helpers.expectFalse(try r.eval("(= (expt 2 100) (expt 2 101))"));
    // A bignum result that shrinks back into fixnum range normalizes to a fixnum.
    try helpers.expectInt(try r.eval("(- (expt 2 100) (- (expt 2 100) 42))"), 42);
}

// zepo-or1d: exact rationals. Exact division of non-divisible integers yields a
// reduced ratio (not a float); arithmetic across fixnum/bignum/ratio stays exact.
test "ratio: exact division, arithmetic, and reduction" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // Non-divisible exact division is a reduced ratio; divisible reduces to int.
    try helpers.expectString(try r.eval("(display-to-string (/ 1 3))"), "1/3");
    try helpers.expectString(try r.eval("(display-to-string (/ 6 4))"), "3/2");
    try helpers.expectInt(try r.eval("(/ 6 3)"), 2);
    try helpers.expectString(try r.eval("(display-to-string (/ 3))"), "1/3"); // unary = 1/x
    // Arithmetic across ratios reduces (and normalizes back to an integer).
    try helpers.expectString(try r.eval("(display-to-string (+ 1/2 1/3))"), "5/6");
    try helpers.expectString(try r.eval("(display-to-string (* 2/3 3/4))"), "1/2");
    try helpers.expectInt(try r.eval("(+ 1/3 2/3)"), 1);
    try helpers.expectInt(try r.eval("(* 6 1/2)"), 3);
    try helpers.expectString(try r.eval("(display-to-string (- 5/3))"), "-5/3"); // unary negate
    // Denominator sign is normalized onto the numerator.
    try helpers.expectString(try r.eval("(display-to-string (/ 1 -3))"), "-1/3");
    // Exact comparison, including ratio vs integer.
    try helpers.expectTrue(try r.eval("(< 1/3 1/2)"));
    try helpers.expectTrue(try r.eval("(= 1/2 2/4)"));
    try helpers.expectTrue(try r.eval("(> 3/2 1)"));
    // numerator / denominator (prims).
    try helpers.expectInt(try r.eval("(numerator 3/4)"), 3);
    try helpers.expectInt(try r.eval("(denominator 3/4)"), 4);
    try helpers.expectInt(try r.eval("(denominator 5)"), 1);
    // eqv?/equal? by value; number->string / string->number round-trip.
    try helpers.expectTrue(try r.eval("(eqv? 1/2 2/4)"));
    try helpers.expectString(try r.eval("(number->string 3/4)"), "3/4");
    try helpers.expectString(try r.eval("(display-to-string (string->number \"3/4\"))"), "3/4");
    // A big-numerator ratio stays exact (numerator is a bignum literal).
    try helpers.expectString(try r.eval("(display-to-string (/ 1000000000000000000000000000000 7))"), "1000000000000000000000000000000/7");
}

test "ratio: predicates, conversions, and negative exponents" {
    const r = try Rig.initWithPrelude(alloc); // exact?/rational?/expt
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(exact? 1/3)"));
    try helpers.expectFalse(try r.eval("(inexact? 1/3)"));
    try helpers.expectTrue(try r.eval("(rational? 1/3)"));
    try helpers.expectTrue(try r.eval("(rational? 2.5)"));
    try helpers.expectTrue(try r.eval("(number? 1/3)"));
    try helpers.expectFalse(try r.eval("(integer? 1/3)"));
    // exact <-> inexact.
    try helpers.expectString(try r.eval("(display-to-string (exact->inexact 1/4))"), "0.25");
    try helpers.expectString(try r.eval("(display-to-string (inexact->exact 0.5))"), "1/2");
    // A negative exponent is an exact reciprocal.
    try helpers.expectString(try r.eval("(display-to-string (expt 2 -3))"), "1/8");
    try helpers.expectString(try r.eval("(display-to-string (expt 1/2 3))"), "1/8");
}

test "ratio: reader literals (#e decimals, #i), rounding" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // #e on a decimal is its EXACT value as written (#e0.1 is 1/10, not the float).
    try helpers.expectString(try r.eval("(display-to-string #e0.1)"), "1/10");
    try helpers.expectString(try r.eval("(display-to-string #e1.5)"), "3/2");
    try helpers.expectString(try r.eval("(display-to-string #e2.75)"), "11/4");
    try helpers.expectInt(try r.eval("#e1.5e2"), 150);
    try helpers.expectTrue(try r.eval("(= 1/10 #e0.1)")); // proves exact-decimal value
    // #e/#i on a rational literal.
    try helpers.expectString(try r.eval("(display-to-string #e1/2)"), "1/2");
    try helpers.expectString(try r.eval("(display-to-string #i1/2)"), "0.5");
    // floor/ceiling/truncate/round of a ratio (round is half-to-even).
    try helpers.expectInt(try r.eval("(floor 7/2)"), 3);
    try helpers.expectInt(try r.eval("(ceiling 7/2)"), 4);
    try helpers.expectInt(try r.eval("(truncate -7/2)"), -3);
    try helpers.expectInt(try r.eval("(floor -7/2)"), -4);
    try helpers.expectInt(try r.eval("(round 7/2)"), 4); // 3.5 -> 4 (even)
    try helpers.expectInt(try r.eval("(round 5/2)"), 2); // 2.5 -> 2 (even)
    try helpers.expectString(try r.eval("(display-to-string (abs -3/4))"), "3/4");
}

// zepo-7gpd: (cond (test => proc) ...) evaluates test once and, if truthy,
// applies proc to the test VALUE. The receiver closes over enclosing bindings.
test "cond: => clause applies the receiver to the truthy test value" {
    const r = try Rig.initWithPrelude(alloc); // uses assv/memv
    defer r.deinit();
    try helpers.expectInt(try r.eval("(cond ((assv 2 (list (cons 1 10) (cons 2 20))) => cdr) (else 0))"), 20);
    try helpers.expectInt(try r.eval("(cond ((assv 9 (list (cons 1 10))) => cdr) (else -1))"), -1);
    // The receiver sees the test value (evaluated once), not a re-test.
    try helpers.expectInt(try r.eval("(cond ((+ 3 4) => (lambda (x) (* x 2))))"), 14);
    // Multiple => clauses; the first truthy one wins.
    try helpers.expectInt(try r.eval("(cond (#f => car) (5 => (lambda (x) (* x x))))"), 25);
    // The receiver is a closure over enclosing bindings.
    try helpers.expectInt(try r.eval("(let ((y 100)) (cond (5 => (lambda (t) (+ t y)))))"), 105);
    // A => guard inside a tail-recursive named let.
    try helpers.expectInt(try r.eval("(let loop ((n 3) (acc 0)) (cond ((= n 0) => (lambda (t) acc)) (else (loop (- n 1) (+ acc n)))))"), 6);
    // => coexists with ordinary clauses.
    try helpers.expectInt(try r.eval("(cond (#f 1) ((memv 2 (quote (1 2 3))) => car) (else 9))"), 2);
    // Plain cond is unchanged (regression guard).
    try helpers.expectInt(try r.eval("(cond (#f 1) (else 2))"), 2);
    try helpers.expectInt(try r.eval("(cond (42))"), 42);
}

// zepo-ify4: a compile that fails partway (here register exhaustion — zepo-vx61)
// must roll back program state so a REPL-style reused context is NOT poisoned:
// the next form must compile and run normally.
test "eval: a failed compile does not poison the next form in a reused context" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // A deeply-nested let overflows the 255 physical-register file (IR slots are
    // never reclaimed), so compiling it fails with error.TooManyRegisters.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const N: usize = 400;
    try buf.appendSlice(alloc, "(let ((v0 0)) ");
    var i: usize = 1;
    while (i < N) : (i += 1) {
        var line: [64]u8 = undefined;
        try buf.appendSlice(alloc, try std.fmt.bufPrint(&line, "(let ((v{d} (+ v{d} 1))) ", .{ i, i - 1 }));
    }
    try buf.appendSlice(alloc, "v399");
    i = 0;
    while (i < N) : (i += 1) try buf.appendSlice(alloc, ")");

    try std.testing.expectError(error.TooManyRegisters, r.eval(buf.items));
    // The context is not poisoned — subsequent forms compile and run.
    try helpers.expectInt(try r.eval("(+ 1 2)"), 3);
    try helpers.expectInt(try r.eval("(let ((a 10) (b 20)) (+ a b))"), 30);
    // And a second over-limit form still errors gracefully (not a stale re-error
    // from the first) and again leaves the context usable.
    try std.testing.expectError(error.TooManyRegisters, r.eval(buf.items));
    try helpers.expectInt(try r.eval("(* 6 7)"), 42);
}

// zepo-gwj5: current-output-port / current-input-port are dynamic parameters;
// with-output-to-string / with-input-from-string capture I/O by rebinding them.
test "ports: with-output-to-string and with-input-from-string parameterize I/O" {
    const r = try Rig.initWithPrelude(alloc); // parameterize + string ports
    defer r.deinit();
    // display/write/newline with no port route to the current output port.
    try helpers.expectString(
        try r.eval("(with-output-to-string (lambda () (display \"x=\") (write 42) (newline) (display 'sym)))"),
        "x=42\nsym",
    );
    // write-char / write-string emit raw characters/strings (no #\\ or quotes).
    try helpers.expectString(
        try r.eval("(with-output-to-string (lambda () (write-string \"raw\") (write-char #\\!)))"),
        "raw!",
    );
    // Nested captures restore the outer port (parameterize unwinds).
    try helpers.expectString(
        try r.eval("(with-output-to-string (lambda () (display (with-output-to-string (lambda () (display \"in\")))) (display \"-out\")))"),
        "in-out",
    );
    // An explicit port argument overrides the current port.
    try helpers.expectString(
        try r.eval("(define p (open-output-string)) (write '(1 2) p) (display \"!\" p) (get-output-string p)"),
        "(1 2)!",
    );
    // Input side: read-char / peek-char / read-line draw from the current input.
    try helpers.expectString(
        try r.eval("(with-input-from-string \"ab\" (lambda () (list->string (list (read-char) (peek-char) (read-char)))))"),
        "abb",
    );
    try helpers.expectString(
        try r.eval("(with-input-from-string \"line one\\nline two\" (lambda () (read-line)))"),
        "line one",
    );
    try helpers.expectTrue(try r.eval("(with-input-from-string \"\" (lambda () (eof-object? (read-char))))"));
    try helpers.expectTrue(try r.eval("(output-port? (open-output-string))"));
}

// zepo-1meg: mutable byte-strings. make-string / string-copy produce mutable
// strings; string-set! / string-fill! mutate them in place (byte-indexed, like
// string-ref). Immutable literals are rejected. Chars must fit one byte (0..255).
test "strings: make-string / string-copy are mutable; string-set!/-fill!" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // make-string with a fill, then mutate.
    try helpers.expectString(try r.eval("(make-string 3 #\\x)"), "xxx");
    try helpers.expectString(try r.eval("(define s (make-string 3 #\\a)) (string-set! s 1 #\\Z) s"), "aZa");
    try helpers.expectInt(try r.eval("(string-length (make-string 5))"), 5);
    // string-copy makes a mutable copy of a literal; the literal is unchanged.
    try helpers.expectString(try r.eval("(define c (string-copy \"hello\")) (string-set! c 0 #\\H) c"), "Hello");
    try helpers.expectString(try r.eval("(string-copy \"abcdef\" 2 5)"), "cde");
    // string-fill! over a range.
    try helpers.expectString(try r.eval("(define f (make-string 4 #\\-)) (string-fill! f #\\* 1 3) f"), "-**-");
    // A mutable string is still a string, equal? / string=? compare by content.
    try helpers.expectTrue(try r.eval("(string? (make-string 2))"));
    try helpers.expectTrue(try r.eval("(equal? (make-string 3 #\\a) \"aaa\")"));
    // Mutating an immutable literal is an error.
    try std.testing.expectError(error.ContractViolation, r.eval("(string-set! \"lit\" 0 #\\X)"));
    // A char wider than one byte does not fit zepo's byte strings.
    try std.testing.expectError(error.ContractViolation, r.eval("(string-set! (make-string 1) 0 (integer->char 300))"));
}

// zepo-vhh6: #u8(...) bytevector literals + #N=/#N# datum labels.
test "reader: #u8 bytevector literals" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectString(try r.eval("(display-to-string '#u8(1 2 3 255))"), "#u8(1 2 3 255)");
    try helpers.expectTrue(try r.eval("(bytevector? '#u8(1 2 3))"));
    try helpers.expectInt(try r.eval("(bytevector-length '#u8(10 20 30))"), 3);
    try helpers.expectInt(try r.eval("(bytevector-u8-ref '#u8(5 6 7) 1)"), 6);
    try helpers.expectString(try r.eval("(display-to-string '#u8())"), "#u8()");
    // Elements may use radix prefixes; a value > 255 is rejected.
    try helpers.expectInt(try r.eval("(bytevector-u8-ref '#u8(#xff #x10) 0)"), 255);
    try std.testing.expectError(error.InvalidNumber, r.eval("'#u8(1 300)"));
}

test "reader: #N= / #N# datum labels (shared and cyclic)" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // Cyclic pair: the cdr is the pair itself.
    try helpers.expectTrue(try r.eval("(define x '#0=(a . #0#)) (and (eq? (car x) 'a) (eq? x (cdr x)))"));
    // Shared structure: both list elements are the same object.
    try helpers.expectTrue(try r.eval("(define l '(#0=(x y) #0#)) (eq? (car l) (car (cdr l)))"));
    // A label with no self-reference is just a plain (shared-able) datum.
    try helpers.expectInt(try r.eval("(car (cdr (cdr '#1=(1 2 3))))"), 3);
    // Cyclic vector: element 1 is the vector itself.
    try helpers.expectTrue(try r.eval("(define v '#0=#(1 #0# 3)) (eq? v (vector-ref v 1))"));
    // Multi-digit labels work.
    try helpers.expectTrue(try r.eval("(define y '#42=(z . #42#)) (eq? y (cdr y))"));
    // An undefined back-reference is an error.
    try std.testing.expectError(error.InvalidNumber, r.eval("'#9#"));
}

// zepo-aqwc: #(...) vector literals self-evaluate; equal? recurses into vectors;
// quasiquote walks vector templates; #; comments out a datum.
test "reader: vector literals self-evaluate and compare with equal?" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(vector-ref #(10 20 30) 1)"), 20);
    try helpers.expectInt(try r.eval("(vector-length #(a b c d))"), 4);
    try helpers.expectTrue(try r.eval("(vector? #(1 2))"));
    // equal? recurses into vectors (same length + elementwise).
    try helpers.expectTrue(try r.eval("(equal? #(1 2 3) (vector 1 2 3))"));
    try helpers.expectTrue(try r.eval("(equal? #(1 #(2 3)) #(1 #(2 3)))"));
    try helpers.expectFalse(try r.eval("(equal? #(1 2) #(1 2 3))"));
    // A vector literal is mutable.
    try helpers.expectString(try r.eval("(define v #(9 8 7)) (vector-set! v 0 'X) (display-to-string v)"), "#(X 8 7)");
    // #; comments out the next datum. (car (cdr (list 1 #;2 3))) == 3 → the
    // middle element 2 was dropped, so the list is (1 3). Prim-only, no stdlib.
    try helpers.expectInt(try r.eval("(car (cdr (list 1 #;2 3)))"), 3);
    try helpers.expectInt(try r.eval("(+ 1 #;(* 100 100) 2)"), 3);
    try helpers.expectInt(try r.eval("(vector-length #(1 #;2 3))"), 2);
}

test "reader: quasiquote walks vector templates" {
    const r = try Rig.initWithPrelude(alloc); // needs list->vector
    defer r.deinit();
    try helpers.expectString(try r.eval("(define x 99) (display-to-string `#(1 ,x 3))"), "#(1 99 3)");
    try helpers.expectString(try r.eval("(display-to-string `#(1 ,@(list 2 3) 4))"), "#(1 2 3 4)");
    try helpers.expectString(try r.eval("(display-to-string `#(0 #(1 ,x) 2))"), "#(0 #(1 99) 2)");
}

// zepo-asu1: mutable pairs — set-car!/set-cdr! (write-barrier'd) + list-set!,
// and the cyclic structures they make constructible must still render (bounded).
test "pairs: set-car! / set-cdr! mutate in place" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(define p (cons 1 2)) (set-car! p 10) (car p)"), 10);
    try helpers.expectInt(try r.eval("(set-cdr! p 20) (cdr p)"), 20);
    // A returned value that is itself mutated.
    try helpers.expectInt(try r.eval("(define q (cons 0 0)) (set-car! q (cons 7 8)) (car (car q))"), 7);
    // set-car!/set-cdr! on a non-pair is a type error.
    try std.testing.expectError(error.TypeError, r.eval("(set-car! 5 1)"));
    try std.testing.expectError(error.TypeError, r.eval("(set-cdr! 'x 1)"));
}

test "pairs: list-set! mutates the k-th element" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(define l (list 'a 'b 'c 'd)) (list-set! l 2 'X) (display-to-string l)"),
        "(a b X d)",
    );
}

test "pairs: cyclic list display/write terminate with a bounded marker" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // A 3-element spine made circular — Floyd cycle detection bounds the output.
    try helpers.expectString(
        try r.eval("(define c (cons 1 (cons 2 (cons 3 (quote ()))))) (set-cdr! (cdr (cdr c)) c) (display-to-string c)"),
        "(1 2 3 1 2 ...)",
    );
    // A self-referential pair.
    try helpers.expectString(
        try r.eval("(define s (cons 1 2)) (set-cdr! s s) (display-to-string s)"),
        "(1 ...)",
    );
}

// zepo-vx61: IR register slots are never reclaimed, so a function with enough
// sequential lets exceeds the byte-sized physical register file. That must fail
// with a graceful error.TooManyRegisters — NOT a "reached unreachable" panic
// (Debug) or silent register-aliasing UB (ReleaseFast). Without the fix this
// test would crash the test runner via the panic.
test "codegen: register exhaustion returns TooManyRegisters, not a panic" {
    const r = try Rig.init(alloc);
    defer r.deinit();

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var numbuf: [24]u8 = undefined;
    const N: usize = 400;
    try buf.appendSlice(alloc, "(define (big)\n");
    var i: usize = 0;
    while (i < N) : (i += 1) {
        if (i == 0) {
            try buf.appendSlice(alloc, "(let ((v0 0))\n");
        } else {
            try buf.appendSlice(alloc, "(let ((v");
            try buf.appendSlice(alloc, try std.fmt.bufPrint(&numbuf, "{d}", .{i}));
            try buf.appendSlice(alloc, " (+ v");
            try buf.appendSlice(alloc, try std.fmt.bufPrint(&numbuf, "{d}", .{i - 1}));
            try buf.appendSlice(alloc, " 1)))\n");
        }
    }
    try buf.appendSlice(alloc, "v");
    try buf.appendSlice(alloc, try std.fmt.bufPrint(&numbuf, "{d}", .{N - 1}));
    i = 0;
    while (i < N) : (i += 1) try buf.append(alloc, ')');
    try buf.append(alloc, ')');

    try std.testing.expectError(error.TooManyRegisters, r.eval(buf.items));
}

// Sanity: a modest nested let is well under the register limit and compiles.
// (Fresh Rig — a failed over-limit compile does not yet cleanly roll back the
// shared program state; recoverability is tracked separately.)
test "codegen: modest nested lets compile and run" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(let ((a 1)) (let ((b (+ a 1))) (let ((c (+ b 1))) c)))"), 3);
}

// zepo-mqvc: inexact division by zero produces ±inf.0/+nan.0 (R7RS/IEEE);
// exact (fixnum) division by zero remains an error.
test "prims: inexact division by zero yields inf/nan, exact stays an error" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // Inexact zero divisor → non-finite result.
    try helpers.expectString(try r.eval("(display-to-string (/ 1.0 0.0))"), "+inf.0");
    try helpers.expectString(try r.eval("(display-to-string (/ -1.0 0.0))"), "-inf.0");
    try helpers.expectString(try r.eval("(display-to-string (/ 0.0 0.0))"), "+nan.0");
    // Reciprocal form: (/ z) = (/ 1 z).
    try helpers.expectString(try r.eval("(display-to-string (/ 0.0))"), "+inf.0");
    // Mixed but inexact result, exact zero divisor → still an error.
    try std.testing.expectError(error.DivisionByZero, r.eval("(/ 1.0 0)"));
    // All-exact division by zero → error.
    try std.testing.expectError(error.DivisionByZero, r.eval("(/ 1 0)"));
    try std.testing.expectError(error.DivisionByZero, r.eval("(/ 0)"));
}

test "prims: json-stringify errors on non-finite floats" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // finite floats are valid JSON
    try helpers.expectString(try r.eval("(display-to-string (json-stringify 1.5))"), "(ok . 1.5)");
    // NaN/Infinity have no JSON form → an (err ...) result, not invalid JSON
    try helpers.expectString(try r.eval("(display-to-string (car (json-stringify (prim-inf))))"), "err");
}

// zepo-wijk: a large-negative epoch yields a negative year; formatting it used
// to panic on @intCast to u64.
test "prims: time-format handles negative years without panicking" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // must not panic; negative year prints with a leading '-'
    try helpers.expectString(try r.eval("(time-format -100000000000000 \"%Y\")"), "-1199");
    // ordinary dates are unchanged (no stray '+' on the positive year)
    try helpers.expectString(try r.eval("(time-format 1700000000 \"%Y-%m-%d\")"), "1970-01-20");
}

test "prims: comparison operators" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(< 1 2)"));
    try helpers.expectFalse(try r.eval("(> 1 2)"));
    try helpers.expectTrue(try r.eval("(<= 2 2)"));
    try helpers.expectTrue(try r.eval("(>= 3 2)"));
    try helpers.expectTrue(try r.eval("(= 5 5)"));
}

test "prims: not" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(not #f)"));
    try helpers.expectFalse(try r.eval("(not #t)"));
    try helpers.expectFalse(try r.eval("(not 0)"));
}

test "prims: apply" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(apply + '(1 2 3))"), 6);
    try helpers.expectInt(try r.eval("(apply + 1 2 '(3 4))"), 10);
}

test "prims: type predicates" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(pair? (cons 1 2))"));
    try helpers.expectTrue(try r.eval("(null? '())"));
    try helpers.expectTrue(try r.eval("(boolean? #t)"));
    try helpers.expectTrue(try r.eval("(number? 42)"));
    try helpers.expectTrue(try r.eval("(integer? 42)"));
    try helpers.expectTrue(try r.eval("(float? 3.14)"));
    try helpers.expectTrue(try r.eval("(char? #\\a)"));
    try helpers.expectTrue(try r.eval("(string? \"hi\")"));
    try helpers.expectTrue(try r.eval("(symbol? 'foo)"));
    try helpers.expectTrue(try r.eval("(procedure? car)"));
}

test "prims: cons/car/cdr" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(car (cons 1 2))"), 1);
    try helpers.expectInt(try r.eval("(cdr (cons 1 2))"), 2);
}

test "prims: list builtin" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(list 10 20 30)");
    try std.testing.expect(helpers.objects.isPair(v));
    try helpers.expectInt(helpers.objects.pairCar(v).*, 10);
}

test "prims: prelude length/map/filter" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(length '(1 2 3 4 5))"), 5);
    try helpers.expectInt(try r.eval("(car (map (lambda (x) (* x x)) '(1 2 3)))"), 1);
    try helpers.expectInt(try r.eval("(car (cdr (map (lambda (x) (* x x)) '(1 2 3))))"), 4);
}

test "prims: prelude fold/append/reverse" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(fold-left + 0 '(1 2 3 4 5))"), 15);
    try helpers.expectInt(try r.eval("(length (append '(1 2) '(3 4 5)))"), 5);
    try helpers.expectInt(try r.eval("(car (reverse '(1 2 3)))"), 3);
}

test "prims: string primitives" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(string-length \"hello\")"), 5);
    const v = try r.eval("(string-append \"foo\" \"bar\")");
    try std.testing.expect(helpers.objects.isString(v));
    try std.testing.expectEqualStrings("foobar", helpers.objects.stringBytes(v));
}

// ── keyword symbols ───────────────────────────────────────────────────────────

test "keywords: self-evaluating" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval(":foo");
    const expected = try r.eval("(quote :foo)");
    try std.testing.expectEqual(expected, v);
}

test "keywords: two distinct keywords are not equal" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectFalse(try r.eval("(equal? :foo :bar)"));
}

test "keywords: same keyword is equal to itself" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(equal? :key :key)"));
}

test "keywords: usable as plist keys" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(let ((pl (list :x 1 :y 2)))
        \\  (plist-get pl :x))
    );
    try helpers.expectInt(v, 1);
}

// ── display-to-string / write-to-string ──────────────────────────────────────

test "display-to-string: integer" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(display-to-string 42)");
    try helpers.expectString(v, "42");
}

test "display-to-string: string (no quotes)" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(display-to-string \"hello\")");
    try helpers.expectString(v, "hello");
}

test "display-to-string: bool" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectString(try r.eval("(display-to-string #t)"), "#t");
    try helpers.expectString(try r.eval("(display-to-string #f)"), "#f");
}

test "display-to-string: list" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval("(display-to-string (list 1 2 3))");
    try helpers.expectString(v, "(1 2 3)");
}

test "write-to-string: string has quotes" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(write-to-string \"hello\")");
    try helpers.expectString(v, "\"hello\"");
}

test "write-to-string: symbol" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(write-to-string (quote foo))");
    try helpers.expectString(v, "foo");
}

// ── string utilities ──────────────────────────────────────────────────────────

test "string-replace: replaces all occurrences" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(string-replace \"hello world hello\" \"hello\" \"hi\")"),
        "hi world hi");
}

test "string-replace: no match returns original" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(string-replace \"abc\" \"x\" \"y\")"), "abc");
}

test "string-pad-left: pads to width" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(string-pad-left \"42\" 5 #\\0)"), "00042");
}

test "string-pad-right: pads to width" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(string-pad-right \"hi\" 5 #\\-)"), "hi---");
}

test "string-repeat: repeats n times" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(string-repeat \"ab\" 3)"), "ababab");
}

test "string-prefix?: true and false" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(string-prefix? \"hel\" \"hello\")"));
    try helpers.expectFalse(try r.eval("(string-prefix? \"world\" \"hello\")"));
}

test "string-suffix?: true and false" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectTrue(try r.eval("(string-suffix? \"llo\" \"hello\")"));
    try helpers.expectFalse(try r.eval("(string-suffix? \"hel\" \"hello\")"));
}

test "string-index: found and not found" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    try helpers.expectInt(try r.eval("(string-index \"hello\" #\\l)"), 2);
    try helpers.expectFalse(try r.eval("(string-index \"hello\" #\\z)"));
}

// ── date/time ─────────────────────────────────────────────────────────────────

test "current-time-ms: returns positive integer" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const v = try r.eval("(current-time-ms)");
    if (!helpers.value_mod.isFixnum(v)) return error.TestExpectedFixnum;
    try std.testing.expect(helpers.value_mod.fixnumVal(v) > 0);
}

test "epoch->date: known epoch" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    // 2001-09-09 01:46:40 UTC = 1000000000 seconds = 1000000000000 ms
    _ = try r.eval("(define d (epoch->date 1000000000000))");
    try helpers.expectInt(try r.eval("(cdr (assoc (quote year) d))"), 2001);
    try helpers.expectInt(try r.eval("(cdr (assoc (quote month) d))"), 9);
    try helpers.expectInt(try r.eval("(cdr (assoc (quote day) d))"), 9);
}

test "date->epoch: round-trips with epoch->date" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const ms: i63 = 1000000000000;
    _ = try r.eval("(define d (epoch->date 1000000000000))");
    const v = try r.eval(
        \\(date->epoch
        \\  (cdr (assoc (quote year)   d))
        \\  (cdr (assoc (quote month)  d))
        \\  (cdr (assoc (quote day)    d))
        \\  (cdr (assoc (quote hour)   d))
        \\  (cdr (assoc (quote minute) d))
        \\  (cdr (assoc (quote second) d)))
    );
    try helpers.expectInt(v, ms);
}

test "time-format: formats known epoch" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try helpers.expectString(
        try r.eval("(time-format 1000000000000 \"%Y-%m-%d\")"),
        "2001-09-09");
}
