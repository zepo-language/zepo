# Testing in Zepo

Zepo has two complementary test layers:

- **Zig unit tests** (`tests/**/*.zig`) — low-level tests for GC, compiler, reader, FFI, and runtime internals. Run with `zig build test`.
- **Lisp integration tests** (`tests/**/*_test.lisp`) — higher-level tests for library code and language behavior. Run with `zepo test`.

This document covers writing Lisp tests. For the Zig layer, see the files under `tests/` directly.

---

## Running Tests

```sh
zepo test                        # discover and run all tests/**/*_test.lisp
zepo test tests/format_test.lisp # run a single file
```

`zepo test` exits 0 if all tests pass, 1 if any fail.

---

## The Test Library

Import `test` at the top of every test file:

```lisp
(import test)
```

### `deftest`

Defines a named test. The name is a symbol; the body is one or more expressions that run when the test executes. Any unhandled error (including a failed assertion) marks the test as failed.

```lisp
(deftest my-test
  (is (= 1 1)))
```

Names can use `/` to express hierarchy:

```lisp
(deftest string/append-empty
  (=check (string-append "" "x") "x"))
```

### `is`

Asserts that an expression is truthy. Fails with the expression text on `#f` or `'()`.

```lisp
(is (> 3 2))
(is (string? "hello"))
(is (null? '()))
```

### `=check`

Asserts that an expression equals an expected value using `equal?`. On failure, prints both the expected and actual values alongside the expression.

```lisp
(=check (+ 1 2) 3)
(=check (string-append "foo" "bar") "foobar")
(=check (map (lambda (x) (* x 2)) '(1 2 3)) '(2 4 6))
```

### `throws`

Asserts that an expression raises an exception. Fails if no exception is thrown.

```lisp
(throws (error "deliberate"))
(throws (car '()))
(throws (/ 1 0))
```

### `run-tests`

Runs all tests registered with `deftest` in the current file, prints a summary, and exits 1 on any failure. **Always call this at the end of every test file.**

```lisp
(run-tests)
```

To run only one test by name:

```lisp
(run-tests 'my-test)
```

### `run-tests/tap`

Same as `run-tests` but emits [TAP 14](https://testanything.org/) output. Useful for CI integrations that consume TAP.

```lisp
(run-tests/tap)
```

---

## Simple Example

```lisp
; tests/math_test.lisp
(import test)

(deftest add/basic
  (=check (+ 1 2) 3)
  (=check (+ 0 0) 0)
  (=check (+ -1 1) 0))

(deftest add/multiple-args
  (=check (+ 1 2 3 4) 10))

(deftest div/throws-on-zero
  (throws (/ 1 0)))

(run-tests)
```

Output:
```
PASS add/basic
PASS add/multiple-args
PASS div/throws-on-zero
Summary: 3 passed, 0 failed
```

---

## Complex Example — Testing with Exceptions

When testing code that uses exceptions, combine `guard`/`with-exception-handler`
with the test assertions:

```lisp
(import test)

(deftest error-object/structure
  ; error-object? is true for values created by (error ...)
  (with-exception-handler
    (lambda (e)
      (is (error-object? e))
      (=check (error-object-message e) "bad input")
      (=check (error-object-irritants e) '(42)))
    (lambda ()
      (error "bad input" 42))))

(deftest guard/catches-by-type
  ; guard clauses pattern-match on the exception value
  (=check
    (guard (exn
      ((error-object? exn) (error-object-message exn))
      (else "unknown"))
      (error "expected message"))
    "expected message"))

(deftest guard/reraises-unmatched
  ; when no clause matches, guard re-raises to the enclosing handler
  (=check
    (guard (outer (#t "outer-caught"))
      (guard (inner
        ((equal? inner 'specific) "matched"))
        (raise 'other-value)))
    "outer-caught"))

(run-tests)
```

---

## Test Isolation with `make-suite`

For libraries that want an isolated test suite (not sharing state with the
global registry), use `make-suite`:

```lisp
(import test)

(define suite (make-suite))
(define register! (car suite))
(define run!      (cdr suite))

(register! 'isolated-test
  (lambda ()
    (=check (+ 1 1) 2)))

(run!)
```

This is useful when a library wants to ship tests alongside its implementation
without polluting the global `deftest` registry.

---

## Reference Test Files

The following test files in `tests/` demonstrate real usage and serve as the
canonical examples for each feature:

| File | What it tests |
|------|--------------|
| [`tests/format_test.lisp`](../tests/format_test.lisp) | `(import format)` — all directives, edge cases, error cases |
| [`tests/guard_test.lisp`](../tests/guard_test.lisp) | `error`, `raise`, `guard`, `with-exception-handler`, condition predicates |

---

## Known Limitations

- The `throws` assertion does not distinguish between error types — it passes for any raised exception. Use `with-exception-handler` directly when you need to assert on the exception value.
