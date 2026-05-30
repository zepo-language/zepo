; orch-exec-smoke.lisp — manual smoke test for lib/orch/exec.lisp.
;
; Exercises tool-call / sequence / parallel / final-answer with an
; in-process registry. Includes a timing comparison that confirms
; parallel actually overlaps yielding tools.
;
; Run:
;   zepo examples/orch-exec-smoke.lisp
;
; zepo-ekd

(import :libs (orch/registry (reset-registry! register-tool!) ; zepo-y1a4
               orch/exec     (run-plan plan-result step-result-of)))

(reset-registry!)

(register-tool! 'echo (lambda (args) (cdr (assoc 'text args)))
                :inputs '((text . string)))
(register-tool! 'add  (lambda (args) (+ (cdr (assoc 'a args)) (cdr (assoc 'b args))))
                :inputs '((a . integer) (b . integer)))
(register-tool! 'slow (lambda (args) (sleep 0.2) (cdr (assoc 'tag args)))
                :inputs '((tag . string)))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want)
          (display " got=") (display got) (newline)
          (exit 1))))

; --- basic plan with final-answer ---
(let* ((r (run-plan '(sequence
                       (tool-call "x" add ((a . 2) (b . 3)))
                       (tool-call "y" add ((a . 10) (b . 20)))
                       (final-answer "y"))))
       (ctx (result-value r)))
  (assert-eq "final via plan-result" '(ok . 30) (plan-result ctx)))

; --- sequence short-circuit ---
(let ((r (run-plan
           '(sequence
              (tool-call "a" echo ((text . "ok")))
              (tool-call "b" echo ((text . 42)))    ; wrong-type
              (tool-call "c" echo ((text . "skipped")))))))
  (assert-eq "short-circuit err"  #t            (err? r))
  (assert-eq "short-circuit kind" 'plan-failed  (err-kind r)))

; --- parallel partial-fail records both ok and err entries ---
(let* ((r (run-plan
            '(parallel
               (tool-call "good" echo ((text . "yes")))
               (tool-call "bad"  echo ((text . 42))))))
       (ctx (result-value r)))
  (assert-eq "parallel good" '(ok . "yes") (step-result-of "good" ctx))
  (assert-eq "parallel bad"   #t            (err? (step-result-of "bad" ctx))))

; --- timing: parallel actually overlaps yielding tools ---
;
; zepo-mj0h: replaced the wall-clock-only check (< par-ms (/ seq-ms 2)),
; which flaked under fiber scheduler load. We now verify overlap directly:
; each `traced` tool records its start time into a shared list and the
; parallel block asserts max(start_i) - min(start_i) < 50 ms. That proves
; the tools actually launched concurrently regardless of how slow the
; scheduler is. Wall-clock is still printed for visibility.
(define starts '())
(define (record-start!) (set! starts (cons (current-time-ms) starts)))
(register-tool! 'traced (lambda (args) (record-start!) (sleep 0.2)
                          (cdr (assoc 'tag args)))
                :effect 'read-only)

(define t0 (current-time-ms))
(run-plan '(sequence (tool-call "a" slow ((tag . "a")))
                     (tool-call "b" slow ((tag . "b")))
                     (tool-call "c" slow ((tag . "c")))))
(define seq-ms (- (current-time-ms) t0))

(set! starts '())
(define t1 (current-time-ms))
(run-plan '(parallel  (tool-call "a" traced ((tag . "a")))
                      (tool-call "b" traced ((tag . "b")))
                      (tool-call "c" traced ((tag . "c")))))
(define par-ms (- (current-time-ms) t1))

(display "seq 3x200ms = ") (display seq-ms) (display " ms") (newline)
(display "par 3x200ms = ") (display par-ms) (display " ms") (newline)

; Direct overlap check: the three tools started within 50 ms of each other,
; which is only possible if the parallel scheduler launched them concurrently.
(define (max-of xs) (let loop ((xs (cdr xs)) (m (car xs)))
                      (if (null? xs) m (loop (cdr xs) (if (> (car xs) m) (car xs) m)))))
(define (min-of xs) (let loop ((xs (cdr xs)) (m (car xs)))
                      (if (null? xs) m (loop (cdr xs) (if (< (car xs) m) (car xs) m)))))
(define start-spread (- (max-of starts) (min-of starts)))
(display "parallel start spread = ") (display start-spread) (display " ms") (newline)
(assert-eq "parallel overlaps" #t (< start-spread 50))

(display "all checks passed.") (newline)
