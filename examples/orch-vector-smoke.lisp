; orch-vector-smoke.lisp — manual smoke test for lib/orch/vector_store.lisp.
;
; Builds a tiny in-memory index over hand-written sentences, queries it,
; round-trips through save/load, and prints the top hits. Requires a
; local Ollama with nomic-embed-text pulled.
;
; Run:
;   zepo examples/orch-vector-smoke.lisp
;
; zepo-rrh

(import :libs (orch/embed        (embed-text) ; zepo-y1a4
               orch/vector_store (make-store store-add! store-search
                                  store-save store-load)))

(define corpus
  (list
    (cons "doc1" "Cats love to nap in the sun")
    (cons "doc2" "Felines enjoy sunny afternoon sleeps")
    (cons "doc3" "Graph theory and combinatorial optimization")
    (cons "doc4" "Dogs run in the park")
    (cons "doc5" "Lisp macros and the syntax-rules system")))

(define s (make-store))

(for-each
  (lambda (row)
    (let ((id (car row)) (text (cdr row)))
      (let ((emb (embed-text text)))
        (when (ok? emb)
          (store-add! s id (result-value emb)
                      (list (cons "text" text)))))))
  corpus)

(define (show-hits hits)
  (for-each
    (lambda (h)
      (let ((score (car h))
            (id    (car (cdr h)))
            (meta  (cdr (cdr h))))
        (display "  ") (display score) (display "  ")
        (display id) (display " — ")
        (display (hash-get meta "text")) (newline)))
    hits))

(define query "sleeping pets")
(display "query: ") (display query) (newline)
(define qe (embed-text query))
(when (err? qe) (display "embed failed") (newline) (exit 1))
(show-hits (store-search s (result-value qe) 3))

; Round-trip through disk.
(define save-r (store-save s "/tmp/orch_vs_smoke.json"))
(when (err? save-r) (display "save failed") (newline) (exit 1))

(define load-r (store-load "/tmp/orch_vs_smoke.json"))
(when (err? load-r) (display "load failed") (newline) (exit 1))
(define s2 (result-value load-r))
(display "after reload, top-3:") (newline)
(show-hits (store-search s2 (result-value qe) 3))
