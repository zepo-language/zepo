; orch-agent-smoke.lisp — offline smoke for the ReAct loop in
; lib/orch/agent.lisp.
;
; The loop's planner is INJECTED (run-agent takes a next-step fn), so the
; whole control flow — finish, ctx threading, error feedback, the
; max-iters cap, the no-progress guard, and the mutating-tool approval
; gate — is exercised deterministically without Ollama.
;
; Run:
;   zepo examples/orch-agent-smoke.lisp
;
; zepo-fao

(import :libs (orch/registry (reset-registry! register-tool!) ; zepo-y1a4
               orch/exec     (step-result-of)
               orch/agent    (run-agent)
               orch/plan     (plan-from-json)))

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

; --- one action, then finish with the result threaded out of ctx ---
; turn 0 (empty ctx): run add. turn 1: finish with s1's value as text.
(define (stub-add goal history ctx)
  (cond
    ((null? ctx) '(tool-call "s1" add ((a . 2) (b . 3))))
    (else (list 'finish (number->string (result-value (step-result-of "s1" ctx)))))))

(let ((r (run-agent "add 2 and 3" 10 stub-add)))
  (assert-eq "agent finishes with answer" '(ok . "5") r))

; --- error feedback: a tool error is observed and the loop recovers ---
; flaky errs on its first call, succeeds on its second. The stub sees the
; error in ctx and retries with a fresh id, then finishes.
(define flaky-n (vector 0))
(register-tool! 'flaky
                (lambda (args)
                  (let ((n (vector-ref flaky-n 0)))
                    (vector-set! flaky-n 0 (+ n 1))
                    (if (= n 0) (err 'transient "first call fails") "recovered"))))

(define (stub-retry goal history ctx)
  (cond
    ((null? ctx) '(tool-call "f1" flaky ()))
    ((assoc "f2" ctx) (list 'finish (result-value (step-result-of "f2" ctx))))
    ((err? (step-result-of "f1" ctx)) '(tool-call "f2" flaky ()))
    (else (list 'finish "unexpected"))))

(let ((r (run-agent "do the flaky thing" 10 stub-retry)))
  (assert-eq "recovers after tool error" '(ok . "recovered") r)
  (assert-eq "flaky called twice"        2                    (vector-ref flaky-n 0)))

; --- max-iters cap: a planner that never finishes is stopped ---
; distinct id each turn so the no-progress guard does not fire first.
(define (stub-forever goal history ctx)
  (list 'tool-call (string-append "x" (number->string (length ctx)))
        'add '((a . 1) (b . 1))))

(let ((r (run-agent "loop forever" 3 stub-forever)))
  (assert-eq "budget exhausted" 'budget-exhausted (err-kind r)))

; --- no-progress guard: the same action twice aborts ---
(define (stub-stuck goal history ctx) '(tool-call "same" add ((a . 1) (b . 1))))

(let ((r (run-agent "get stuck" 100 stub-stuck)))
  (assert-eq "no progress" 'no-progress (err-kind r)))

; --- approval gate: a mutating tool needs explicit confirmation ---
(define edit-n (vector 0))
(register-tool! 'edit
                (lambda (args)
                  (vector-set! edit-n 0 (+ (vector-ref edit-n 0) 1))
                  "wrote")
                :effect 'mutating)
(register-tool! 'verify_tool (lambda (args) "verified") :effect 'verify)

(define (ok-step? id ctx)
  (let ((p (assoc id ctx))) (and p (ok? (cdr p)))))

; turn 0 tries the edit; if it SUCCEEDED (approved), verify before finish
; (zepo-m4z requires it); if it was denied, no successful mutation so the
; stub can finish straight away.
(define (stub-edit goal history ctx)
  (cond ((null? ctx) '(tool-call "m1" edit ()))
        ((and (ok-step? "m1" ctx) (not (assoc "v1" ctx)))
         '(tool-call "v1" verify_tool ()))
        (else (list 'finish "done"))))

; default (no confirm) denies the mutation
(vector-set! edit-n 0 0)
(let ((r (run-agent "edit a file" 10 stub-edit)))
  (assert-eq "default deny: edit not run" 0             (vector-ref edit-n 0))
  (assert-eq "deny: loop still finishes"  '(ok . "done") r))

; an approving confirm callback lets the mutation run
(vector-set! edit-n 0 0)
(let ((r (run-agent "edit a file" 10 stub-edit (lambda (action) #t))))
  (assert-eq "approved: edit runs"     1             (vector-ref edit-n 0))
  (assert-eq "approved: loop finishes" '(ok . "done") r))

; --- the JSON finish form the real planner emits parses to (finish ...) ---
(let ((r (plan-from-json "{\"type\":\"finish\",\"text\":\"all done\"}")))
  (assert-eq "finish parses to core form" '(ok finish "all done") r))

; --- zepo-m4z: finish is blocked while a mutation is unverified ---
; edits, then keeps trying to finish without verifying -> must NOT return ok
(define (stub-bad goal history ctx)
  (cond ((null? ctx) '(tool-call "m1" edit ()))
        (else (list 'finish "early"))))
(let ((r (run-agent "edit without verify" 10 stub-bad (lambda (a) #t))))
  (assert-eq "unverified finish blocked" #f (equal? r '(ok . "early")))
  (assert-eq "unverified finish errors"  #t (err? r)))

; edit -> verify -> finish succeeds once the mutation is verified
(define (stub-good goal history ctx)
  (cond ((null? ctx)            '(tool-call "m1" edit ()))
        ((not (assoc "v1" ctx)) '(tool-call "v1" verify_tool ()))
        (else                   (list 'finish "done"))))
(let ((r (run-agent "edit then verify" 10 stub-good (lambda (a) #t))))
  (assert-eq "edit+verify+finish ok" '(ok . "done") r))

(display "all checks passed.") (newline)
