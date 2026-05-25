; examples/agent-edit.lisp — write-capable agent loop over a target dir.
;
; Drives the ReAct loop (orch/agent) with read + write tools (orch/tools)
; and a planner (qwen2.5-coder:7b). The point of this entry vs
; explain-file.lisp: it can CHANGE files — but every repo mutation pauses
; for EXPLICIT interactive approval (orch/approval). Default is no. The
; plan validator (zepo-0rs) also refuses any plan that edits without a
; following verify step, and writes are confined to the target dir.
;
; Requires Ollama on localhost:11434 with qwen2.5-coder:7b pulled.
;
; Run:
;   zepo examples/agent-edit.lisp -- <target-dir> "<goal>"
;
; zepo-dad

(import :libs (orch/registry))
(import :libs (orch/exec))
(import :libs (orch/agent))
(import :libs (orch/tools))
(import :libs (orch/approval))
(import :libs (orch/planner))

; argv = (binary script arg ...) once Zepo has stripped "--".
(define raw-argv (argv))
(define args (if (>= (length raw-argv) 4) (cddr raw-argv) '()))

(cond
  ((< (length args) 2)
   (display "usage: zepo examples/agent-edit.lisp -- <target-dir> \"<goal>\"")
   (newline)
   (exit 1)))

(define target-dir (car args))
(define goal       (cadr args))

(define planner-model (or (getenv "ZEPO_PLANNER_MODEL") "qwen2.5-coder:7b"))
(define planner-url
  (or (getenv "ZEPO_OLLAMA_URL") "http://localhost:11434/v1/chat/completions"))

; --- tools ---------------------------------------------------------------
(reset-registry!)

; read_file (read-only) so the agent can look before it edits. Reads are
; kept under the target dir and refuse '..' traversal.
(define (read-file-tool a)
  (let ((path (cdr (assoc 'path a))))
    (cond
      ((string-contains path "..")
       (err 'unsafe-path (string-append "path contains '..': " path)))
      (else
        (let ((full (string-append target-dir "/" path)))
          (cond
            ((file-exists? full) (ok (file-read-string full)))
            (else (err 'not-found (string-append "no such file: " path)))))))))

(register-tool! 'read_file read-file-tool :inputs '((path . string)) :effect 'read)
(register-builtin-tools!)            ; edit_file, run_shell, run_tests
(set-tools-root! target-dir)

; --- planner adapter -----------------------------------------------------
(define (next-step g history ctx)
  (let ((r (plan-next-step-with g history planner-model planner-url default-retries)))
    (if (ok? r) (result-value r) r)))

; --- run -----------------------------------------------------------------
(display "── goal:    ") (display goal)       (newline)
(display "── dir:     ") (display target-dir) (newline)
(display "── tools:   read_file edit_file run_shell run_tests") (newline)
(display "── safety:  every mutation needs your explicit yes (default: no)") (newline)

(define result (run-agent goal 12 next-step interactive-confirm))

(newline)
(cond
  ((and (pair? result) (eq? (car result) 'ok))
   (display "── answer: ") (display (cdr result)) (newline))
  (else
   (display "── stopped: ") (write result) (newline)))
