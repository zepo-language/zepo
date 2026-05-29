; orch-persist-smoke.lisp — manual smoke test for lib/orch/persist.lisp.
;
; Exercises save/load of a run's ctx and resume-by-seed-ctx in the
; executor: a seeded result short-circuits the tool call so a finished
; (or partially finished) run can be replayed without re-running tools.
;
; Run:
;   zepo examples/orch-persist-smoke.lisp
;
; zepo-qjk

(import :libs (orch/registry (reset-registry! register-tool!) ; zepo-y1a4
               orch/exec     (run-plan plan-result step-result-of)
               orch/persist  (save-ctx load-ctx)))

(define test-path "/tmp/zepo-qjk-run.json")

; A counting tool: every real invocation bumps the counter so a test can
; prove whether a step was actually run or served from a seeded result.
(define calls (vector 0))
(define (bump!) (vector-set! calls 0 (+ (vector-ref calls 0) 1)))

(reset-registry!)
(register-tool! 'add
                (lambda (args)
                  (bump!)
                  (+ (cdr (assoc 'a args)) (cdr (assoc 'b args))))
                :inputs '((a . integer) (b . integer)))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want)
          (display " got=") (display got) (newline)
          (exit 1))))

; --- save a finished run's ctx, reload it, plan-result still works ---
(let* ((r   (run-plan '(sequence
                         (tool-call "x" add ((a . 2) (b . 3)))
                         (final-answer "x"))))
       (ctx (result-value r)))
  (let ((saved (save-ctx test-path ctx)))
    (assert-eq "save ok" #t (ok? saved)))
  (let* ((loaded (load-ctx test-path))
         (lctx   (result-value loaded)))
    (assert-eq "load ok"         #t        (ok? loaded))
    (assert-eq "reloaded answer" '(ok . 5) (plan-result lctx))))

; --- resume: a seeded ctx short-circuits the matching tool call ---
(vector-set! calls 0 0)
(let* ((seed (result-value (load-ctx test-path)))    ; ctx already has "x" -> (ok . 5)
       (r    (run-plan '(sequence
                          (tool-call "x" add ((a . 2) (b . 3)))
                          (final-answer "x"))
                       seed))
       (ctx  (result-value r)))
  (assert-eq "resume answer"   '(ok . 5) (plan-result ctx))
  (assert-eq "tool NOT re-run" 0         (vector-ref calls 0)))

; --- partial resume: cached step skipped, uncached step runs ---
(vector-set! calls 0 0)
(let* ((seed (list (cons "s1" (ok 100))))             ; s1 precomputed; s2 absent
       (r    (run-plan '(sequence
                          (tool-call "s1" add ((a . 1) (b . 1)))   ; cached -> skipped
                          (tool-call "s2" add ((a . 4) (b . 5)))   ; fresh  -> runs (=9)
                          (final-answer "s2"))
                       seed))
       (ctx  (result-value r)))
  (assert-eq "partial: s1 cached" '(ok . 100) (step-result-of "s1" ctx))
  (assert-eq "partial: s2 fresh"  '(ok . 9)   (step-result-of "s2" ctx))
  (assert-eq "partial: ran once"  1           (vector-ref calls 0)))

; --- a cached err is NOT reused: the failed step re-runs ---
(vector-set! calls 0 0)
(let* ((seed (list (cons "e1" (err 'tool-failure "boom"))))
       (r    (run-plan '(sequence
                          (tool-call "e1" add ((a . 6) (b . 7)))
                          (final-answer "e1"))
                       seed))
       (ctx  (result-value r)))
  (assert-eq "err re-run result" '(ok . 13) (step-result-of "e1" ctx))
  (assert-eq "err re-run once"   1          (vector-ref calls 0)))

(display "all checks passed.") (newline)
