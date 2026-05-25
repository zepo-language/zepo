; lib/orch/rerank.lisp — hybrid lexical rerank for retrieval results.
;
; Embeddings rank semantically-related chunks well but under-rank chunks that
; contain the EXACT identifiers a question names (e.g. "approved?" / "run-
; parallel"). This blends each chunk's embedding score with the fraction of
; query terms that appear in its text and re-sorts, lifting exact-identifier
; matches. Pure — no embeddings, fully offline-testable.
;
; Usage: (rerank query-text hits [boost])  where hits is store-search output
;   (cons score (cons id meta)) and meta has a "text" field. boost defaults
;   to 0.5: blended = embedding-score + boost * lexical-score.
;
; zepo-546

(module orch/rerank
  (export rerank query-terms lexical-score)

  (define default-boost 0.5)

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
