(module math/numeric/fit
  (export fit-linear least-squares-line fit-poly-2)

  (define (sum-x xs n i s)
    (if (= i n) s (sum-x xs n (+ i 1) (+ s (vector-ref xs i)))))

  (define (sum-xy xs ys n i s)
    (if (= i n) s
        (sum-xy xs ys n (+ i 1) (+ s (* (vector-ref xs i) (vector-ref ys i))))))

  (define (sum-xx xs n i s)
    (if (= i n) s
        (sum-xx xs n (+ i 1) (+ s (* (vector-ref xs i) (vector-ref xs i))))))

  (define (fit-linear xs ys)
    (let* ((n (vector-length xs))
           (sx (sum-x xs n 0 0))
           (sy (sum-x ys n 0 0))
           (sxx (sum-xx xs n 0 0))
           (sxy (sum-xy xs ys n 0 0))
           (denom (- (* n sxx) (* sx sx))))
      (if (< (abs denom) 1e-12) (error "fit-linear: degenerate data"))
      (let* ((slope (/ (- (* n sxy) (* sx sy)) denom))
             (intercept (/ (- sy (* slope sx)) n))
             (result (make-hash-table)))
        (hash-set! result 'slope slope)
        (hash-set! result 'intercept intercept)
        result)))

  (define (least-squares-line xs ys) (fit-linear xs ys))

  (define (sum-x3 xs n i s)
    (if (= i n) s
        (let ((xi (vector-ref xs i)))
          (sum-x3 xs n (+ i 1) (+ s (* xi xi xi))))))

  (define (sum-x4 xs n i s)
    (if (= i n) s
        (let ((xi (vector-ref xs i)))
          (sum-x4 xs n (+ i 1) (+ s (* xi xi xi xi))))))

  (define (sum-x2y xs ys n i s)
    (if (= i n) s
        (let ((xi (vector-ref xs i)))
          (sum-x2y xs ys n (+ i 1) (+ s (* xi xi (vector-ref ys i)))))))

  ;; Quadratic regression  y = a*x^2 + b*x + c  via Vandermonde normal equations.
  ;; Returns hash with keys a, b, c.
  (define (fit-poly-2 xs ys)
    (let* ((n   (vector-length xs))
           (s1  (sum-x  xs n 0 0))
           (s2  (sum-xx xs n 0 0))
           (s3  (sum-x3 xs n 0 0))
           (s4  (sum-x4 xs n 0 0))
           (sy  (sum-x  ys n 0 0))
           (sxy (sum-xy xs ys n 0 0))
           (sx2y (sum-x2y xs ys n 0 0))
           ;; det of Gram matrix
           (det-m (- (+ (* n s2 s4) (* s1 s3 s2) (* s2 s1 s3))
                     (+ (* s2 s2 s2) (* s3 s3 n) (* s1 s1 s4)))))
      (if (< (abs det-m) 1e-12) (error "fit-poly-2: degenerate data"))
      (let* ((det-c (- (+ (* sy s2 s4) (* s1 s3 sx2y) (* s2 sxy s3))
                       (+ (* s2 s2 sx2y) (* s3 s3 sy) (* s1 sxy s4))))
             (det-b (- (+ (* n sxy s4) (* sy s3 s2) (* s2 s1 sx2y))
                       (+ (* s2 sxy s2) (* s3 sx2y n) (* sy s1 s4))))
             (det-a (- (+ (* n s2 sx2y) (* s1 sxy s2) (* sy s1 s3))
                       (+ (* sy s2 s2) (* sxy s3 n) (* s1 s1 sx2y))))
             (result (make-hash-table)))
        (hash-set! result 'c (/ det-c det-m))
        (hash-set! result 'b (/ det-b det-m))
        (hash-set! result 'a (/ det-a det-m))
        result))))
