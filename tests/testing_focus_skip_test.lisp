;; zepo-s3zf: focus and skip modifiers.
;;
;; This file exercises both modes in isolation. Each scenario uses
;; clear-tests! to wipe the registry between phases so the test counts
;; are clean.

(import testing
  (describe it fdescribe fit xdescribe xit is
   run! result-passed result-failed result-skipped
   clear-tests!))

;; ── Phase 1: xit marks a single test as skipped ────────────────────────
(describe "skip"
  (it  "runs"     (is #t))
  (xit "skipped"  (is #t)))
(define r1 (run! :silent #t))
(if (not (= (result-passed r1) 1))  (error "phase1 expected 1 passed, got" (result-passed r1)))
(if (not (= (result-skipped r1) 1)) (error "phase1 expected 1 skipped, got" (result-skipped r1)))
(display "phase 1 (xit) OK") (newline)

;; ── Phase 2: xdescribe skips all nested tests ──────────────────────────
(clear-tests!)
(describe "skipped-group"
  (xdescribe "inner"
    (it "would have run" (error "must not run"))
    (it "neither would this" (error "must not run"))))
(define r2 (run! :silent #t))
(if (not (= (result-passed r2) 0))  (error "phase2 expected 0 passed, got" (result-passed r2)))
(if (not (= (result-skipped r2) 2)) (error "phase2 expected 2 skipped, got" (result-skipped r2)))
(display "phase 2 (xdescribe) OK") (newline)

;; ── Phase 3: fit puts the runner into focus mode ───────────────────────
(clear-tests!)
(describe "focus-target"
  (it  "would normally run" (error "must not run when focus active"))
  (fit "focused"            (is #t))
  (it  "also non-focused"   (error "must not run when focus active")))
(define r3 (run! :silent #t))
(if (not (= (result-passed r3) 1))  (error "phase3 expected 1 passed, got" (result-passed r3)))
(if (not (= (result-failed r3) 0))  (error "phase3 expected 0 failed, got" (result-failed r3)))
(if (not (= (result-skipped r3) 2)) (error "phase3 expected 2 skipped, got" (result-skipped r3)))
(display "phase 3 (fit focus mode) OK") (newline)

(display "focus/skip OK") (newline)
