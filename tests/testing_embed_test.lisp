;; zepo-fqws: the embeddable runner. run! returns a result record without
;; calling exit, even on failure. run!/exit exits 1 on failure (for use at
;; the bottom of a test file).

(import testing
  (describe it deftest is
   run! result-passed result-failed result-total result-failures result-duration-ms
   clear-tests!))

;; ── Set up a small suite with a known mix of pass/fail ─────────────────
(describe "embed-target"
  (it "first passes"      (is #t))
  (it "second passes"     (is #t))
  (it "third fails"       (is #f))
  (it "fourth passes"     (is (= 1 1)))
  (it "fifth fails again" (error "intentional")))

;; ── Drive it silently and inspect the returned record ─────────────────
(define r (run! :silent #t))

(if (not (= (result-passed r) 3))
    (error "expected 3 passed, got" (result-passed r)))
(if (not (= (result-failed r) 2))
    (error "expected 2 failed, got" (result-failed r)))
(if (not (= (result-total r) 5))
    (error "expected 5 total, got" (result-total r)))
(if (not (>= (result-duration-ms r) 0))
    (error "expected non-negative duration"))
(if (not (= (length (result-failures r)) 2))
    (error "expected 2 failure entries, got" (length (result-failures r))))

;; ── Process should still be running — print proof. ─────────────────────
(display "embeddable run! returned a record without exiting: ")
(display "passed=") (display (result-passed r))
(display " failed=") (display (result-failed r))
(display " duration=") (display (result-duration-ms r)) (display "ms")
(newline)
(display "embed test OK") (newline)
