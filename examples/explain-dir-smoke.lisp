; explain-dir-smoke.lisp — END-TO-END cross-file indexing with real nomic
; embeddings. Indexes lib/orch (multiple files) into one store via the
; per-file cache, then runs a semantic query and checks the top hit comes
; from the file that actually covers the topic.
;
; Requires Ollama on localhost:11434 with nomic-embed-text pulled.
; First run embeds the corpus (~tens of seconds); the cache makes re-runs
; fast.
;
; Run:
;   zepo examples/explain-dir-smoke.lisp
;
; zepo-1j2

(import :libs (orch/embed))
(import :libs (orch/vector_store))
(import :libs (orch/corpus))

; Index lib/orch via glob (base dir + .lisp extension), cache under /tmp.
(define sources (result-value (resolve-sources "lib/orch/**/*.lisp")))
(display "indexing ") (display (length sources)) (display " files…") (newline)

(define store
  (result-value (build-index-with sources embed-text "/tmp/zepo-1j2-orch-cache.json")))
(display "store chunks: ") (display (store-size store)) (newline)

; Semantic query that should land on vector_store.lisp (cosine/top-k search).
(define q (result-value (embed-text "cosine similarity top-k vector search")))
(define hits (store-search store q 3))

(display "top-3:") (newline)
(for-each
  (lambda (h)
    (let ((score (car h))
          (meta  (cdr (cdr h))))
      (display "  ") (display score) (display "  ")
      (display (hash-get meta "path")) (newline)))
  hits)

(define top-path (hash-get (cdr (cdr (car hits))) "path"))
(cond
  ((string-contains top-path "vector_store")
   (display "OK  top hit is vector_store.lisp (cross-file retrieval works)") (newline))
  (else
   (display "FAIL  expected vector_store.lisp, got ") (display top-path) (newline)
   (exit 1)))
