(import test)
(import math/core)
(import math/dist)

(deftest dist/rng-determinism
  ;; same seed -> identical streams
  (let ((a (make-rng 42)) (b (make-rng 42)))
    (=check (rng-next! a) (rng-next! b))
    (=check (rng-next! a) (rng-next! b))
    (=check (rng-next! a) (rng-next! b)))
  ;; different seeds -> first draw differs
  (let ((a (make-rng 1)) (b (make-rng 2)))
    (is (not (= (rng-next! a) (rng-next! b)))))
  ;; raw draws are non-negative 32-bit fixnums
  (let ((r (make-rng 7)))
    (let ((x (rng-next! r)))
      (is (>= x 0))
      (is (< x 4294967296)))))

(deftest dist/rng-golden
  (let ((r (make-rng 42)))
    (=check (rng-next! r) 660444221)
    (=check (rng-next! r) 3652823732)
    (=check (rng-next! r) 77672526)))

(run-tests)
