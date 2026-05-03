; 24game.lisp — print all solvable quadruples for the 24 game
; zepo-bes
;
; Rules: combine four integers (1–13) with +, -, *, / to reach 24.
; Each integer used exactly once. Fractions are allowed mid-computation.
; Output: all solvable non-decreasing quadruples, one per line.

(import format)

; ── Rational arithmetic ───────────────────────────────────────────────────────
; Represent rationals as (num . den), den always positive, fully reduced.

(define (make-rat n d)
  (if (= d 0) #f
      (let* ((s (if (< d 0) -1 1))
             (n (* n s))
             (d (* d s))
             (g (gcd (abs n) d)))
        (cons (/ n g) (/ d g)))))

(define (rat+ a b)
  (make-rat (+ (* (car a) (cdr b)) (* (car b) (cdr a)))
            (* (cdr a) (cdr b))))

(define (rat- a b)
  (make-rat (- (* (car a) (cdr b)) (* (car b) (cdr a)))
            (* (cdr a) (cdr b))))

(define (rat* a b)
  (make-rat (* (car a) (car b)) (* (cdr a) (cdr b))))

(define (rat/ a b)
  (if (= (car b) 0) #f
      (make-rat (* (car a) (cdr b)) (* (cdr a) (car b)))))

(define (rat=24? r) (and (= (car r) 24) (= (cdr r) 1)))

; ── Operator dispatch ─────────────────────────────────────────────────────────

(define (apply-op op a b)
  (cond ((eq? op '+) (rat+ a b))
        ((eq? op '-) (rat- a b))
        ((eq? op '*) (rat* a b))
        ((eq? op '/) (rat/ a b))))

(define ops '(+ - * /))

; ── Remove element at index i from list ──────────────────────────────────────

(define (drop-at lst i)
  (cond ((null? lst) '())
        ((= i 0) (cdr lst))
        (else (cons (car lst) (drop-at (cdr lst) (- i 1))))))

; ── Core solver: can any combination of lst equal 24? ────────────────────────
;
; Strategy: pick any ordered pair (i, j) of distinct indices, apply an
; operator to (lst[i], lst[j]), replace both with the result, recurse.
; Trying all ordered pairs covers non-commutative ops (a-b vs b-a, a/b vs b/a).
; Short-circuit on first solution found.

(define (can-make-24? lst)
  (if (= (length lst) 1)
      (rat=24? (car lst))
      (let ((n (length lst)))
        (let try-i ((i 0))
          (cond
            ((= i n) #f)
            (else
             (let try-j ((j 0))
               (cond
                 ((= j n)  (try-i (+ i 1)))
                 ((= i j)  (try-j (+ j 1)))
                 (else
                  (let* ((a    (list-ref lst i))
                         (b    (list-ref lst j))
                         (lo   (min i j))
                         (hi   (max i j))
                         (rest (drop-at (drop-at lst hi) lo)))
                    (let try-op ((ops ops))
                      (cond
                        ((null? ops) (try-j (+ j 1)))
                        (else
                         (let ((v (apply-op (car ops) a b)))
                           (if (and v (can-make-24? (cons v rest)))
                               #t
                               (try-op (cdr ops)))))))))))))))))

; ── Enumerate all non-decreasing quadruples from 1..13 ───────────────────────
; Note: nested for-each shares an internal function name that collides under
; TCO; use named let with distinct loop names instead.

(let loop-a ((a 1))
  (when (<= a 13)
    (let loop-b ((b a))
      (when (<= b 13)
        (let loop-c ((c b))
          (when (<= c 13)
            (let loop-d ((d c))
              (when (<= d 13)
                (when (can-make-24? (list (cons a 1) (cons b 1)
                                         (cons c 1) (cons d 1)))
                  (display (format "~a ~a ~a ~a~%" a b c d)))
                (loop-d (+ d 1))))
            (loop-c (+ c 1))))
        (loop-b (+ b 1))))
    (loop-a (+ a 1))))
