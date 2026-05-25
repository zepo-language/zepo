; examples/explain.lisp — QUERY stage of the code-understanding tool.
;
; Loads the vector store persisted by index-repo.lisp (.zepo-index/store.json)
; — NO corpus embedding — then runs the multi-hop research loop (orch/research):
; embed only the question, retrieve, grep to chase exact symbols, and a code
; model synthesizes a grounded answer. Read-only.
;
; Index first:  zepo examples/index-repo.lisp -- <spec>
; Then query:   zepo examples/explain.lisp   -- "<question>"
;
; Requires Ollama on localhost:11434 with nomic-embed-text + qwen2.5-coder:7b.
;
; zepo-frz

(import :libs (orch/vector_store))
(import :libs (orch/research))

(define store-path   ".zepo-index/store.json")
(define sources-path ".zepo-index/sources.json")

(define raw-argv (argv))
(define args (if (>= (length raw-argv) 3) (cddr raw-argv) '()))

(cond
  ((< (length args) 1)
   (display "usage: zepo examples/explain.lisp -- \"<question>\"") (newline)
   (display "  (run  zepo examples/index-repo.lisp -- <spec>  first)") (newline)
   (exit 1)))
(define question (car args))

(cond
  ((not (file-exists? store-path))
   (display "no index at ") (display store-path) (newline)
   (display "run:  zepo examples/index-repo.lisp -- <spec>") (newline)
   (exit 1)))

; --- load persisted index (no corpus embedding) ---
(define loaded (store-load store-path))
(cond
  ((err? loaded)
   (display "index load error: ") (display (err-message loaded)) (newline) (exit 1)))
(define store (result-value loaded))

; sources list (for grep_code) persisted alongside the store
(define (vec->list v)
  (let loop ((i (- (vector-length v) 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (vector-ref v i) acc)))))
(define sources
  (let ((p (json-parse (file-read-string sources-path))))
    (if (ok? p) (vec->list (result-value p)) '())))

; --- staleness: warn (non-fatal) if any source is newer than the index ---
(define store-mtime (or (file-mtime store-path) 0))
(define stale
  (let loop ((ss sources) (n 0))
    (cond
      ((null? ss) n)
      ((> (or (file-mtime (car ss)) 0) store-mtime) (loop (cdr ss) (+ n 1)))
      (else (loop (cdr ss) n)))))
(when (> stale 0)
  (display "⚠ ") (display stale)
  (display " source file(s) changed since indexing — re-run index-repo for fresh results.")
  (newline))

(display "── loaded ") (display (store-size store)) (display " chunks from index") (newline)
(display "── researching (retrieve + grep, multi-hop)…") (newline)
(define answer (research question sources store))

(newline)
(cond
  ((ok? answer) (display (result-value answer)) (newline))
  (else
   (display "research error: ") (display (err-message answer)) (newline) (exit 1)))
