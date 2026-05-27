(module math/stats
  (export ->vec sum mean variance stdev pvariance pstdev
          median quantile percentile span iqr mode
          covariance pcovariance correlation
          standardize normalize linreg)

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
  (define (stdev  xs) (sqrt (variance  xs)))

  ;; zepo-7uu: sorted copy as a vector (sort works on lists).
  (define (sorted-vec xs) (list->vector (sort (vector->list (->vec xs)) <)))

  ;; type-7 quantile with linear interpolation (numpy/R default).
  (define (quantile xs q)
    (if (or (< q 0) (> q 1)) (error "quantile: q must be in [0,1]"))
    (let* ((s (sorted-vec xs)) (n (vector-length s)))
      (if (= n 0) (error "quantile: empty sequence"))
      (if (= n 1)
          (vector-ref s 0)
          (let* ((h    (* (- n 1) q))
                 (lo   (floor h))
                 (frac (- h lo))
                 (i    (inexact->exact lo)))
            (if (>= i (- n 1))
                (vector-ref s (- n 1))
                (+ (vector-ref s i)
                   (* frac (- (vector-ref s (+ i 1)) (vector-ref s i)))))))))

  (define (percentile xs p) (quantile xs (/ p 100)))
  (define (median xs)       (quantile xs 0.5))
  (define (iqr xs)          (- (quantile xs 0.75) (quantile xs 0.25)))

  (define (span xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "span: empty sequence"))
      (let loop ((i 1) (lo (vector-ref v 0)) (hi (vector-ref v 0)))
        (if (= i n)
            (- hi lo)
            (let ((x (vector-ref v i)))
              (loop (+ i 1) (if (< x lo) x lo) (if (> x hi) x hi)))))))

  ;; mode: most frequent value; smallest value on a tie.
  (define (mode xs)
    (let* ((s (sorted-vec xs)) (n (vector-length s)))
      (if (= n 0) (error "mode: empty sequence"))
      (let loop ((i 1)
                 (cur (vector-ref s 0)) (cur-cnt 1)
                 (best (vector-ref s 0)) (best-cnt 1))
        (if (= i n)
            best
            (let ((x (vector-ref s i)))
              (if (= x cur)
                  (let ((c (+ cur-cnt 1)))
                    (if (> c best-cnt)
                        (loop (+ i 1) cur c x c)
                        (loop (+ i 1) cur c best best-cnt)))
                  (loop (+ i 1) x 1 best best-cnt)))))))

  ;; zepo-7uu: sum of products of deviations (two-pass).
  (define (sp xs ys)
    (let* ((vx (->vec xs)) (vy (->vec ys)) (n (vector-length vx)))
      (if (not (= n (vector-length vy)))
          (error "covariance: sequences differ in length"))
      (let ((mx (mean vx)) (my (mean vy)))
        (let loop ((i 0) (acc 0))
          (if (= i n)
              acc
              (loop (+ i 1)
                    (+ acc (* (- (vector-ref vx i) mx)
                              (- (vector-ref vy i) my)))))))))

  (define (pcovariance xs ys)
    (let ((n (vector-length (->vec xs))))
      (if (= n 0) (error "pcovariance: empty sequence"))
      (/ (sp xs ys) n)))

  (define (covariance xs ys)
    (let ((n (vector-length (->vec xs))))
      (if (< n 2) (error "covariance: needs >= 2 values"))
      (/ (sp xs ys) (- n 1))))

  (define (correlation xs ys)
    (let ((sx (stdev xs)) (sy (stdev ys)))
      (if (or (= sx 0) (= sy 0)) (error "correlation: zero variance"))
      (/ (covariance xs ys) (* sx sy))))

  ;; zepo-7uu: z-score each element using the sample stdev.
  (define (standardize xs)
    (let* ((v (->vec xs)) (n (vector-length v)) (m (mean v)) (sd (stdev v)))
      (if (= sd 0) (error "standardize: zero variance"))
      (let ((out (make-vector n 0)))
        (let loop ((i 0))
          (if (= i n)
              out
              (begin
                (vector-set! out i (/ (- (vector-ref v i) m) sd))
                (loop (+ i 1))))))))

  ;; min-max scale into [0,1].
  (define (normalize xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "normalize: empty sequence"))
      (let loop ((i 1) (lo (vector-ref v 0)) (hi (vector-ref v 0)))
        (if (< i n)
            (let ((x (vector-ref v i)))
              (loop (+ i 1) (if (< x lo) x lo) (if (> x hi) x hi)))
            (begin
              (if (= lo hi) (error "normalize: zero range"))
              (let ((out (make-vector n 0)) (rng (- hi lo)))
                (let fill ((j 0))
                  (if (= j n)
                      out
                      (begin
                        (vector-set! out j (/ (- (vector-ref v j) lo) rng))
                        (fill (+ j 1)))))))))))

  ;; zepo-7uu: ordinary least squares for a single predictor.
  (define (linreg xs ys)
    (let* ((vx (->vec xs)) (vy (->vec ys)) (n (vector-length vx)))
      (if (not (= n (vector-length vy)))
          (error "linreg: sequences differ in length"))
      (if (< n 2) (error "linreg: needs >= 2 points"))
      (let ((mx (mean vx)) (my (mean vy)))
        (let loop ((i 0) (sxy 0) (sxx 0))
          (if (= i n)
              (begin
                (if (= sxx 0) (error "linreg: x has zero variance"))
                (let* ((slope     (/ sxy sxx))
                       (intercept (- my (* slope mx)))
                       (r         (correlation vx vy)))
                  (let ((m (make-hash-table)))
                    (hash-set! m 'slope slope)
                    (hash-set! m 'intercept intercept)
                    (hash-set! m 'r2 (square r))
                    (hash-set! m 'n n)
                    m)))
              (let ((dx (- (vector-ref vx i) mx))
                    (dy (- (vector-ref vy i) my)))
                (loop (+ i 1) (+ sxy (* dx dy)) (+ sxx (* dx dx))))))))))
