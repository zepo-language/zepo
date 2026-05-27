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

(run-tests)
