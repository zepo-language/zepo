; orch-tools-smoke.lisp — smoke for the mutating/verify tools in
; lib/orch/tools.lisp (edit_file, run_shell, run_tests).
;
; Covers: edit_file writing within a confined root, refusing paths that
; escape it, run_shell capturing a non-zero exit as an err, run_tests
; being verify-classed, and the zepo-0rs integration (a plan that edits
; then verifies validates; edit-alone is rejected).
;
; Run:
;   zepo examples/orch-tools-smoke.lisp
;
; zepo-k2n

(import :libs (orch/registry))
(import :libs (orch/tools))
(import :libs (orch/plan))

(define root "/tmp/zepo-k2n-root")
(shell (string-append "rm -rf " root " && mkdir -p " root))

(reset-registry!)
(register-builtin-tools!)
(set-tools-root! root)

(define (call-reg name args) (call-tool (lookup-tool name) args))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want)
          (display " got=") (display got) (newline)
          (exit 1))))

; --- edit_file writes within the root ---
(let ((r (call-reg 'edit_file (list (cons 'path "hello.txt")
                                     (cons 'content "hi there")))))
  (assert-eq "edit_file ok"     #t        (ok? r))
  (assert-eq "file written"     "hi there" (file-read-string (string-append root "/hello.txt"))))

; --- edit_file refuses a path that escapes the root ---
(let ((r (call-reg 'edit_file (list (cons 'path "../escape.txt")
                                     (cons 'content "nope")))))
  (assert-eq "reject traversal" #t (err? r)))

; --- run_tests is verify-classed; a passing command returns ok ---
(assert-eq "run_tests effect" 'verify (tool-effect 'run_tests))
(let ((r (call-reg 'run_tests (list (cons 'cmd "true")))))
  (assert-eq "tests pass -> ok" #t (ok? r)))

; --- run_shell captures a non-zero exit as an err ---
(assert-eq "run_shell effect" 'mutating (tool-effect 'run_shell))
(let ((r (call-reg 'run_shell (list (cons 'cmd "exit 3")))))
  (assert-eq "shell non-zero -> err" #t (err? r)))

; --- zepo-0rs integration: edit+verify validates, edit-alone rejected ---
(let ((good (plan-from-json
              (string-append
                "{\"type\":\"sequence\",\"steps\":["
                "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{\"path\":\"a\",\"content\":\"x\"}},"
                "{\"type\":\"tool-call\",\"id\":\"v1\",\"tool\":\"run_tests\",\"args\":{\"cmd\":\"true\"}},"
                "{\"type\":\"final-answer\",\"from\":\"v1\"}]}")))
      (bad  (plan-from-json
              (string-append
                "{\"type\":\"sequence\",\"steps\":["
                "{\"type\":\"tool-call\",\"id\":\"e1\",\"tool\":\"edit_file\",\"args\":{\"path\":\"a\",\"content\":\"x\"}},"
                "{\"type\":\"final-answer\",\"from\":\"e1\"}]}"))))
  (assert-eq "edit+verify accepted" #t (ok? good))
  (assert-eq "edit-alone rejected"  #t (err? bad)))

(display "all checks passed.") (newline)
