; lib/orch/rerank.lisp — hybrid rerank for retrieval results.
;
; Blends a chunk's embedding score with query-term overlap (lexical / whole-
; identifier) and an optional file hotspot signal, re-sorting to lift chunks
; that name the question's identifiers. Pure — no embeddings, offline-testable.
;
; MEASURED RESULT (zepo-546 lexical, zepo-ecq structural): on the
; orch-retrieval-eval fixture this does NOT beat the embedding-only baseline
; (recall@5 8/8, MRR 0.76). Lexical boost 0.5 hurt; structural (whole-id +
; hotspot) gave MRR 0.63, recall 7/8. Baseline retrieval is already strong
; (the real ranking fix was retrieve-k=6, not reranking), so this module is
; built + tested but NOT wired into retrieve_code — wiring it would regress.
; Kept as a measured capability for other query types / future tuning against
; the eval harness. Structural signals' real payoff is the find_def/find_refs
; tools (zepo-fzi) and co-change for multi-hop expansion, not query reranking.
;
; Usage: (rerank query-text hits [boost])  where hits is store-search output
;   (cons score (cons id meta)) and meta has a "text" field. boost defaults
;   to 0.5: blended = embedding-score + boost * lexical-score.
;
; zepo-546

(module orch/rerank
  (export rerank query-terms lexical-score
          structural-rerank whole-id-score)

  (define default-boost 0.5)

  ; zepo-ecq: structural rerank for query->chunk retrieval. Blends embedding
  ; score with WHOLE-IDENTIFIER query-term overlap (the disciplined fix over
  ; the substring lexical-score, which over-matched and hurt MRR) and a file
  ; hotspot signal. Co-change is file->file with no query anchor, so it is NOT
  ; used here (it belongs to multi-hop expansion, not query ranking).
  ; hotspot-fn : path -> [0,1].  Decorate-sort: score computed once per hit.
  (define (structural-rerank query hits hotspot-fn w-lex w-hot)
    (let* ((terms  (query-terms query))
           (scored (map (lambda (h)
                          (let ((meta (cdr (cdr h))))
                            (cons (+ (car h)
                                     (* w-lex (whole-id-score (hash-get meta "text") terms))
                                     (* w-hot (hotspot-fn (hash-get meta "path"))))
                                  h)))
                        hits)))
      (map cdr (sort scored (lambda (a b) (> (car a) (car b)))))))

  ; Fraction of `terms` present in `text` as WHOLE identifiers (bounded by
  ; non-identifier chars), so "run" does not match "run-parallel".
  (define (whole-id-score text terms)
    (cond
      ((null? terms) 0.0)
      (else
        (let ((low (string-downcase text)))
          (let loop ((ts terms) (hits 0))
            (cond
              ((null? ts) (/ (exact->inexact hits) (length terms)))
              ((whole-occ? low (car ts)) (loop (cdr ts) (+ hits 1)))
              (else (loop (cdr ts) hits))))))))

  (define (whole-occ? line name)
    (let ((nl (string-length name)) (ll (string-length line)))
      (let loop ((start 0))
        (cond
          ((>= start ll) #f)
          (else
            (let ((rel (string-contains (substring line start) name)))
              (cond
                ((not rel) #f)
                (else
                  (let ((p (+ start rel)))
                    (if (and (occ-boundary? line (- p 1)) (occ-boundary? line (+ p nl)))
                        #t
                        (loop (+ p 1))))))))))))

  (define (occ-boundary? line i)
    (or (< i 0) (>= i (string-length line)) (not (occ-id-char? (string-ref line i)))))

  (define (occ-id-char? c)
    (or (and (char>=? c #\a) (char<=? c #\z))
        (and (char>=? c #\0) (char<=? c #\9))
        (and (member c (list #\- #\_ #\! #\? #\* #\+ #\< #\> #\= #\/ #\. #\:)) #t)))

  ; Re-sort hits by blended score (descending). A stable embedding-only order
  ; is preserved when no query terms match (lexical-score 0 for all).
  ; Decorate-sort-undecorate: blended (which downcases the chunk text) is
  ; computed ONCE per hit, not on every sort comparison — otherwise lexical-
  ; score re-downcases each chunk O(n log n) times and dominates runtime.
  (define (rerank query-text hits . opt)
    (let* ((terms  (query-terms query-text))
           (boost  (if (null? opt) default-boost (car opt)))
           (scored (map (lambda (h) (cons (blended h terms boost) h)) hits)))
      (map cdr (sort scored (lambda (a b) (> (car a) (car b)))))))

  (define (blended hit terms boost)
    (+ (car hit)
       (* boost (lexical-score (hash-get (cdr (cdr hit)) "text") terms))))

  ; Fraction of `terms` that appear (case-insensitively, as substrings) in
  ; `text`. Substring match so a query term "approved" hits code "approved?".
  (define (lexical-score text terms)
    (cond
      ((null? terms) 0.0)
      (else
        (let ((low (string-downcase text)))
          (let loop ((ts terms) (hits 0))
            (cond
              ((null? ts) (/ (exact->inexact hits) (length terms)))
              ((string-contains low (car ts)) (loop (cdr ts) (+ hits 1)))
              (else (loop (cdr ts) hits))))))))

  ; Tokenize a query into content terms: lowercased, identifier chars kept
  ; ([a-z0-9_-]), tokens shorter than 3 chars and stopwords dropped.
  (define (query-terms query)
    (let loop ((ws (split-words (string-downcase query))) (acc '()))
      (cond
        ((null? ws) (reverse acc))
        (else
          (let ((w (clean-token (car ws))))
            (cond
              ((and (>= (string-length w) 3) (not (stopword? w)) (not (member w acc)))
               (loop (cdr ws) (cons w acc)))
              (else (loop (cdr ws) acc))))))))

  ; ── helpers ───────────────────────────────────────────────────────────────

  ; Split on whitespace into raw words.
  (define (split-words s)
    (let loop ((i 0) (start 0) (n (string-length s)) (acc '()))
      (cond
        ((>= i n)
         (reverse (if (> i start) (cons (substring s start i) acc) acc)))
        ((ws-char? (string-ref s i))
         (loop (+ i 1) (+ i 1) n (if (> i start) (cons (substring s start i) acc) acc)))
        (else (loop (+ i 1) start n acc)))))

  ; Keep only identifier chars [a-z0-9_-]; drop surrounding punctuation.
  (define (clean-token w)
    (let loop ((i 0) (n (string-length w)) (out ""))
      (cond
        ((>= i n) out)
        ((id-char? (string-ref w i))
         (loop (+ i 1) n (string-append out (substring w i (+ i 1)))))
        (else (loop (+ i 1) n out)))))

  (define (ws-char? c)
    (or (char=? c #\space) (char=? c #\tab) (char=? c #\newline) (char=? c #\return)))

  (define (id-char? c)
    (or (and (char>=? c #\a) (char<=? c #\z))
        (and (char>=? c #\0) (char<=? c #\9))
        (char=? c #\_) (char=? c #\-)))

  (define stopwords
    '("the" "and" "for" "are" "how" "does" "did" "when" "where" "what" "why"
      "who" "its" "his" "her" "you" "use" "used" "uses" "into" "from" "with"
      "that" "this" "these" "those" "then" "than" "but" "not" "can" "will"
      "before" "after" "during" "between" "about" "over" "under" "out"))

  (define (stopword? w)
    (and (member w stopwords) #t)))
