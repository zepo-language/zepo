; examples/index-repo.lisp — INIT stage for the code-understanding tool.
;
; Embeds a repo / spec ONCE and persists the assembled vector store, so
; explain.lisp queries load it instantly instead of re-embedding the corpus
; every time. Re-run after code changes: the per-file mtime+size cache means
; only changed files are re-embedded.
;
; Writes .zepo-index/store.json (vectors + chunk metadata) and
; .zepo-index/sources.json (the file list, used by grep at query time).
;
; Requires Ollama on localhost:11434 with nomic-embed-text.
;
; Run:
;   zepo examples/index-repo.lisp -- <spec>
;   zepo examples/index-repo.lisp -- "lib/orch/**/*.lisp"
;   zepo examples/index-repo.lisp -- :repo
;
; zepo-frz

(import :libs (orch/corpus       (resolve-sources build-index) ; zepo-y1a4
               orch/vector_store (store-save store-size)))

(define store-path   ".zepo-index/store.json")
(define sources-path ".zepo-index/sources.json")

(define raw-argv (argv))
(define args (if (>= (length raw-argv) 3) (cddr raw-argv) '()))
(cond
  ((< (length args) 1)
   (display "usage: zepo examples/index-repo.lisp -- <spec>") (newline) (exit 1)))

(define spec (car args))
(define srcs (resolve-sources spec))
(cond
  ((err? srcs)
   (display "resolve error: ") (display (err-message srcs)) (newline) (exit 1)))
(define sources (result-value srcs))

(define t0 (current-time-ms))
(display "── indexing ") (display (length sources))
(display " files (embedding new/changed files)…") (newline)

(define idx (build-index sources))
(cond
  ((err? idx)
   (display "index error: ") (display (err-message idx)) (newline) (exit 1)))
(define store (result-value idx))

(make-directory ".zepo-index")
(store-save store store-path)
(file-write-string sources-path
                   (result-value (json-stringify (list->vector sources))))

(display "── indexed ") (display (store-size store)) (display " chunks -> ")
(display store-path) (display "  (") (display (- (current-time-ms) t0)) (display " ms)")
(newline)
(display "── now query with:  zepo examples/explain.lisp -- \"<question>\"") (newline)
