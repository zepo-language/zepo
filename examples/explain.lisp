; examples/explain.lisp — cross-file, multi-hop code explanation.
;
; The iterative, cross-file successor to explain-file.lisp. Resolves a
; source spec (file / directory / glob / :repo), builds a cached embedding
; index (orch/corpus), then runs the multi-hop research loop (orch/research):
; retrieve to locate, grep to chase exact symbols across files, then a code
; model synthesizes a grounded answer. Read-only — it never modifies anything.
;
; Requires Ollama on localhost:11434 with nomic-embed-text + qwen2.5-coder:7b.
;
; Run:
;   zepo examples/explain.lisp -- <spec> "<question>"
;   zepo examples/explain.lisp -- lib/orch "how does the planner feed errors back, and where is the validator it calls defined?"
;
; zepo-t40

(import :libs (orch/corpus))
(import :libs (orch/research))

(define raw-argv (argv))
(define args (if (>= (length raw-argv) 4) (cddr raw-argv) '()))

(cond
  ((< (length args) 2)
   (display "usage: zepo examples/explain.lisp -- <spec> \"<question>\"") (newline)
   (exit 1)))

(define spec     (car args))
(define question (cadr args))

(define srcs (resolve-sources spec))
(cond
  ((err? srcs)
   (display "resolve error: ") (display (err-message srcs)) (newline) (exit 1)))
(define sources (result-value srcs))

(display "── indexing ") (display (length sources)) (display " files…") (newline)
(define idx (build-index sources))
(cond
  ((err? idx)
   (display "index error: ") (display (err-message idx)) (newline) (exit 1)))
(define store (result-value idx))

(display "── researching (retrieve + grep, multi-hop)…") (newline)
(define answer (research question sources store))

(newline)
(cond
  ((ok? answer) (display (result-value answer)) (newline))
  (else
   (display "research error: ") (display (err-message answer)) (newline) (exit 1)))
