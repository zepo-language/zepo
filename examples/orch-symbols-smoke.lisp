; orch-symbols-smoke.lisp — offline tests for lib/orch/symbols.lisp (zepo-6vo).
;
; Symbol index: extract definition sites from Zepo source and answer
; find-def / find-refs precisely. Identifier-aware (Zepo identifiers include
; - ! ? * + < > = /), so matching is on WHOLE identifiers, not substrings:
; "run" must not match "run-parallel".
;
; Run:
;   zepo examples/orch-symbols-smoke.lisp
;
; zepo-6vo

(import :libs (orch/symbols))

(define tree "/tmp/zepo-6vo-tree")
(shell (string-append
         "rm -rf " tree " && mkdir -p " tree " && "
         "printf '(define (make-worker x)\\n  (spawn loop))\\n(define limit 5)\\n' > " tree "/a.lisp && "
         "printf '(define (run-parallel steps)\\n  (make-worker steps))\\n(define (ok? v) v)\\n' > " tree "/b.lisp"))

(define sources (list (string-append tree "/a.lisp") (string-append tree "/b.lisp")))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want) (display " got=") (display got) (newline)
          (exit 1))))

(define idx (build-symbol-index sources))

; --- find-def: definition sites ---
(let ((d (find-def "make-worker" idx)))
  (assert-eq "make-worker defined once" 1 (length d))
  (assert-eq "make-worker def file"     #t (string-suffix? "a.lisp" (car (car d))))
  (assert-eq "make-worker def line"     1  (cdr (car d))))
(assert-eq "limit defined"        1 (length (find-def "limit" idx)))
(assert-eq "run-parallel defined" 1 (length (find-def "run-parallel" idx)))
(assert-eq "special-char def ok?" 1 (length (find-def "ok?" idx)))
(assert-eq "unknown symbol"       0 (length (find-def "nonexistent" idx)))

; --- find-refs: whole-identifier occurrences across files ---
(let ((r (find-refs "make-worker" sources)))
  (assert-eq "make-worker refs (def + call)" 2 (length r)))   ; a.lisp def + b.lisp call

; "run" must NOT match inside "run-parallel" (substring guard)
(assert-eq "run is not a substring match" 0 (length (find-refs "run" sources)))
; whole identifier with special char matches
(assert-eq "ok? whole-id ref" #t (>= (length (find-refs "ok?" sources)) 1))

(display "all checks passed.") (newline)
