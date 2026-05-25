; lib/orch/approval.lisp — interactive approval gate for mutating actions.
;
; The agent loop (orch/agent) calls a confirm callback before running any
; :mutating tool, and denies by default. This module supplies the
; interactive callback: it shows the user exactly what is about to happen
; and only proceeds on an EXPLICIT yes. Anything ambiguous, empty, or an
; EOF (no TTY / piped close) is treated as NO. The repo is never modified
; without the user saying yes.
;
; zepo-dad

(module orch/approval
  (export approved? describe-action interactive-confirm)

  ; The whole safety contract in one predicate: truthy ONLY for an
  ; explicit yes. Accepts the eof-object (read-line at EOF) and denies it.
  (define (approved? response)
    (cond
      ((eof-object? response) #f)
      ((not (string? response)) #f)
      (else
        (let ((r (string-downcase (trim response))))
          (or (string=? r "y") (string=? r "yes"))))))

  ; A human-readable render of the action the user is being asked to
  ; approve. For edit_file we surface the path and a content preview so
  ; the decision is informed; other mutating tools show name + args.
  (define (describe-action action)
    (cond
      ((not (tool-call? action)) "non-tool action")
      (else
        (let ((id   (nth action 1))
              (name (nth action 2))
              (args (nth action 3)))
          (cond
            ((eq? name 'edit_file)
             (string-append "edit_file [" id "] -> " (->s (arg args 'path)) "\n"
                            "  content: " (preview (->s (arg args 'content)) 200)))
            ((eq? name 'run_shell)
             (string-append "run_shell [" id "]: " (->s (arg args 'cmd))))
            (else
             (string-append (symbol->string name) " [" id "]")))))))

  ; The confirm callback handed to run-agent. Prints the action and a
  ; [y/N] prompt, reads one line from stdin, and returns (approved? line).
  (define (interactive-confirm action)
    (display "\n── approval required ──────────────────────────────") (newline)
    (display (describe-action action)) (newline)
    (display "apply this change? [y/N] ")
    (approved? (read-line)))

  ; ── Helpers ────────────────────────────────────────────────────────────

  (define (tool-call? a) (and (pair? a) (eq? (car a) 'tool-call)))
  (define (nth lst i) (if (= i 0) (car lst) (nth (cdr lst) (- i 1))))
  (define (arg args key)
    (let ((p (assoc key args))) (and p (cdr p))))

  (define (->s v)
    (cond
      ((string? v) v)
      ((symbol? v) (symbol->string v))
      ((number? v) (number->string v))
      ((not v)     "<missing>")
      (else (write-to-string v))))

  (define (preview s n)
    (if (> (string-length s) n)
        (string-append (substring s 0 n) " …")
        s))

  (define (trim s)
    (let ((n (string-length s)))
      (let scan-start ((i 0))
        (cond
          ((>= i n) "")
          ((ws? (string-ref s i)) (scan-start (+ i 1)))
          (else
            (let scan-end ((j (- n 1)))
              (cond
                ((ws? (string-ref s j)) (scan-end (- j 1)))
                (else (substring s i (+ j 1))))))))))

  (define (ws? c)
    (or (char=? c #\space) (char=? c #\tab)
        (char=? c #\newline) (char=? c #\return))))
