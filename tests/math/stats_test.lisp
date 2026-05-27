(import test)
(import math/core)   ; abs-close?
(import math/stats)

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

(run-tests)
