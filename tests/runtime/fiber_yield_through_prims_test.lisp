;; zepo-gjwb: regression for the bug class described in ADR 0002.
;;
;; Before zepo-mi9x landed, every assertion in this file failed with
;; "unbound variable" because the closure's eventual return value never
;; landed in the outer (define VAR ...) target register. The fix in
;; src/vm/dispatch.zig PRIM_CALL handler now repoints the closure frame's
;; dst_reg before parking the fiber, so on resume the value flows
;; correctly to the caller's expected location.

(define (must-equal expected actual label)
  (if (not (equal? expected actual))
      (error (string-append label ": expected "
                            (write-to-string expected)
                            " got " (write-to-string actual)))))

;; ── Scenario 1: bare apply with a sleeping closure ──────────────────
(define s1 (apply (lambda () (sleep 0.01) 42) '()))
(must-equal 42 s1 "scenario 1 (apply + sleep)")
(display "1 OK ") (display s1) (newline)

;; ── Scenario 2: with-exception-handler wrapping a sleeping thunk ────
(define s2 (with-exception-handler
             (lambda (e) 'caught-err)
             (lambda () (sleep 0.01) 'thunk-value)))
(must-equal 'thunk-value s2 "scenario 2 (handler + sleep)")
(display "2 OK ") (display s2) (newline)

;; ── Scenario 3: handler catches an error raised after sleep ─────────
(define s3 (with-exception-handler
             (lambda (e) 'caught-after-sleep)
             (lambda () (sleep 0.01) (error "boom"))))
(must-equal 'caught-after-sleep s3 "scenario 3 (handler + sleep + error)")
(display "3 OK ") (display s3) (newline)

;; ── Scenario 4: for-each (which uses apply internally) over a list,
;;    each step sleeping. The accumulator should reflect every iteration.
(define acc 0)
(for-each (lambda (n) (sleep 0.005) (set! acc (+ acc n))) (list 1 2 3 4))
(must-equal 10 acc "scenario 4 (for-each + sleep)")
(display "4 OK ") (display acc) (newline)

;; ── Scenario 5: nested handlers around sleep — make sure intermediate
;;    layers chain correctly.
(define s5 (with-exception-handler
             (lambda (e) 'outer-caught)
             (lambda ()
               (with-exception-handler
                 (lambda (e) 'inner-caught)
                 (lambda () (sleep 0.01) (error "inner-boom"))))))
(must-equal 'inner-caught s5 "scenario 5 (nested handlers + sleep + error)")
(display "5 OK ") (display s5) (newline)

(display "ewdc / mi9x regression OK") (newline)
