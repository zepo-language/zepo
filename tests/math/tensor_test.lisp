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

(deftest tensor/factories
  (=check (shape (zeros (list 2 2))) (list 2 2))
  (=check (size (zeros (list 2 2))) 4)
  (=check (shape (ones (list 3))) (list 3))
  (=check (shape (full (list 2 2) 7)) (list 2 2))
  (let ((a (arange 5)))
    (=check (shape a) (list 5))
    (=check (size a) 5))
  (throws (arange 0)))

(run-tests)

