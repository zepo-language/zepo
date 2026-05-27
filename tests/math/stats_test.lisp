(import test)
(import math/core)   ; abs-close?
(import math/stats)

(deftest stats/sum-and-mean
  (=check (sum (vector 1 2 3 4)) 10)
  (=check (sum '(1 2 3 4)) 10)            ; list coerced
  (is (abs-close? (mean (vector 1 2 3 4)) 2.5 1e-9))
  (is (abs-close? (mean '(2 4 6)) 4.0 1e-9)))

(run-tests)
