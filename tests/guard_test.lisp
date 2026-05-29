;; zepo-y1a4: selective imports.
(import test (deftest is =check throws run-tests))

; ── error-object? predicate ───────────────────────────────────────────────────

(deftest error-object?/true-for-error
  (with-exception-handler
    (lambda (e) (is (error-object? e)))
    (lambda () (error "test"))))

(deftest error-object?/false-for-raise
  (with-exception-handler
    (lambda (e) (is (not (error-object? e))))
    (lambda () (raise 42))))

(deftest error-object?/false-for-string
  (is (not (error-object? "plain string"))))

; ── error-object-message ─────────────────────────────────────────────────────

(deftest error-object-message/basic
  (with-exception-handler
    (lambda (e) (=check (error-object-message e) "something failed"))
    (lambda () (error "something failed"))))

; ── error-object-irritants ────────────────────────────────────────────────────

(deftest error-object-irritants/none
  (with-exception-handler
    (lambda (e) (=check (error-object-irritants e) '()))
    (lambda () (error "msg"))))

(deftest error-object-irritants/single
  (with-exception-handler
    (lambda (e) (=check (error-object-irritants e) '(42)))
    (lambda () (error "msg" 42))))

(deftest error-object-irritants/multiple
  (with-exception-handler
    (lambda (e) (=check (error-object-irritants e) '(1 2 3)))
    (lambda () (error "msg" 1 2 3))))

; ── raise ─────────────────────────────────────────────────────────────────────

(deftest raise/any-value
  (with-exception-handler
    (lambda (e) (=check e 99))
    (lambda () (raise 99))))

(deftest raise/list-value
  (with-exception-handler
    (lambda (e) (=check e '(a b c)))
    (lambda () (raise '(a b c)))))

; ── guard: basic clause matching ─────────────────────────────────────────────

(deftest guard/catches-error-object
  (=check
    (guard (exn
      ((error-object? exn) (error-object-message exn)))
      (error "caught!"))
    "caught!"))

(deftest guard/else-clause
  (=check
    (guard (exn
      ((equal? exn 'specific) "specific match")
      (else "fallback"))
      (raise 'other))
    "fallback"))

(deftest guard/first-matching-clause-wins
  (=check
    (guard (exn
      ((number? exn) "number")
      ((string? exn) "string")
      (else "other"))
      (raise 42))
    "number"))

; ── guard: no exception ───────────────────────────────────────────────────────

(deftest guard/no-exception-returns-body-value
  (=check (guard (exn (#t "error")) (+ 1 2)) 3))

(deftest guard/no-exception-last-body-form
  (=check
    (guard (exn (#t 0))
      (define x 10)
      (+ x 5))
    15))

; ── guard: re-raise when no clause matches ────────────────────────────────────

(deftest guard/reraise-when-no-match
  ; Inner guard does not match 'other — re-raises to outer guard.
  (=check
    (guard (outer (#t "outer-caught"))
      (guard (inner
        ((equal? inner 'specific) "matched"))
        (raise 'other)))
    "outer-caught"))

; ── guard: nested exception handling ─────────────────────────────────────────

(deftest guard/nested-handlers
  (=check
    (guard (outer
      ((error-object? outer)
       (string-append "outer: " (error-object-message outer))))
      (guard (inner
        ((equal? (error-object-message inner) "inner-error")
         (error "rethrown-as-new")))
        (error "inner-error")))
    "outer: rethrown-as-new"))

; ── throws helper ─────────────────────────────────────────────────────────────

(deftest throws/detects-error
  (throws (error "should be caught")))

(deftest throws/detects-raise
  (throws (raise 'anything)))

(deftest throws/passes-when-no-error
  ; This test itself should PASS — the body does NOT throw.
  (is (equal? (+ 1 1) 2)))

(run-tests)
