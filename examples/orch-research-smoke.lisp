; orch-research-smoke.lisp — offline smoke for lib/orch/research.lisp.
;
; Covers the pure grep-sources scanner and the full research flow with an
; injected next-step (planner), embed fn, and synth fn — so the retrieve ->
; grep -> finish -> synthesize pipeline runs deterministically without Ollama.
;
; Run:
;   zepo examples/orch-research-smoke.lisp
;
; zepo-t40

(import :libs (orch/registry     (reset-registry!) ; zepo-y1a4 / zepo-0um3 (register-tool! workaround removed)
               orch/exec         (run-plan)
               orch/agent        (run-agent)
               orch/vector_store (store-size)
               orch/corpus       (resolve-sources build-index-with)
               orch/research     (grep-sources research-with)))

(define tree  "/tmp/zepo-t40-tree")
(define cache "/tmp/zepo-t40-cache.json")
(shell (string-append
         "rm -rf " tree " " cache " && mkdir -p " tree " && "
         "printf 'def make-worker\\n  spawn loop\\n'        > " tree "/worker.lisp && "
         "printf 'call make-worker here\\nshutdown later\\n' > " tree "/main.lisp"))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want)
          (display " got=") (display got) (newline)
          (exit 1))))

(define sources (result-value (resolve-sources tree)))   ; worker.lisp + main.lisp

; --- grep-sources: finds a symbol with path+line, misses absent ones ---
(let ((hits (grep-sources "make-worker" sources)))
  (assert-eq "grep finds 2 occurrences" 2 (length hits)))   ; def + call site, across 2 files
(let ((hits (grep-sources "nonexistent-symbol-xyz" sources)))
  (assert-eq "grep misses absent" 0 (length hits)))

; --- full research flow: retrieve -> grep -> finish -> synthesize ---
(define (const-embed text) (ok (vector 1.0 0.0 0.0)))
(define store (result-value (build-index-with sources const-embed cache)))

; stubbed planner: retrieve, then grep, then finish
(define (stub-ns goal history ctx)
  (cond ((null? ctx)            '(tool-call "r1" retrieve_code ((query . "make-worker"))))
        ((not (assoc "g1" ctx)) '(tool-call "g1" grep_code ((pattern . "make-worker"))))
        (else                   (list 'finish "done"))))

; stubbed synthesis records the context it was handed
(define synth-ctx (vector ""))
(define (stub-synth goal context)
  (vector-set! synth-ctx 0 context)
  (ok "synth-answer"))

(define (has? s sub) (if (string-contains s sub) #t #f))

(let ((r (research-with "how does make-worker work"
                        sources store stub-ns const-embed stub-synth)))
  (assert-eq "research returns synth answer" '(ok . "synth-answer") r)
  (assert-eq "synthesis saw retrieve hits" #t (has? (vector-ref synth-ctx 0) "retrieve "))
  (assert-eq "synthesis saw grep hits"     #t (has? (vector-ref synth-ctx 0) "grep "))
  (assert-eq "grep hit cites worker.lisp"  #t (has? (vector-ref synth-ctx 0) "worker.lisp")))

(display "all checks passed.") (newline)
