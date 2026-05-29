; lib/test.lisp
(module test
  (export
    deftest is =check throws
    run-tests run-tests/tap
    clear-tests! make-suite)

  (define *tests* '())
  (define *passed* 0)
  (define *failed* 0)

  (define (register-test name thunk)
    (set! *tests* (append *tests* (list (cons name thunk)))))

  (define (clear-tests!)
    (set! *tests* '())
    (set! *passed* 0)
    (set! *failed* 0))

  (define (fail msg)
    (error msg))

  (define (format-exception e)
    (if (error-object? e)
      (let ((msg (error-object-message e))
            (irritants (error-object-irritants e)))
        (if (null? irritants)
          msg
          (string-append msg " " (display-to-string irritants))))
      (display-to-string e)))

  (define (is-impl quoted-expr value)
    (if value
        'ok
        (fail (string-append "Assertion failed: " (display-to-string quoted-expr)))))

  (define (=check-impl quoted-expr expected actual)
    (if (equal? expected actual)
        'ok
        (fail (string-append
                "Expected "
                (write-to-string expected)
                ", got "
                (write-to-string actual)
                " in: "
                (display-to-string quoted-expr)))))

  (define (throws-impl quoted-expr thunk)
    (let ((raised? #f))
      (with-exception-handler
        (lambda (e)
          (set! raised? #t)
          '())
        (lambda ()
          (thunk)))
      (if raised?
          'ok
          (begin
            (display "Expected error but none thrown: ")
            (display quoted-expr)
            (newline)
            (fail "throws check failed")))))

  ;;; ── Macros ────────────────────────────────────────────────────────────────

  (defmacro deftest (name . body)
    `(begin
       (register-test ',name (lambda () ,@body))
       ',name))

  (defmacro is (expr)
    `(is-impl ',expr ,expr))

  (defmacro =check (expr expected)
    `(let ((actual ,expr))
       (=check-impl ',expr ,expected actual)))

  (defmacro throws (expr)
    `(throws-impl ',expr (lambda () ,expr)))

  ;;; ── Test runner ───────────────────────────────────────────────────────────

  (define (run-one-test name fn)
    (with-exception-handler
      (lambda (e)
        (set! *failed* (+ *failed* 1))
        (display "FAIL ") (display name)
        (display ": ")    (display (format-exception e))
        (newline))
      (lambda ()
        (fn)
        (set! *passed* (+ *passed* 1))
        (display "PASS ") (display name)
        (newline))))

  (define (run-tests . args)
    (set! *passed* 0)
    (set! *failed* 0)
    (let ((filter (if (null? args) #f (car args))))
      (for-each
        (lambda (pair)
          (let ((name (car pair)))
            (if (or (not filter) (equal? name filter))
                (run-one-test name (cdr pair)))))
        *tests*))
    (display "Summary: ")
    (display *passed*)
    (display " passed, ")
    (display *failed*)
    (display " failed")
    (newline)
    (if (> *failed* 0) (exit 1)))

  ;;; ── TAP output ────────────────────────────────────────────────────────────

  (define (run-tests/tap . args)
    (let ((name-filter (if (null? args) #f (car args))))
      (let ((suite (if name-filter
                       (let loop ((ts *tests*) (acc '()))
                         (if (null? ts) (reverse acc)
                             (loop (cdr ts)
                                   (if (equal? (car (car ts)) name-filter)
                                       (cons (car ts) acc)
                                       acc))))
                       *tests*)))
        (display "TAP version 14")
        (newline)
        (display "1..")
        (display (length suite))
        (newline)
        (let ((n 0)
              (failed 0))
          (for-each
            (lambda (pair)
              (set! n (+ n 1))
              (let ((name (car pair))
                    (fn   (cdr pair))
                    (ok?  #t)
                    (msg  #f))
                (with-exception-handler
                  (lambda (e)
                    (set! ok? #f)
                    (set! msg (format-exception e)))
                  (lambda () (fn)))
                (if ok?
                    (begin (display "ok ") (display n) (display " - ") (display name) (newline))
                    (begin
                      (display "not ok ") (display n) (display " - ") (display name) (newline)
                      (display "  # ") (display (format-exception msg)) (newline)
                      (set! failed (+ failed 1))))))
            suite)
          (if (> failed 0) (exit 1))))))

  ;;; ── Isolated suite ────────────────────────────────────────────────────────
  ;;; Returns a pair (register! . run!) for test isolation across files.
  ;;; Usage:
  ;;;   (define my-suite (make-suite))
  ;;;   ((car my-suite) 'my-test (lambda () ...))
  ;;;   ((cdr my-suite))

  (define (make-suite)
    (let ((tests '()))
      (cons
        (lambda (name thunk)
          (set! tests (append tests (list (cons name thunk)))))
        (lambda args
          (let ((filter (if (null? args) #f (car args)))
                (passed 0)
                (failed 0))
            (for-each
              (lambda (pair)
                (let ((name (car pair)))
                  (if (or (not filter) (equal? name filter))
                      (with-exception-handler
                        (lambda (e)
                          (set! failed (+ failed 1))
                          (display "FAIL ") (display name)
                          (display ": ")    (display (format-exception e)) (newline))
                        (lambda ()
                          ((cdr pair))
                          (set! passed (+ passed 1))
                          (display "PASS ") (display name) (newline))))))
              tests)
            (display "Summary: ") (display passed)
            (display " passed, ") (display failed) (display " failed") (newline)
            (if (> failed 0) (exit 1)))))))

)
