(import test)
(import math/core)     ; abs-close?
(import math/tensor)

(deftest tensor/construct-introspect
  (let ((t (tensor (list 2 3) (list 1 2 3 4 5 6))))
    (is (tensor? t))
    (=check (shape t) (list 2 3))
    (=check (rank t) 2)
    (=check (size t) 6))
  ;; shape/data accept vectors too
  (let ((t (tensor (vector 4) (vector 9 9 9 9))))
    (=check (shape t) (list 4))
    (=check (rank t) 1))
  (is (not (tensor? 5)))
  (is (not (tensor? (list 1 2)))))

(run-tests)
