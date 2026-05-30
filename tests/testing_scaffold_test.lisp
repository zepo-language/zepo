;; zepo-mx0p: scaffold for the testing framework. Self-hosting check —
;; uses the new framework to test itself.
(import testing (describe it deftest is run-tests clear-tests!))

;; ── Group A: describe blocks nest and tests inherit their path ───────────
(describe "scaffold"
  (describe "describe"
    (it "executes the body forms in order"
      (define counter 0)
      (begin
        (set! counter (+ counter 1))
        (set! counter (+ counter 10))
        (is (= counter 11))))
    (it "permits arbitrarily deep nesting"
      (is #t)))
  (describe "it"
    (it "registers a thunk that runs later"
      (is #t))))

;; ── Group B: deftest is a flat shortcut ──────────────────────────────────
(deftest "deftest at the top level works without describe"
  (is (= 42 42)))

;; ── Run and verify counts ────────────────────────────────────────────────
(define result (run-tests))
(define passed (car result))
(define failed (cdr result))

(if (not (= passed 4))
    (error "scaffold smoke: expected 4 passed, got" passed))
(if (not (= failed 0))
    (error "scaffold smoke: expected 0 failed, got" failed))

(display "scaffold smoke OK") (newline)
