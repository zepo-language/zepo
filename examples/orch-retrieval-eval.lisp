; orch-retrieval-eval.lisp — retrieval-quality measurement harness (zepo-546).
;
; A small fixture of questions over lib/orch, each with the file that best
; answers it (ground truth). Builds the cross-file index, runs retrieval, and
; reports recall@k: the fraction of questions whose top-k retrieved chunks
; include at least one chunk from the correct file. This is the before/after
; yardstick for any retrieval-quality lever (rerank, chunk boundaries, k).
;
; Requires Ollama on localhost:11434 with nomic-embed-text.
;
; Run:
;   zepo examples/orch-retrieval-eval.lisp
;
; zepo-546

(import :libs (orch/embed        (embed-text) ; zepo-y1a4
               orch/vector_store (store-size store-search)
               orch/corpus       (resolve-sources build-index)
               orch/rerank       (rerank)))

; (question file-substr answering-keyword) — the keyword must appear in the
; chunk that actually answers the question, so we measure CHUNK-level recall
; and rank, not just whether the right file shows up.
(define fixture
  (list
    (list "how does the planner retry when the model returns invalid output?" "planner.lisp"     "try-plan")
    (list "where is cosine similarity between vectors computed?"              "vector_store.lisp" "cos-sim")
    (list "how is a mutating tool approved before it runs?"                   "approval.lisp"     "approved?")
    (list "how does the executor run plan steps in parallel?"                 "exec.lisp"         "run-parallel")
    (list "how does edit_file keep writes inside an allowed root?"            "tools.lisp"        "confine")
    (list "how does the agent loop decide when to finish?"                    "agent.lisp"        "pending")
    (list "how are source files chunked by line range?"                      "chunker.lisp"      "chunk-text")
    (list "how is a run's context saved and resumed?"                         "persist.lisp"      "save-ctx")))

(define sources (result-value (resolve-sources "lib/orch/**/*.lisp")))
(define store   (result-value (build-index sources)))
(display "indexed ") (display (store-size store)) (display " chunks") (newline)

; rank (1-based) of the first hit whose chunk TEXT contains the keyword, or 0.
(define (keyword-rank hits keyword)
  (let loop ((hs hits) (r 1))
    (cond
      ((null? hs) 0)
      ((string-contains (hash-get (cdr (cdr (car hs))) "text") keyword) r)
      (else (loop (cdr hs) (+ r 1))))))

; take first k of a list
(define (take-k xs k)
  (if (or (= k 0) (null? xs)) '() (cons (car xs) (take-k (cdr xs) (- k 1)))))

; Evaluate top-k. If `rerank?`, retrieve a wider candidate set (k*4) and apply
; the lexical rerank before taking the top-k.
; Pre-embed all queries once (cache), so a boost sweep doesn't re-hit Ollama.
(define qembeds (map (lambda (row) (cons row (result-value (embed-text (car row))))) fixture))

; boost = #f -> embedding only; otherwise hybrid rerank with that boost.
(define (eval-boost k boost label)
  (let loop ((qs qembeds) (hits 0) (mrr 0.0) (n 0))
    (cond
      ((null? qs)
       (display label) (display "  recall@") (display k) (display ": ")
       (display hits) (display "/") (display n)
       (display "   MRR: ") (display (/ mrr n)) (newline))
      (else
        (let* ((row (car (car qs)))
               (qe  (cdr (car qs)))
               (kw  (car (cdr (cdr row))))
               (top (if boost
                        (take-k (rerank (car row) (store-search store qe (* k 4)) boost) k)
                        (store-search store qe k)))
               (rnk (keyword-rank top kw)))
          (loop (cdr qs) (if (> rnk 0) (+ hits 1) hits)
                (if (> rnk 0) (+ mrr (/ 1.0 rnk)) mrr) (+ n 1)))))))

(display "=== boost sweep @5 ===") (newline)
(eval-boost 5 #f   "baseline    ")
(eval-boost 5 0.05 "hybrid b=.05")
(eval-boost 5 0.10 "hybrid b=.10")
(eval-boost 5 0.15 "hybrid b=.15")
(eval-boost 5 0.20 "hybrid b=.20")
(eval-boost 5 0.30 "hybrid b=.30")
