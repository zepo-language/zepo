; orch-registry-smoke.lisp — manual smoke test for lib/orch/registry.lisp.
;
; Exercises register / lookup / validate / call-tool / unregister and
; verifies the typed-error contract on invalid args and tool failures.
;
; Run:
;   zepo examples/orch-registry-smoke.lisp
;
; zepo-acn

(import :libs (orch/registry (register-tool! lookup-tool unregister-tool! ; zepo-y1a4
                              call-tool reset-registry!)))

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

; --- tool that returns an err tuple ----------------------------------------
; Tools that want fault isolation must return (err ...) themselves; the
; registry no longer wraps the call in guard because that breaks any
; tool that yields (sleep/HTTP/channel-recv) — see zepo-9bi.
(register-tool! 'fail (lambda (a) (err 'expected "no")) :inputs '())
(let ((r (call-tool (lookup-tool 'fail) '())))
  (assert-eq "tool err pass-through" #t (err? r))
  (assert-eq "tool err kind"         'expected (err-kind r)))

; --- raw value is auto-wrapped in (ok ...) ----------------------------------
(register-tool! 'raw (lambda (a) 99) :inputs '())
(assert-eq "auto-wrap raw" '(ok . 99) (call-tool (lookup-tool 'raw) '()))

; --- unregister --------------------------------------------------------------
(unregister-tool! 'fail)
(assert-eq "after unregister" #f (lookup-tool 'fail))

(display "all checks passed.") (newline)
