(module math/stats
  (export ->vec sum mean variance stdev pvariance pstdev)

  (import math/core)    ; square, abs-close? (used later)
  (import math/linear)  ; solve, matvec, mat (used by ols)

  ;; zepo-7uu: canonical input is a vector; accept a list too.
  (define (->vec xs) (if (vector? xs) xs (list->vector xs)))

  (define (sum xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (let loop ((i 0) (acc 0))
        (if (= i n) acc (loop (+ i 1) (+ acc (vector-ref v i)))))))

  (define (mean xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "mean: empty sequence"))
      (/ (sum v) n)))

  ;; zepo-7uu: two-pass sum of squared deviations from the mean.
  (define (ss xs)
    (let* ((v (->vec xs)) (n (vector-length v)) (m (mean v)))
      (let loop ((i 0) (acc 0))
        (if (= i n) acc
            (loop (+ i 1) (+ acc (square (- (vector-ref v i) m))))))))

  (define (pvariance xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "pvariance: empty sequence"))
      (/ (ss v) n)))

  (define (variance xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (< n 2) (error "variance: needs >= 2 values"))
      (/ (ss v) (- n 1))))

  (define (pstdev xs) (sqrt (pvariance xs)))
  (define (stdev  xs) (sqrt (variance  xs))))
