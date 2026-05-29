;; zepo-y1a4: selective imports.
(import test (deftest is =check throws run-tests))
(import math/core   (abs-close?))
(import math/linear (rows->mat))
(import math/stats  (sum mean variance stdev pvariance pstdev
                     median quantile percentile span iqr mode
                     covariance pcovariance correlation
                     standardize normalize linreg ols summary))

(deftest stats/sum-and-mean
  (=check (sum (vector 1 2 3 4)) 10)
  (=check (sum '(1 2 3 4)) 10)            ; list coerced
  (is (abs-close? (mean (vector 1 2 3 4)) 2.5 1e-9))
  (is (abs-close? (mean '(2 4 6)) 4.0 1e-9)))

(deftest stats/variance-stdev
  ;; sample variance of (vector 2 4 4 4 5 5 7 9) = 4.571428571...
  (is (abs-close? (variance (vector 2 4 4 4 5 5 7 9)) 4.5714285714 1e-9))
  (is (abs-close? (stdev    (vector 2 4 4 4 5 5 7 9)) 2.1380899353 1e-9))
  ;; population variance of same data = 4.0, pstdev = 2.0
  (is (abs-close? (pvariance (vector 2 4 4 4 5 5 7 9)) 4.0 1e-9))
  (is (abs-close? (pstdev    (vector 2 4 4 4 5 5 7 9)) 2.0 1e-9)))

(deftest stats/order-stats
  (is (abs-close? (median (vector 1 2 3 4))   2.5 1e-9))
  (is (abs-close? (median (vector 1 2 3 4 5)) 3.0 1e-9))
  (is (abs-close? (quantile (vector 1 2 3 4) 0.5)  2.5 1e-9))
  (is (abs-close? (quantile (vector 1 2 3 4) 0.0)  1.0 1e-9))
  (is (abs-close? (quantile (vector 1 2 3 4) 1.0)  4.0 1e-9))
  ;; type-7: q=0.25 of 1..4 -> 1 + 0.75*(0.25*3 mod) = 1.75
  (is (abs-close? (quantile (vector 1 2 3 4) 0.25) 1.75 1e-9))
  (is (abs-close? (percentile (vector 1 2 3 4) 50) 2.5 1e-9))
  (is (abs-close? (span (vector 3 1 4 1 5)) 4.0 1e-9))
  (is (abs-close? (iqr  (vector 1 2 3 4 5 6 7 8)) 3.5 1e-9))
  (=check (mode (vector 1 2 2 3 3 3 4)) 3)
  (=check (mode (vector 4 4 1 1)) 1))            ; tie -> smallest

(deftest stats/paired
  ;; perfectly correlated y = 2x + 1
  (is (abs-close? (correlation (vector 1 2 3 4) (vector 3 5 7 9)) 1.0 1e-9))
  (is (abs-close? (correlation (vector 1 2 3 4) (vector 9 7 5 3)) -1.0 1e-9))
  ;; sample covariance of x=1..4, y=2,4,5,4 : mean_x=2.5,mean_y=3.75
  ;; sum dev products = (-1.5)(-1.75)+(-.5)(.25)+(.5)(1.25)+(1.5)(.25)=3.5 ; /(4-1)=7/6
  ;; NOTE: plan had wrong expected value (3.0); corrected to 3.5 sum -> 7/6 cov, 7/8 pcov
  (is (abs-close? (covariance (vector 1 2 3 4) (vector 2 4 5 4)) (/ 7.0 6.0) 1e-9))
  (is (abs-close? (pcovariance (vector 1 2 3 4) (vector 2 4 5 4)) 0.875 1e-9)))

(deftest stats/transforms
  (let ((z (standardize (vector 1 2 3 4 5))))
    (is (abs-close? (mean z) 0.0 1e-9))
    (is (abs-close? (stdev z) 1.0 1e-9)))
  (let ((u (normalize (vector 10 20 30))))
    (is (abs-close? (vector-ref u 0) 0.0 1e-9))
    (is (abs-close? (vector-ref u 1) 0.5 1e-9))
    (is (abs-close? (vector-ref u 2) 1.0 1e-9))))

(deftest stats/linreg
  (let ((m (linreg (vector 1 2 3 4) (vector 3 5 7 9))))   ; y = 2x + 1 exactly
    (is (abs-close? (hash-get m 'slope 0)     2.0 1e-9))
    (is (abs-close? (hash-get m 'intercept 0) 1.0 1e-9))
    (is (abs-close? (hash-get m 'r2 0)        1.0 1e-9))
    (=check (hash-get m 'n 0) 4)))

(deftest stats/ols
  ;; X columns: [1 (intercept), x] ; y = 1 + 2x exactly -> coeffs (1 2), r2 1
  (let* ((X (rows->mat (list (list 1 1) (list 1 2) (list 1 3) (list 1 4))))
         (y (vector 3 5 7 9))
         (m (ols X y))
         (c (hash-get m 'coeffs #f)))
    (is (abs-close? (vector-ref c 0) 1.0 1e-7))
    (is (abs-close? (vector-ref c 1) 2.0 1e-7))
    (is (abs-close? (hash-get m 'r2 0) 1.0 1e-7))))

(deftest stats/summary
  (let ((s (summary (vector 1 2 3 4 5 6 7 8))))
    (=check (hash-get s 'n 0) 8)
    (is (abs-close? (hash-get s 'mean 0)   4.5 1e-9))
    (is (abs-close? (hash-get s 'min 0)    1.0 1e-9))
    (is (abs-close? (hash-get s 'max 0)    8.0 1e-9))
    (is (abs-close? (hash-get s 'median 0) 4.5 1e-9))
    (is (abs-close? (hash-get s 'q1 0)     2.75 1e-9))
    (is (abs-close? (hash-get s 'q3 0)     6.25 1e-9))))

(deftest stats/errors
  (throws (mean (vector )))
  (throws (variance (vector 5)))               ; n < 2
  (is (abs-close? (pvariance (vector 5)) 0.0 1e-9))  ; population allows n=1
  (throws (correlation (vector 1 1 1) (vector 1 2 3)))     ; zero variance in x
  (throws (quantile (vector 1 2 3) 1.5))             ; q out of range
  (throws (covariance (vector 1 2 3) (vector 1 2)))        ; unequal lengths
  (throws (linreg (vector 1 1 1) (vector 2 4 6))))         ; x zero variance

;; zepo-sb7: regression — median over 50k elements used to OOM (stdlib's
;; list-based sort blew the stack). The vector merge sort in sorted-vec
;; should handle this comfortably.
(deftest stats/sort-large
  (let* ((n 50000)
         (v (make-vector n 0)))
    (let loop ((i 0))
      (if (< i n) (begin (vector-set! v i (modulo (* i 7919) n)) (loop (+ i 1)))))
    ;; median of a permutation of 0..n-1 is (n-1)/2
    (is (abs-close? (median v) (/ (- n 1) 2.0) 1e-9))))

(run-tests)
