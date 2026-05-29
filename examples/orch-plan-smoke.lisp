; orch-plan-smoke.lisp — manual smoke test for lib/orch/plan.lisp.
;
; Validates the planner JSON → core-form pipeline AND verifies the result
; runs cleanly through orch/exec. No model calls — uses fixed in-process
; tools so the smoke is self-contained.
;
; Run:
;   zepo examples/orch-plan-smoke.lisp
;
; zepo-bh2

(import :libs (orch/plan     (plan-from-json) ; zepo-y1a4
               orch/registry (reset-registry! register-tool!)
               orch/exec     (run-plan step-result-of plan-result)))

(reset-registry!)
(register-tool! 'echo (lambda (args) (cdr (assoc 'text args)))
                :inputs '((text . string)))
(register-tool! 'add  (lambda (args) (+ (cdr (assoc 'a args)) (cdr (assoc 'b args))))
                :inputs '((a . integer) (b . integer)))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display "  want=") (display want)
          (display "  got=") (display got) (newline)
          (exit 1))))

; --- Validate planner-shaped JSON --------------------------------------------
(define p1
  (plan-from-json
    "{\"type\":\"sequence\",\"steps\":[
       {\"type\":\"parallel\",\"steps\":[
         {\"type\":\"tool-call\",\"id\":\"e\",\"tool\":\"echo\",\"args\":{\"text\":\"hi\"}},
         {\"type\":\"tool-call\",\"id\":\"a\",\"tool\":\"add\", \"args\":{\"a\":3,\"b\":4}}
       ]},
       {\"type\":\"final-answer\",\"from\":\"a\"}]}"))

(assert-eq "validates" #t (ok? p1))

; --- Run it via orch/exec ----------------------------------------------------
(define ctx (run-plan (result-value p1)))
(assert-eq "runs"   #t (ok? ctx))
(assert-eq "e ok"   '(ok . "hi") (step-result-of "e" (result-value ctx)))
(assert-eq "a ok"   '(ok . 7)    (step-result-of "a" (result-value ctx)))
(assert-eq "final"  '(ok . 7)    (plan-result (result-value ctx)))

; --- Typed errors --------------------------------------------------------------
(let ((r (plan-from-json "not even json")))
  (assert-eq "bad json"   #t (err? r))
  (assert-eq "bad json kind" 'json-parse-failed (err-kind r)))

(let ((r (plan-from-json "{\"type\":\"bogus\"}")))
  (assert-eq "unknown type"      #t (err? r))
  (assert-eq "unknown type kind" 'invalid-plan (err-kind r)))

(let ((r (plan-from-json
           "{\"type\":\"sequence\",\"steps\":[
              {\"type\":\"tool-call\",\"id\":99,\"tool\":\"echo\",\"args\":{}}]}")))
  (assert-eq "nested err"  #t (err? r))
  ; path should point at the bad nested field
  (display "  nested-err: ") (display (err-message r)) (newline))

(display "all checks passed.") (newline)
