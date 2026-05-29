; orch-index-smoke.lisp — offline test for the two-stage index/query split (zepo-frz).
;
; The load-bearing assumption: building an index, persisting it with
; store-save, then store-load-ing it yields a store that retrieves
; identically — float vectors and chunk metadata survive the JSON round-trip.
; If this holds, the query stage can skip all corpus embedding and just load.
;
; Offline: a text-dependent stub embedder (no Ollama).
;
; Run:
;   zepo examples/orch-index-smoke.lisp
;
; zepo-frz

(import :libs (orch/registry     (reset-registry!) ; zepo-y1a4
               orch/vector_store (store-search store-save store-load store-size)
               orch/corpus       (resolve-sources build-index-with)))

(define cache "/tmp/orch-index-smoke-cache.json")
(define store-path "/tmp/orch-index-smoke-store.json")
(shell (string-append "rm -f " cache " " store-path))

; text-dependent stub: vector keyed on length + first byte so chunks differ.
(define (stub text)
  (ok (vector (exact->inexact (string-length text))
              (exact->inexact (if (> (string-length text) 0) (char->integer (string-ref text 0)) 0))
              1.0)))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want) (display " got=") (display got) (newline)
          (exit 1))))

(define sources (result-value (resolve-sources "lib/orch/**/*.lisp")))
(define mem-store (result-value (build-index-with sources stub cache)))

(define q (result-value (stub "how does the executor run parallel steps")))

(define (top-id store) (car (cdr (car (store-search store q 1)))))  ; (score . (id . meta)) -> id

; --- persist + reload, retrieval must be identical ---
(define saved (store-save mem-store store-path))
(assert-eq "store-save ok" #t (ok? saved))

(define loaded (result-value (store-load store-path)))
(assert-eq "size round-trips"   (store-size mem-store) (store-size loaded))
(assert-eq "top hit round-trips" (top-id mem-store)    (top-id loaded))

; --- loaded chunk metadata is intact (path + text usable for grep/synthesis) ---
(let ((meta (cdr (cdr (car (store-search loaded q 1))))))
  (assert-eq "meta has path" #t (string? (hash-get meta "path")))
  (assert-eq "meta has text" #t (string? (hash-get meta "text"))))

(display "all checks passed.") (newline)
