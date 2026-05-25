; orch-gc-safepoint-regress.lisp — regression for zepo-jus.
;
; The GC safepoint root map must track EVERY value-producing op (notably
; `move` and `push_handler`), or a heap Value held only in such a register
; across a GC triggered inside a guarded tool call gets corrupted. Pre-fix
; this deterministically crashes with a TypeError in lookup-tool when the
; registry hash-table is the corrupted object.
;
; Deterministic trigger: a COLD embedding cache forces heavy allocation
; during build-index (heap pressure), then a guarded tool (call-tool wraps
; tools in `guard`) does its own heavy allocation, tripping a GC.
;
; Offline (stub embedder) — no Ollama needed.
;
; Run:
;   zepo examples/orch-gc-safepoint-regress.lisp
;
; zepo-jus

(import :libs (orch/registry))
(import :libs (orch/exec))
(import :libs (orch/agent))
(import :libs (orch/vector_store))
(import :libs (orch/corpus))

(define cache "/tmp/zepo-jus-regress-cache.json")
(shell (string-append "rm -f " cache))            ; cold cache => heap pressure each run

(define sources (result-value (resolve-sources "lib/orch/**/*.lisp")))
(define store
  (result-value (build-index-with sources (lambda (t) (ok (vector 1.0 0.0 0.0))) cache)))

(reset-registry!)
(register-tool! 'heavy
                (lambda (a)
                  (let loop ((fs sources) (n 0))
                    (if (null? fs)
                        (ok (number->string n))
                        (loop (cdr fs)
                              (+ n (length (string-split (file-read-string (car fs)) "\n")))))))
                :effect 'read)

(define (ns g h ctx)
  (cond ((null? ctx) '(tool-call "h1" heavy ()))
        (else (list 'finish "done"))))

; Running the guarded heavy tool under heap pressure must NOT corrupt the
; module-global registry; the loop's post-call tool-effect/lookup-tool then
; succeeds.
(define r (run-agent "x" 4 ns))

(cond
  ((and (pair? r) (eq? (car r) 'ok))
   (display "OK  guarded heavy-alloc tool did not corrupt the registry") (newline))
  (else
   (display "FAIL unexpected result: ") (write r) (newline) (exit 1)))
