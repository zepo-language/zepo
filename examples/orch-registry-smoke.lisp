; orch-registry-smoke.lisp — manual smoke test for lib/orch/registry.lisp.
;
; Exercises register / lookup / validate / call-tool / unregister and
; verifies the typed-error contract on invalid args and tool failures.
;
; Run:
;   zepo examples/orch-registry-smoke.lisp
;
; zepo-acn

(import :libs (orch/registry))

(reset-registry!)

(define (assert-eq label want got)
  (cond
    ((equal? want got)
     (display "OK  ") (display label) (newline))
    (else
     (display "FAIL ") (display label)
     (display "  want=") (display want)
     (display "  got=") (display got) (newline)
     (exit 1))))

; --- happy path ---------------------------------------------------------------
(register-tool! 'echo
  (lambda (args) (cdr (assoc 'message args)))
  :inputs '((message . string)))

(define e (lookup-tool 'echo))
(assert-eq "echo lookup non-false" #t (not (not e)))
(assert-eq "echo call"
  '(ok . "hi")
  (call-tool e (list (cons 'message "hi"))))

; --- typed errors -------------------------------------------------------------
(let ((r (call-tool e (list))))
  (assert-eq "missing arg is err" #t (err? r))
  (assert-eq "missing arg kind"   'invalid-args (err-kind r)))

(let ((r (call-tool e (list (cons 'message 42)))))
  (assert-eq "wrong-type is err" #t (err? r))
  (assert-eq "wrong-type kind"   'invalid-args (err-kind r)))

(assert-eq "unknown lookup is #f" #f (lookup-tool 'nope))

; --- 'any type ---------------------------------------------------------------
(register-tool! 'pass (lambda (a) (cdr (assoc 'x a))) :inputs '((x . any)))
(assert-eq "any/int"  '(ok . 42)        (call-tool (lookup-tool 'pass) (list (cons 'x 42))))
(assert-eq "any/list" '(ok 1 2)         (call-tool (lookup-tool 'pass) (list (cons 'x '(1 2)))))

; --- tool that raises --------------------------------------------------------
(register-tool! 'boom (lambda (a) (error "kaboom")) :inputs '())
(let ((r (call-tool (lookup-tool 'boom) '())))
  (assert-eq "tool error caught" #t (err? r))
  (assert-eq "tool error kind"   'tool-failure (err-kind r)))

; --- unregister --------------------------------------------------------------
(unregister-tool! 'boom)
(assert-eq "after unregister" #f (lookup-tool 'boom))

(display "all checks passed.") (newline)
