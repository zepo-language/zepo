(module math/stats
  (export ->vec sum mean)

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
      (/ (sum v) n))))
