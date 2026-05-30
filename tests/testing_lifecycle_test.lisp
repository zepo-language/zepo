;; zepo-mqf4: lifecycle hooks. Verifies order and isolation across nested
;; describes and across the boundary BETWEEN describes.
(import testing
  (describe it is =check
   before-each after-each before-all after-all
   run! result-passed result-failed clear-tests!))

;; ── Hook ordering across nested describes ─────────────────────────────
;;
;; This side-effect log records the sequence of hook + test invocations.
;; We compare it against the expected order after the run.

(define log '())
(define (note! sym) (set! log (append log (list sym))))

(describe "outer"
  (before-all  (lambda () (note! 'outer-before-all)))
  (after-all   (lambda () (note! 'outer-after-all)))
  (before-each (lambda () (note! 'outer-before-each)))
  (after-each  (lambda () (note! 'outer-after-each)))
  (it "test-A" (note! 'outer-test-A))
  (describe "inner"
    (before-all  (lambda () (note! 'inner-before-all)))
    (after-all   (lambda () (note! 'inner-after-all)))
    (before-each (lambda () (note! 'inner-before-each)))
    (after-each  (lambda () (note! 'inner-after-each)))
    (it "test-B" (note! 'inner-test-B))
    (it "test-C" (note! 'inner-test-C))))

(define r (run! :silent #t))
(define expected
  '(outer-before-all
    outer-before-each   outer-test-A     outer-after-each
    inner-before-all
    outer-before-each   inner-before-each   inner-test-B   inner-after-each   outer-after-each
    outer-before-each   inner-before-each   inner-test-C   inner-after-each   outer-after-each
    inner-after-all
    outer-after-all))

(if (not (equal? log expected))
    (begin
      (display "expected: ") (display expected) (newline)
      (display "got:      ") (display log) (newline)
      (error "hook order mismatch")))

(display "lifecycle hook ordering OK") (newline)

;; ── after-each runs even on failure ───────────────────────────────────
(clear-tests!)
(set! log '())

(describe "after-each-on-failure"
  (after-each (lambda () (note! 'after-ran)))
  (it "fails"   (error "boom"))
  (it "passes"  (is #t)))

(define r2 (run! :silent #t))

(if (not (= (result-failed r2) 1))
    (error "expected 1 fail in after-each-on-failure suite"))
(if (not (equal? log '(after-ran after-ran)))
    (error "after-each did not run for the failing test; log:" log))

(display "after-each-on-failure OK") (newline)
