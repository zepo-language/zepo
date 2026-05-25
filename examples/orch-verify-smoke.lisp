; orch-verify-smoke.lisp — manual smoke for the verify-after-mutation
; rule in lib/orch/plan.lisp.
;
; A mutating tool (edit_file, run_shell) must be followed by a verify
; tool (run_tests) within the same sequence, or the plan is rejected at
; validate time. This makes correctness structural instead of relying
; on the planner model's discipline.
;
; Run:
;   zepo examples/orch-verify-smoke.lisp
;
; zepo-0rs

(import :libs (orch/registry))
(import :libs (orch/plan))

(reset-registry!)
; Effect tags drive the rule; the fns are never called during validation.
(register-tool! 'edit_file (lambda (args) "edited")  :effect 'mutating)
(register-tool! 'run_tests (lambda (args) "passed")  :effect 'verify)
(register-tool! 'retrieve  (lambda (args) "context")) ; default :effect 'read

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want)
          (display " got=") (display got) (newline)
          (exit 1))))

; --- REJECT: mutation with no following verify in the sequence ---
(let ((r (plan-from-json
           (string-append
             "{\"type\":\"sequence\",\"steps\":["
             "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{\"path\":\"x\"}},"
             "{\"type\":\"final-answer\",\"from\":\"e1\"}]}"))))
  (assert-eq "reject unverified mutation" #t           (err? r))
  (assert-eq "reject kind"                'invalid-plan (err-kind r)))

; --- ACCEPT: mutation followed by a verify step ---
(let ((r (plan-from-json
           (string-append
             "{\"type\":\"sequence\",\"steps\":["
             "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{\"path\":\"x\"}},"
             "{\"type\":\"tool-call\",\"id\":\"v1\",\"tool\":\"run_tests\",\"args\":{}},"
             "{\"type\":\"final-answer\",\"from\":\"v1\"}]}"))))
  (assert-eq "accept verified mutation" #t (ok? r)))

; --- REJECT: bare mutating tool-call with no enclosing sequence ---
(let ((r (plan-from-json
           "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{}}")))
  (assert-eq "reject bare mutation" #t (err? r)))

; --- REJECT: mutating tool-call directly inside a parallel (v1) ---
(let ((r (plan-from-json
           (string-append
             "{\"type\":\"parallel\",\"steps\":["
             "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{}},"
             "{\"type\":\"tool-call\",\"id\":\"r1\",\"tool\":\"retrieve\",\"args\":{}}]}"))))
  (assert-eq "reject mutation in parallel" #t (err? r)))

; --- REJECT: verify present but BEFORE the mutation (wrong order) ---
(let ((r (plan-from-json
           (string-append
             "{\"type\":\"sequence\",\"steps\":["
             "{\"type\":\"tool-call\",\"id\":\"v1\",\"tool\":\"run_tests\",\"args\":{}},"
             "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{}},"
             "{\"type\":\"final-answer\",\"from\":\"e1\"}]}"))))
  (assert-eq "reject verify-before-mutation" #t (err? r)))

; --- ACCEPT: read-only plan imposes no constraint (regression) ---
(let ((r (plan-from-json
           (string-append
             "{\"type\":\"sequence\",\"steps\":["
             "{\"type\":\"tool-call\",\"id\":\"r1\",\"tool\":\"retrieve\",\"args\":{}},"
             "{\"type\":\"final-answer\",\"from\":\"r1\"}]}"))))
  (assert-eq "accept read-only plan" #t (ok? r)))

; --- zepo-m4z: ReAct single-action validation skips the within-sequence ---
; rule (a one-action plan is inherently "bare"); the loop enforces verify
; across turns instead. The full-DAG validator is UNCHANGED.
(let ((step "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{\"path\":\"x\",\"content\":\"y\"}}"))
  (assert-eq "step: bare edit accepted"        #t (ok? (plan-step-from-json step)))
  (assert-eq "full: bare edit still rejected"  #t (err? (plan-from-json step))))

(display "all checks passed.") (newline)
