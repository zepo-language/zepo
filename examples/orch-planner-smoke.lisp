; orch-planner-smoke.lisp — manual smoke for lib/orch/planner.lisp.
;
; Requires a local Ollama with llama3.1:8b pulled. Registers a couple of
; tools, asks the planner for a plan, prints the resulting core form.
; Does NOT run the plan — that's the workflow bead's job.
;
; Run:
;   zepo examples/orch-planner-smoke.lisp
;
; zepo-gp5

(import :libs (orch/registry))
(import :libs (orch/planner))

(reset-registry!)
(register-tool! 'retrieve_docs (lambda (args) "fake docs")
                :inputs '((query . string)))
(register-tool! 'summarize (lambda (args) "summary")
                :inputs '((text . string)))

(define p (plan "Find docs about workers, then summarize the result" ""))

(cond
  ((err? p)
   (display "FAIL: ") (display (err-kind p))
   (display " — ") (display (err-message p)) (newline)
   (exit 1))
  (else
   (display "OK: planner returned a valid core plan.") (newline)
   (display "  ") (display (result-value p)) (newline)))
