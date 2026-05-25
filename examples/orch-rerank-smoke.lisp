; orch-rerank-smoke.lisp — offline unit tests for lib/orch/rerank.lisp (zepo-546).
;
; Hybrid lexical rerank: blends a chunk's embedding score with how many query
; terms appear in its text, so chunks that contain the exact identifiers a
; question names (which embeddings rank poorly) move up. Pure — no embeddings.
;
; Run:
;   zepo examples/orch-rerank-smoke.lisp
;
; zepo-546

(import :libs (orch/rerank))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want) (display " got=") (display got) (newline)
          (exit 1))))

; store-search hit shape: (cons score (cons id meta)), meta has "text".
(define (mk-hit score text)
  (let ((h (make-hash-table)))
    (hash-set! h "text" text)
    (cons score (cons "id" h))))

; --- query-terms: lowercase, drop stopwords + short tokens, keep identifiers ---
(let ((ts (query-terms "How does the agent decide to FINISH a run_loop?")))
  (assert-eq "drops stopwords"   #f (if (member "the" ts) #t #f))
  (assert-eq "keeps content"     #t (if (member "finish" ts) #t #f))
  (assert-eq "keeps identifier"  #t (if (member "run_loop" ts) #t #f)))

; --- lexical-score: fraction of query terms present in text ---
(assert-eq "all terms present" 1.0 (lexical-score "x approved y mutating z" '("approved" "mutating")))
(assert-eq "no terms present"  0.0 (lexical-score "nothing relevant here"   '("approved" "mutating")))
(assert-eq "substring match"   1.0 (lexical-score "the approved? form"      '("approved")))

; --- rerank promotes a lexical match above a higher-embedding non-match ---
(let* ((a (mk-hit 0.90 "completely unrelated prose"))
       (b (mk-hit 0.60 "approved mutating tool guard"))
       (ranked (rerank "approved mutating tool" (list a b) 1.0)))
  (assert-eq "lexical match ranks first" 0.60 (car (car ranked))))

; --- with no query terms matching, original embedding order is preserved ---
(let* ((a (mk-hit 0.90 "alpha"))
       (b (mk-hit 0.60 "beta"))
       (ranked (rerank "zzz nomatch qqq" (list a b) 1.0)))
  (assert-eq "no lexical signal keeps embedding order" 0.90 (car (car ranked))))

(display "all checks passed.") (newline)
