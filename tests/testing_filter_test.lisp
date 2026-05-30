;; zepo-nqfu: filter by name pattern and tag.

(import testing
  (describe it tag is
   run! result-passed result-failed result-skipped result-total
   clear-tests!))

;; ── Phase 1: tag attaches to the next test only ─────────────────────────
(describe "alpha"
  (it "fast-one" (is #t))
  (tag 'slow)
  (it "slow-one" (is #t))
  (tag 'integration)
  (it "integ-one" (is #t)))

;; No filter — all three run.
(define r0 (run! :silent #t))
(if (not (= (result-passed r0) 3)) (error "phase0 expected 3 passed, got" (result-passed r0)))
(display "phase 0 (no filter) OK") (newline)

;; :tags '(slow) — only the slow test runs.
(define r1 (run! :silent #t :tags '(slow)))
(if (not (= (result-passed r1) 1)) (error "phase1 expected 1 passed, got" (result-passed r1)))
(display "phase 1 (:tags slow) OK") (newline)

;; :exclude-tags '(slow integration) — only the untagged test runs.
(define r2 (run! :silent #t :exclude-tags '(slow integration)))
(if (not (= (result-passed r2) 1)) (error "phase2 expected 1 passed, got" (result-passed r2)))
(display "phase 2 (:exclude-tags slow integration) OK") (newline)

;; ── Phase 3: name-pattern filter ────────────────────────────────────────
(clear-tests!)
(describe "math"
  (describe "stats"
    (it "mean of empty errors" (is #t))
    (it "median of 5" (is #t)))
  (describe "tensor"
    (it "transpose swaps axes" (is #t))))

;; :filter "tensor" — only the tensor test matches (substring match).
(define r3 (run! :silent #t :filter "tensor"))
(if (not (= (result-passed r3) 1)) (error "phase3 expected 1 passed, got" (result-passed r3)))
(display "phase 3 (:filter tensor) OK") (newline)

;; :filter "stats" — both stats tests match.
(define r4 (run! :silent #t :filter "stats"))
(if (not (= (result-passed r4) 2)) (error "phase4 expected 2 passed, got" (result-passed r4)))
(display "phase 4 (:filter stats) OK") (newline)

(display "filter OK") (newline)
