; orch-agent-e2e-smoke.lisp — END-TO-END ReAct loop with the LIVE planner.
;
; Unlike orch-agent-smoke.lisp (which stubs the planner for deterministic
; offline coverage), this drives run-agent with the real llama3.1:8b
; next-step planner over Ollama. It proves the full integration: prompt ->
; one JSON action -> validate -> execute -> observe -> repeat -> finish.
;
; Requires Ollama on localhost:11434 with llama3.1:8b pulled.
;
; Run:
;   zepo examples/orch-agent-e2e-smoke.lisp
;
; zepo-fao

(import :libs (orch/registry (reset-registry! register-tool!) ; zepo-y1a4
               orch/exec     (run-plan)
               orch/agent    (run-agent)
               orch/planner  (plan-next-step-with default-planner-url
                              default-retries)))

(reset-registry!)
(register-tool! 'echo
                (lambda (args) (cdr (assoc 'text args)))
                :inputs '((text . string)))

; Bridge plan-next-step (goal history) -> (ok form)|(err) into the loop's
; next-step contract (goal history ctx) -> bare form | err.
; qwen2.5-coder:7b follows the one-action-or-finish protocol more
; reliably than the default planner model on this loop.
(define (next-step goal history ctx)
  (let ((r (plan-next-step-with goal history
                                "qwen2.5-coder:7b"
                                default-planner-url default-retries)))
    (if (ok? r) (result-value r) r)))

(define answer
  (run-agent
    "Use the echo tool to echo the exact word hello, then finish with the echoed text."
    6
    next-step))

(display "result: ") (write answer) (newline)
(cond
  ((and (pair? answer) (eq? (car answer) 'ok))
   (display "OK  loop reached a finish") (newline))
  (else
   (display "FAIL loop did not finish cleanly") (newline)
   (exit 1)))
