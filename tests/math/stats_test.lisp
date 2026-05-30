;; zepo-g77k: migrated to the new testing framework. Same coverage, real
;; describe/it nesting, =check~ for approximate floats.
(import testing
  (describe it is =check =check~ throws
   run!/exit))
(import math/linear (rows->mat))
(import math/stats  (sum mean variance stdev pvariance pstdev
                     median quantile percentile span iqr mode
                     covariance pcovariance correlation
                     standardize normalize linreg ols summary))

(describe "stats"

  (describe "central tendency"
    (it "sum on vector"      (=check (sum (vector 1 2 3 4)) 10))
    (it "sum coerces list"   (=check (sum '(1 2 3 4)) 10))
    (it "mean on vector"     (=check~ (mean (vector 1 2 3 4)) 2.5 1e-9))
    (it "mean on list"       (=check~ (mean '(2 4 6)) 4.0 1e-9)))

  (describe "spread"
    (it "sample variance"
      (=check~ (variance (vector 2 4 4 4 5 5 7 9)) 4.5714285714 1e-9))
    (it "sample stdev"
      (=check~ (stdev    (vector 2 4 4 4 5 5 7 9)) 2.1380899353 1e-9))
    (it "population variance"
      (=check~ (pvariance (vector 2 4 4 4 5 5 7 9)) 4.0 1e-9))
    (it "population stdev"
      (=check~ (pstdev    (vector 2 4 4 4 5 5 7 9)) 2.0 1e-9)))

  (describe "order stats"
    (it "median of even-length vector"   (=check~ (median (vector 1 2 3 4))   2.5 1e-9))
    (it "median of odd-length vector"    (=check~ (median (vector 1 2 3 4 5)) 3.0 1e-9))
    (it "q=0.5 equals median"            (=check~ (quantile (vector 1 2 3 4) 0.5)  2.5 1e-9))
    (it "q=0.0 is min"                   (=check~ (quantile (vector 1 2 3 4) 0.0)  1.0 1e-9))
    (it "q=1.0 is max"                   (=check~ (quantile (vector 1 2 3 4) 1.0)  4.0 1e-9))
    (it "q=0.25 of 1..4 type-7"          (=check~ (quantile (vector 1 2 3 4) 0.25) 1.75 1e-9))
    (it "percentile and quantile agree"  (=check~ (percentile (vector 1 2 3 4) 50) 2.5 1e-9))
    (it "span is max - min"              (=check~ (span (vector 3 1 4 1 5)) 4.0 1e-9))
    (it "iqr"                            (=check~ (iqr  (vector 1 2 3 4 5 6 7 8)) 3.5 1e-9))
    (it "mode picks most-frequent"       (=check (mode (vector 1 2 2 3 3 3 4)) 3))
    (it "mode breaks ties by smallest"   (=check (mode (vector 4 4 1 1)) 1)))

  (describe "paired"
    (it "perfectly correlated y=2x+1"
      (=check~ (correlation (vector 1 2 3 4) (vector 3 5 7 9)) 1.0 1e-9))
    (it "perfectly anti-correlated"
      (=check~ (correlation (vector 1 2 3 4) (vector 9 7 5 3)) -1.0 1e-9))
    (it "sample covariance"
      (=check~ (covariance (vector 1 2 3 4) (vector 2 4 5 4)) (/ 7.0 6.0) 1e-9))
    (it "population covariance"
      (=check~ (pcovariance (vector 1 2 3 4) (vector 2 4 5 4)) 0.875 1e-9)))

  (describe "transforms"
    (it "standardize gives mean 0, stdev 1"
      (let ((z (standardize (vector 1 2 3 4 5))))
        (=check~ (mean z) 0.0 1e-9)
        (=check~ (stdev z) 1.0 1e-9)))
    (it "normalize scales to [0,1]"
      (let ((u (normalize (vector 10 20 30))))
        (=check~ (vector-ref u 0) 0.0 1e-9)
        (=check~ (vector-ref u 1) 0.5 1e-9)
        (=check~ (vector-ref u 2) 1.0 1e-9))))

  (describe "regression"
    (it "linreg recovers slope and intercept"
      (let ((m (linreg (vector 1 2 3 4) (vector 3 5 7 9))))
        (=check~ (hash-get m 'slope 0)     2.0 1e-9)
        (=check~ (hash-get m 'intercept 0) 1.0 1e-9)
        (=check~ (hash-get m 'r2 0)        1.0 1e-9)
        (=check (hash-get m 'n 0) 4)))
    (it "ols matches the exact line"
      (let* ((X (rows->mat (list (list 1 1) (list 1 2) (list 1 3) (list 1 4))))
             (y (vector 3 5 7 9))
             (m (ols X y))
             (c (hash-get m 'coeffs #f)))
        (=check~ (vector-ref c 0) 1.0 1e-7)
        (=check~ (vector-ref c 1) 2.0 1e-7)
        (=check~ (hash-get m 'r2 0) 1.0 1e-7))))

  (describe "summary"
    (it "reports n / mean / min / max / median / q1 / q3"
      (let ((s (summary (vector 1 2 3 4 5 6 7 8))))
        (=check  (hash-get s 'n 0) 8)
        (=check~ (hash-get s 'mean 0)   4.5 1e-9)
        (=check~ (hash-get s 'min 0)    1.0 1e-9)
        (=check~ (hash-get s 'max 0)    8.0 1e-9)
        (=check~ (hash-get s 'median 0) 4.5 1e-9)
        (=check~ (hash-get s 'q1 0)     2.75 1e-9)
        (=check~ (hash-get s 'q3 0)     6.25 1e-9))))

  (describe "error cases"
    (it "mean of empty raises"                 (throws (mean (vector))))
    (it "variance with n<2 raises"             (throws (variance (vector 5))))
    (it "pvariance allows n=1 (returns 0)"     (=check~ (pvariance (vector 5)) 0.0 1e-9))
    (it "correlation with zero variance"       (throws (correlation (vector 1 1 1) (vector 1 2 3))))
    (it "quantile rejects q out of [0,1]"      (throws (quantile (vector 1 2 3) 1.5)))
    (it "covariance rejects unequal lengths"   (throws (covariance (vector 1 2 3) (vector 1 2))))
    (it "linreg rejects x with zero variance"  (throws (linreg (vector 1 1 1) (vector 2 4 6)))))

  (describe "scale" ; zepo-sb7 regression
    (it "median over 50k elements doesn't OOM"
      (let* ((n 50000)
             (v (make-vector n 0)))
        (let loop ((i 0))
          (if (< i n) (begin (vector-set! v i (modulo (* i 7919) n)) (loop (+ i 1)))))
        (=check~ (median v) (/ (- n 1) 2.0) 1e-9)))))

(run!/exit)
