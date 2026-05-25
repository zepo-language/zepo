; lib/orch/tools.lisp — the orchestrator's write-side tools.
;
; These turn the orchestrator from a read-only explainer into something
; that can change a repo. They are tagged with effect classes (zepo-0rs)
; so the plan validator forces a verify step after every mutation, and
; they are meant to run only behind the agent loop's approval gate
; (zepo-fao) — never the bare static executor.
;
;   edit_file  (:effect 'mutating) — write content to a confined path
;   run_shell  (:effect 'mutating) — run a command, capture stdout + exit
;   run_tests  (:effect 'verify)   — run a command as a verification step
;
; Writes are confined to a configurable root (default: CWD) so an agent
; cannot clobber arbitrary files.
;
; zepo-k2n

(module orch/tools
  (export register-builtin-tools! set-tools-root! tools-root)

  (import orch/registry)

  ; Confinement root, in a one-cell vector so set-tools-root! can change
  ; it without rebinding. #f means "use the current working directory".
  (define root-box (vector #f))
  (define (tools-root) (or (vector-ref root-box 0) (current-directory)))
  (define (set-tools-root! path) (vector-set! root-box 0 path))

  (define (register-builtin-tools!)
    (register-tool! 'edit_file edit-file-fn
                    :inputs '((path . string) (content . string))
                    :effect 'mutating)
    (register-tool! 'run_shell run-shell-fn
                    :inputs '((cmd . string))
                    :effect 'mutating)
    (register-tool! 'run_tests run-tests-fn
                    :inputs '((cmd . string))
                    :effect 'verify))

  ; ── edit_file ───────────────────────────────────────────────────────────

  ; Write content to path (truncating). Path is confined to the root.
  ; Returns (ok summary) | (err 'unsafe-path | 'outside-root msg).
  (define (edit-file-fn args)
    (let ((path    (cdr (assoc 'path args)))
          (content (cdr (assoc 'content args))))
      (let ((safe (confine path)))
        (cond
          ((err? safe) safe)
          (else
            (file-write-string (result-value safe) content)
            (ok (string-append "wrote "
                               (number->string (string-length content))
                               " bytes to " path)))))))

  ; Resolve path against the root and reject anything that could escape
  ; it. The ".." guard blocks traversal; the prefix check blocks absolute
  ; paths pointing elsewhere. Returns (ok abs-path) | (err ...).
  (define (confine path)
    (cond
      ((string-contains path "..")
       (err 'unsafe-path (string-append "path contains '..': " path)))
      (else
        (let* ((root (tools-root))
               (abs  (if (string-prefix? "/" path)
                         path
                         (string-append root "/" path))))
          (cond
            ((not (string-prefix? (string-append root "/") abs))
             (err 'outside-root
                  (string-append "path escapes root " root ": " path)))
            (else (ok abs)))))))

  ; ── run_shell / run_tests ─────────────────────────────────────────────────

  (define (run-shell-fn args)
    (run-capture (cdr (assoc 'cmd args)) 'shell-failed))

  (define (run-tests-fn args)
    (run-capture (cdr (assoc 'cmd args)) 'tests-failed))

  ; Run cmd via `sh -c`, capturing stdout and the exit code (process-spawn
  ; like orch/http does). Exit 0 -> (ok stdout); non-zero -> (err kind msg)
  ; carrying the exit code and output so the planner can react.
  ; zepo-m4z: run in the tools root so a verify step (run_tests) sees the
  ; same files edit_file writes — otherwise it runs in the process CWD and
  ; can't find them. The root is single-quoted to tolerate spaces.
  (define (run-capture cmd fail-kind)
    (let ((p (process-spawn "sh" "-c"
                            (string-append "cd '" (tools-root) "' && " cmd))))
      (process-close-stdin p)
      (let ((out  (process-recv-all p))
            (code (process-wait p)))
        (cond
          ((= code 0) (ok out))
          (else (err fail-kind
                     (string-append "exit " (number->string code) ": " out))))))))
