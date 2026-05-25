; orch-symtools-smoke.lisp — offline test for find_def/find_refs tools in the
; research loop (zepo-fzi).
;
; The loop can now chase cross-references precisely: find_def {name} surfaces a
; symbol's definition (location + code window) and find_refs {name} its use
; sites, both appended to the synthesis context. Deterministic, no Ollama
; (stubbed planner/embed/synth).
;
; Run:
;   zepo examples/orch-symtools-smoke.lisp
;
; zepo-fzi

(import :libs (orch/registry))
(import :libs (orch/exec))
(import :libs (orch/agent))
(import :libs (orch/vector_store))
(import :libs (orch/corpus))
(import :libs (orch/research))

(define tree  "/tmp/zepo-fzi-tree")
(define cache "/tmp/zepo-fzi-cache.json")
(shell (string-append
         "rm -rf " tree " " cache " && mkdir -p " tree " && "
         "printf '(define (make-worker x)\\n  (spawn loop))\\n' > " tree "/a.lisp && "
         "printf '(define (run-it)\\n  (make-worker 1))\\n' > " tree "/b.lisp"))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want) (display " got=") (display got) (newline)
          (exit 1))))

(define sources (result-value (resolve-sources tree)))
(define (const-embed t) (ok (vector 1.0 0.0 0.0)))
(define store (result-value (build-index-with sources const-embed cache)))

; stub planner: find_def make-worker, then find_refs make-worker, then finish.
(define (stub-ns goal history ctx)
  (cond ((null? ctx)            '(tool-call "d1" find_def  ((name . "make-worker"))))
        ((not (assoc "r1" ctx)) '(tool-call "r1" find_refs ((name . "make-worker"))))
        (else                   (list 'finish "done"))))

(define synth-ctx (vector ""))
(define (stub-synth goal context) (vector-set! synth-ctx 0 context) (ok "answer"))
(define (has? s sub) (if (string-contains s sub) #t #f))

(let ((r (research-with "explain make-worker" sources store stub-ns const-embed stub-synth)))
  (assert-eq "research returns answer"   '(ok . "answer") r)
  (assert-eq "synthesis saw find_def"    #t (has? (vector-ref synth-ctx 0) "find_def"))
  (assert-eq "find_def shows def site"   #t (has? (vector-ref synth-ctx 0) "a.lisp"))
  (assert-eq "find_def shows def code"   #t (has? (vector-ref synth-ctx 0) "make-worker"))
  (assert-eq "synthesis saw find_refs"   #t (has? (vector-ref synth-ctx 0) "find_refs"))
  (assert-eq "find_refs shows call site" #t (has? (vector-ref synth-ctx 0) "b.lisp")))

(display "all checks passed.") (newline)
