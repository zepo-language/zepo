;; zepo-n6qc: parallel test execution via fibers.
;;
;; Each (it ...) runs in its own spawned fiber when (run! :parallel #t)
;; is in effect. Four tests that each sleep 100ms should complete in
;; ~100ms total when parallel, vs. ~400ms serial.

(import testing (describe it is run!
                 result-passed result-failed result-duration-ms
                 clear-tests!))

;; ── Run 1: serial — should take ~400ms ───────────────────────────────
(describe "parallel-bench"
  (it "sleeps 100ms (1)" (sleep 0.1) (is #t))
  (it "sleeps 100ms (2)" (sleep 0.1) (is #t))
  (it "sleeps 100ms (3)" (sleep 0.1) (is #t))
  (it "sleeps 100ms (4)" (sleep 0.1) (is #t)))

(define serial-r (run! :silent #t))
(display "serial: ")
(display (result-passed serial-r))
(display "/4 in ")
(display (result-duration-ms serial-r))
(display " ms")
(newline)

(if (not (= (result-passed serial-r) 4))
    (error "expected 4 passed in serial"))

;; ── Run 2: parallel — same 4 tests, should finish faster ─────────────
(define par-r (run! :silent #t :parallel #t))
(display "parallel: ")
(display (result-passed par-r))
(display "/4 in ")
(display (result-duration-ms par-r))
(display " ms")
(newline)

(if (not (= (result-passed par-r) 4))
    (error "expected 4 passed in parallel"))

;; The win threshold is generous to allow for scheduler overhead:
;; parallel should be at LEAST 30% faster than serial.
(define serial-ms (result-duration-ms serial-r))
(define par-ms    (result-duration-ms par-r))
(if (not (< par-ms (* serial-ms 0.7)))
    (error "parallel did not beat serial:"
           "serial=" serial-ms "ms parallel=" par-ms "ms"))

(display "parallel beat serial by ")
(display (- serial-ms par-ms))
(display " ms")
(newline)
(display "parallel execution OK") (newline)
