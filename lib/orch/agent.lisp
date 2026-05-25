; lib/orch/agent.lisp — iterative ReAct loop over the plan executor.
;
; orch/exec runs a static plan once. This wraps it in an observe->act->
; observe driver: each turn a planner picks ONE action, the executor runs
; it over a SHARED ctx (zepo-qjk seed semantics carry prior step ids
; across turns), and the rendered result is appended to a transcript the
; planner reads next turn. The model reacts to every observation — that
; feedback edge is what makes this an agent rather than a one-shot Q&A.
;
; The planner is INJECTED as `next-step` so the loop is testable without
; a live model: next-step is (goal history ctx) -> a core action form,
; a (finish "text") terminal form, or an (err ...).
;
; zepo-fao

(module orch/agent
  (export run-agent render-observation)

  (import orch/exec)
  (import orch/registry)   ; tool-effect, for the mutating-tool gate

  ; Drive the loop until next-step says (finish ...), the max-iters
  ; budget is spent, or the same action repeats (no progress).
  ; The optional CONFIRM callback gates mutating tools: it is called with
  ; the action and must return truthy to let the tool run; the default
  ; denies, so a mutating tool never runs unless a caller opts in.
  ; Returns (ok answer-text) | (err 'budget-exhausted history)
  ;       | (err 'no-progress history) | a propagated executor err.
  (define (run-agent goal max-iters next-step . opt)
    (let ((confirm (if (null? opt) deny-all (car opt))))
      (let loop ((i 0) (ctx '()) (history "") (last-action #f) (pending #f))
        (cond
          ((>= i max-iters) (err 'budget-exhausted history))
          (else
            (let ((action (next-step goal history ctx)))
              (cond
                ((err? action) action)
                ; zepo-m4z: the verify invariant lives at the loop level
                ; for ReAct (one bare action per turn can't carry its own
                ; verify). Refuse to finish while an edit is unverified;
                ; feed the requirement back so the model runs a verify
                ; step (e.g. run_tests) and then finishes.
                ((finish? action)
                 (cond
                   ((not pending) (ok (finish-text action)))
                   (else
                     (loop (+ i 1) ctx
                           (string-append history
                             "REJECTED finish: files were modified but no verify step has run since. Run a verify tool (e.g. run_tests), then finish.\n")
                           action pending))))
                ((equal? action last-action) (err 'no-progress history))
                ; gate: a mutating tool-call the caller won't confirm is
                ; recorded as a 'denied result (so the planner sees it in
                ; ctx and history) and the loop moves on without running it.
                ; A denied mutation never ran, so it leaves pending alone.
                ((and (tool-call? action)
                      (eq? (tool-effect (action-tool action)) 'mutating)
                      (not (confirm action)))
                 (let ((id (tool-call-id action)))
                   (loop (+ i 1)
                         (cons (cons id (err 'denied "mutating tool not approved")) ctx)
                         (string-append history "step " id " DENIED: mutating tool not approved\n")
                         action pending)))
                (else
                  (let ((r (run-plan action ctx)))
                    (cond
                      ((err? r) r)
                      (else
                        (let* ((ctx2 (result-value r))
                               (obs  (render-observation action ctx2))
                               (eff  (action-effect action))
                               ; a SUCCESSFUL mutation owes a verify; a
                               ; verify step clears the debt; reads keep it.
                               (new-pending
                                 (cond
                                   ((eq? eff 'mutating)
                                    (or pending (mutation-ok? action ctx2)))
                                   ((eq? eff 'verify) #f)
                                   (else pending))))
                          (loop (+ i 1) ctx2
                                (string-append history obs "\n")
                                action new-pending)))))))))))))

  ; Turn the just-run action's result into a compact transcript line.
  ; Errors are rendered (not swallowed) so the planner can recover.
  (define (render-observation action ctx)
    (cond
      ((tool-call? action)
       (let* ((id  (tool-call-id action))
              (res (step-result-of id ctx)))
         (cond
           ((ok? res)
            (string-append "step " id " ok: " (->str (result-value res))))
           (else
            (string-append "step " id " ERROR "
                           (symbol->string (err-kind res)) ": "
                           (err-message res))))))
      (else "step done")))

  ; ── Helpers ────────────────────────────────────────────────────────────

  (define (finish? a)      (and (pair? a) (eq? (car a) 'finish)))
  (define (finish-text a)  (car (cdr a)))
  (define (tool-call? a)   (and (pair? a) (eq? (car a) 'tool-call)))
  (define (tool-call-id a) (car (cdr a)))
  ; core tool-call form is (tool-call ID NAME ARGS).
  (define (action-tool a)  (car (cdr (cdr a))))
  (define (deny-all action) #f)

  ; zepo-m4z: a tool-call action's effect class, or 'read for non-calls.
  (define (action-effect a)
    (if (tool-call? a) (tool-effect (action-tool a)) 'read))

  ; Did this mutating action actually succeed (record an ok in ctx)?
  ; A failed edit changed nothing, so it owes no verify.
  (define (mutation-ok? action ctx)
    (and (tool-call? action)
         (ok? (step-result-of (tool-call-id action) ctx))))

  (define (->str v)
    (cond
      ((string? v) v)
      ((number? v) (number->string v))
      ((symbol? v) (symbol->string v))
      (else (write-to-string v)))))
