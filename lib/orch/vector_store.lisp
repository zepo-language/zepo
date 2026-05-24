; lib/orch/vector_store.lisp — flat in-memory vector store with cosine top-k.
;
; Suitable for the v1 orchestrator's retrieval needs: <100k chunks, 768-dim
; nomic-embed-text vectors, single-process. Brute-force O(n) per query.
; Norms precomputed at insert time so search is just dot products + a sort.
;
; Persisted as JSON. An s-expr format would be slightly tighter but Zepo
; has no read-from-string primitive; JSON has both halves available natively.
;
; zepo-rrh

(module orch/vector_store
  (export make-store store-add! store-search store-size
          store-save store-load
          cos-sim)

  ; A store is just a hash-table id -> #(embedding norm metadata).
  ; Wrapping in a vector lets us add fields later without breaking callers.
  (define (make-store)
    (vector (make-hash-table)))

  (define (store-table s) (vector-ref s 0))

  (define (store-size s)
    (hash-size (store-table s)))

  ; Add or replace an entry. id should be a string (used as dict key).
  ; vec is a vector of numbers (any dim; all vectors in one store must match).
  ; metadata may be an alist or a hash-table; it is normalised to a
  ; hash-table internally so callers can always retrieve fields with
  ; hash-get regardless of whether the store was just built or loaded
  ; from disk.
  (define (store-add! s id vec metadata)
    (let ((n (vec-norm vec))
          (m (normalise-meta metadata)))
      (hash-set! (store-table s) id (vector vec n m))))

  (define (normalise-meta m)
    (cond
      ((hash-table? m) m)
      ((pair? m)        (alist->hash m))
      (else             m))) ; pass through anything else (string, symbol, etc.)

  (define (alist->hash al)
    (let ((h (make-hash-table)))
      (for-each
        (lambda (kv)
          (when (pair? kv) (hash-set! h (car kv) (cdr kv))))
        al)
      h))

  ; Return list of (cons score (cons id metadata)) for the top-k closest
  ; entries to query-vec by cosine similarity, sorted descending.
  ; Linear scan; for v1 sizes this is well under a millisecond per 1k rows.
  (define (store-search s query-vec k)
    (let ((qn (vec-norm query-vec))
          (results '()))
      (hash-for-each
        (lambda (id entry)
          (let ((vec  (vector-ref entry 0))
                (norm (vector-ref entry 1))
                (meta (vector-ref entry 2)))
            (let ((denom (* qn norm)))
              (let ((score (if (= denom 0) 0
                               (/ (vec-dot query-vec vec) denom))))
                (set! results (cons (cons score (cons id meta)) results))))))
        (store-table s))
      (take (sort results (lambda (a b) (> (car a) (car b)))) k)))

  ; Cosine similarity between two raw vectors (no precomputed norms).
  ; Exported for callers that want ad-hoc comparisons.
  (define (cos-sim a b)
    (let ((na (vec-norm a))
          (nb (vec-norm b)))
      (if (= (* na nb) 0) 0
          (/ (vec-dot a b) (* na nb)))))

  ; Save to a JSON file. Shape: [[id, [v..], norm, meta], ...].
  ; Metadata is passed through json-stringify as-is — keep it alist
  ; or hash-table. Note: on store-load, alist metadata comes back as
  ; a hash-table because JSON has no list-of-pairs distinction.
  (define (store-save s path)
    (let ((rows '()))
      (hash-for-each
        (lambda (id entry)
          (let ((vec  (vector-ref entry 0))
                (norm (vector-ref entry 1))
                (meta (vector-ref entry 2)))
            (set! rows (cons (vector id vec norm meta) rows))))
        (store-table s))
      (let ((js (json-stringify (list->vector rows))))
        (cond
          ((err? js) js)
          (else
           (file-write-string path (result-value js))
           (ok (length rows)))))))

  ; Load from a JSON file. Returns (ok store) or (err kind msg).
  (define (store-load path)
    (let ((parsed (json-parse (file-read-string path))))
      (cond
        ((err? parsed) (err 'parse-failed (err-message parsed)))
        (else (rebuild-store (result-value parsed))))))

  (define (rebuild-store rows)
    (cond
      ((not (vector? rows))
       (err 'shape "top-level must be a JSON array"))
      (else
        (let ((s (make-store)))
          (load-rows-into s rows 0)))))

  (define (load-rows-into s rows i)
    (cond
      ((= i (vector-length rows)) (ok s))
      (else (load-one-row s (vector-ref rows i))
            (load-rows-into s rows (+ i 1)))))

  (define (load-one-row s row)
    (cond
      ((or (not (vector? row)) (< (vector-length row) 4))
       (err 'shape "row malformed"))
      (else
        (store-add! s
                    (vector-ref row 0)
                    (list->vector* (vector-ref row 1))
                    (vector-ref row 3)))))

  ; ── Helpers ────────────────────────────────────────────────────────────

  (define (vec-dot a b)
    (let loop ((i 0) (acc 0))
      (if (= i (vector-length a)) acc
          (loop (+ i 1)
                (+ acc (* (vector-ref a i) (vector-ref b i)))))))

  (define (vec-norm v) (sqrt (vec-dot v v)))

  ; json-parse delivers JSON arrays as vectors already; this guard is here
  ; only in case a hand-edited persistence file uses lists.
  (define (list->vector* x)
    (if (vector? x) x (list->vector x)))

  ; Take first k elements of a list (or all if shorter).
  (define (take xs k)
    (cond
      ((= k 0) '())
      ((null? xs) '())
      (else (cons (car xs) (take (cdr xs) (- k 1)))))))
