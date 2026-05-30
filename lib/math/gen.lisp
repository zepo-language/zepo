(module math/gen
  ;; zepo-bm3a: random-value generators with shrinking, the foundation
  ;; for property-based testing (zepo-qv9y).
  ;;
  ;; A generator is a hash-table with two procedures:
  ;;   :sample  (lambda (rng) value)         — draw one value
  ;;   :shrink  (lambda (value) candidates)  — list of structurally
  ;;                                            smaller candidates
  (export make-gen gen-sample gen-shrink
          gen-int gen-float gen-bool gen-char gen-string
          gen-list gen-vector gen-one-of gen-bind)

  (import math/dist (make-rng rng-int! rng-float!))

  ;; ── core record ──────────────────────────────────────────────────────────

  (define (make-gen sample-fn shrink-fn)
    (let ((g (make-hash-table)))
      (hash-set! g (quote :sample) sample-fn)
      (hash-set! g (quote :shrink) shrink-fn)
      g))

  (define (gen-sample g rng)
    ((hash-get g (quote :sample) #f) rng))

  (define (gen-shrink g value)
    ((hash-get g (quote :shrink) #f) value))

  ;; ── small helpers ────────────────────────────────────────────────────────

  (define (sign-of n)
    (cond ((> n 0) 1)
          ((< n 0) -1)
          (else 0)))

  (define (abs-of n) (if (< n 0) (- n) n))

  ;; unique-preserving filter: keep candidates strictly smaller (|c| < |v|).
  (define (smaller-ints v cands)
    (let loop ((xs cands) (seen (quote ())) (acc (quote ())))
      (if (null? xs)
          (reverse acc)
          (let ((c (car xs)))
            (if (and (< (abs-of c) (abs-of v))
                     (not (member c seen)))
                (loop (cdr xs) (cons c seen) (cons c acc))
                (loop (cdr xs) seen acc))))))

  ;; integer shrinker — toward 0.
  (define (int-shrink n)
    (if (= n 0)
        (quote ())
        (let* ((half (quotient n 2))
               (toward (- n (sign-of n))))
          (smaller-ints n (list 0 half toward)))))

  ;; ── gen-int ──────────────────────────────────────────────────────────────

  ;; rng-int! is half-open [lo,hi); we want inclusive [lo,hi].
  (define (gen-int lo hi)
    (if (> lo hi) (error "gen-int: lo > hi"))
    (make-gen
     (lambda (rng) (rng-int! rng lo (+ hi 1)))
     (lambda (v)
       ;; only keep candidates that fall within the declared range.
       (let loop ((xs (int-shrink v)) (acc (quote ())))
         (if (null? xs)
             (reverse acc)
             (let ((c (car xs)))
               (if (and (>= c lo) (<= c hi))
                   (loop (cdr xs) (cons c acc))
                   (loop (cdr xs) acc))))))))

  ;; ── gen-float ────────────────────────────────────────────────────────────

  (define (gen-float lo hi)
    (if (>= lo hi) (error "gen-float: lo must be < hi"))
    (make-gen
     (lambda (rng) (+ lo (* (- hi lo) (rng-float! rng))))
     (lambda (v)
       ;; round toward zero then use int shrinker; keep in range.
       (let* ((i (inexact->exact (truncate v)))
              (cands (int-shrink i)))
         (let loop ((xs cands) (acc (quote ())))
           (if (null? xs)
               (reverse acc)
               (let ((c (exact->inexact (car xs))))
                 (if (and (>= c lo) (< c hi)
                          (< (abs-of c) (abs-of v)))
                     (loop (cdr xs) (cons c acc))
                     (loop (cdr xs) acc)))))))))

  ;; ── gen-bool ─────────────────────────────────────────────────────────────

  (define (gen-bool)
    (make-gen
     (lambda (rng) (= 0 (rng-int! rng 0 2)))
     (lambda (v)
       (cond ((eq? v #t) (list #f))
             ((eq? v #f) (list (quote ())))
             (else (quote ()))))))

  ;; ── gen-char ─────────────────────────────────────────────────────────────

  (define printable-lo 32)               ; space
  (define printable-hi 127)              ; one past '~'
  (define char-a (char->integer #\a))

  (define (gen-char)
    (make-gen
     (lambda (rng)
       (integer->char (rng-int! rng printable-lo printable-hi)))
     (lambda (c)
       (let ((n (char->integer c)))
         (cond ((= n char-a) (quote ()))
               ((> n char-a)
                ;; shrink toward 'a' by halving distance and stepping one closer.
                (let* ((d (- n char-a))
                       (half (+ char-a (quotient d 2)))
                       (step (- n 1)))
                  (let loop ((xs (list char-a half step))
                             (seen (quote ()))
                             (acc (quote ())))
                    (if (null? xs)
                        (reverse acc)
                        (let ((m (car xs)))
                          (if (and (>= m printable-lo)
                                   (< m printable-hi)
                                   (< (abs-of (- m char-a))
                                      (abs-of (- n char-a)))
                                   (not (member m seen)))
                              (loop (cdr xs)
                                    (cons m seen)
                                    (cons (integer->char m) acc))
                              (loop (cdr xs) seen acc)))))))
               (else
                ;; n < 'a' — shrink toward 'a' from below.
                (let* ((d (- char-a n))
                       (half (- char-a (quotient d 2)))
                       (step (+ n 1)))
                  (let loop ((xs (list char-a half step))
                             (seen (quote ()))
                             (acc (quote ())))
                    (if (null? xs)
                        (reverse acc)
                        (let ((m (car xs)))
                          (if (and (>= m printable-lo)
                                   (< m printable-hi)
                                   (< (abs-of (- m char-a))
                                      (abs-of (- n char-a)))
                                   (not (member m seen)))
                              (loop (cdr xs)
                                    (cons m seen)
                                    (cons (integer->char m) acc))
                              (loop (cdr xs) seen acc))))))))))))

  ;; ── gen-string ───────────────────────────────────────────────────────────

  ;; remove the element at index i from a list.
  (define (list-remove-at lst i)
    (let loop ((xs lst) (k 0) (acc (quote ())))
      (if (null? xs)
          (reverse acc)
          (if (= k i)
              (loop (cdr xs) (+ k 1) acc)
              (loop (cdr xs) (+ k 1) (cons (car xs) acc))))))

  (define (gen-string lo-len hi-len)
    (if (< lo-len 0) (error "gen-string: lo-len < 0"))
    (if (> lo-len hi-len) (error "gen-string: lo-len > hi-len"))
    (let ((char-gen (gen-char)))
      (make-gen
       (lambda (rng)
         (let ((n (rng-int! rng lo-len (+ hi-len 1))))
           (let loop ((i 0) (acc (quote ())))
             (if (= i n)
                 (list->string (reverse acc))
                 (loop (+ i 1)
                       (cons (gen-sample char-gen rng) acc))))))
       (lambda (s)
         (let* ((chars (string->list s))
                (len (length chars)))
           (let ((acc (quote ())))
             ;; (1) truncate to half length, if shorter and still >= lo-len.
             (let ((half (quotient len 2)))
               (if (and (< half len) (>= half lo-len))
                   (set! acc (cons (list->string
                                    (let take ((xs chars) (k half))
                                      (if (or (= k 0) (null? xs))
                                          (quote ())
                                          (cons (car xs) (take (cdr xs) (- k 1))))))
                                   acc))))
             ;; (2) remove one char at each position.
             (if (and (> len 0) (>= (- len 1) lo-len))
                 (let drop-loop ((i 0))
                   (if (< i len)
                       (begin
                         (set! acc (cons (list->string (list-remove-at chars i)) acc))
                         (drop-loop (+ i 1))))))
             ;; (3) shrink each char.
             (let char-loop ((i 0))
               (if (< i len)
                   (let ((ch (list-ref chars i)))
                     (let inner ((cands (gen-shrink char-gen ch)))
                       (if (not (null? cands))
                           (let ((replaced (let r ((xs chars) (k 0))
                                             (if (null? xs)
                                                 (quote ())
                                                 (if (= k i)
                                                     (cons (car cands) (cdr xs))
                                                     (cons (car xs) (r (cdr xs) (+ k 1))))))))
                             (set! acc (cons (list->string replaced) acc))
                             (inner (cdr cands)))))
                     (char-loop (+ i 1)))))
             (reverse acc)))))))

  ;; ── gen-list ─────────────────────────────────────────────────────────────

  (define (gen-list lo-len hi-len item-gen)
    (if (< lo-len 0) (error "gen-list: lo-len < 0"))
    (if (> lo-len hi-len) (error "gen-list: lo-len > hi-len"))
    (make-gen
     (lambda (rng)
       (let ((n (rng-int! rng lo-len (+ hi-len 1))))
         (let loop ((i 0) (acc (quote ())))
           (if (= i n)
               (reverse acc)
               (loop (+ i 1) (cons (gen-sample item-gen rng) acc))))))
     (lambda (lst)
       (let ((len (length lst))
             (acc (quote ())))
         ;; (1) empty list, if allowed and not already empty.
         (if (and (> len 0) (= lo-len 0))
             (set! acc (cons (quote ()) acc)))
         ;; (2) remove one element at each position.
         (if (and (> len 0) (>= (- len 1) lo-len))
             (let loop ((i 0))
               (if (< i len)
                   (begin
                     (set! acc (cons (list-remove-at lst i) acc))
                     (loop (+ i 1))))))
         ;; (3) shrink each element in place.
         (let loop ((i 0))
           (if (< i len)
               (let ((v (list-ref lst i)))
                 (let inner ((cands (gen-shrink item-gen v)))
                   (if (not (null? cands))
                       (let ((replaced (let r ((xs lst) (k 0))
                                         (if (null? xs)
                                             (quote ())
                                             (if (= k i)
                                                 (cons (car cands) (cdr xs))
                                                 (cons (car xs) (r (cdr xs) (+ k 1))))))))
                         (set! acc (cons replaced acc))
                         (inner (cdr cands)))))
                 (loop (+ i 1)))))
         (reverse acc)))))

  ;; ── gen-vector ───────────────────────────────────────────────────────────

  (define (list->vec lst)
    (let* ((n (length lst))
           (v (make-vector n 0)))
      (let loop ((xs lst) (i 0))
        (if (null? xs)
            v
            (begin (vector-set! v i (car xs))
                   (loop (cdr xs) (+ i 1)))))))

  (define (vec->lst v)
    (let ((n (vector-length v)))
      (let loop ((i (- n 1)) (acc (quote ())))
        (if (< i 0) acc
            (loop (- i 1) (cons (vector-ref v i) acc))))))

  (define (gen-vector lo-len hi-len item-gen)
    (let ((lg (gen-list lo-len hi-len item-gen)))
      (make-gen
       (lambda (rng) (list->vec (gen-sample lg rng)))
       (lambda (vec)
         (let loop ((xs (gen-shrink lg (vec->lst vec))) (acc (quote ())))
           (if (null? xs)
               (reverse acc)
               (loop (cdr xs) (cons (list->vec (car xs)) acc))))))))

  ;; ── gen-one-of ───────────────────────────────────────────────────────────

  (define (gen-one-of items)
    (if (null? items) (error "gen-one-of: empty list"))
    (let* ((vec (list->vec items))
           (n (vector-length vec)))
      (make-gen
       (lambda (rng) (vector-ref vec (rng-int! rng 0 n)))
       (lambda (v)
         ;; prefer earlier items in the list as "smaller".
         (let loop ((xs items) (acc (quote ())))
           (cond ((null? xs) (reverse acc))
                 ((equal? (car xs) v) (reverse acc))
                 (else (loop (cdr xs) (cons (car xs) acc)))))))))

  ;; ── gen-bind ─────────────────────────────────────────────────────────────

  ;; Monadic compose. We sample the outer gen to get an outer value, then
  ;; build the inner gen by calling f on it, then sample the inner gen.
  ;; The shrinker tries the outer gen's shrinks via re-sampling the inner.
  ;; Since we can't easily re-derive the inner value from just the result,
  ;; the shrinker stores no history and falls back to: "no shrinks".
  ;; A richer impl would carry the outer seed; for now we expose what we can.
  (define (gen-bind outer-gen f)
    (make-gen
     (lambda (rng)
       (let* ((outer-v (gen-sample outer-gen rng))
              (inner-gen (f outer-v)))
         (gen-sample inner-gen rng)))
     (lambda (v)
       ;; Without the outer value cached, we attempt to shrink as if v were
       ;; itself a sample of the inner gen — try shrinking via a freshly-built
       ;; inner gen with a degenerate outer value if f is total. Safer: return ().
       (quote ())))))
