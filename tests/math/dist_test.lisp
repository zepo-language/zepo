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

(deftest dist/rng-float-int
  (let ((r (make-rng 99)))
    (let loop ((i 0))
      (if (< i 1000)
          (let ((f (rng-float! r)) (k (rng-int! r 5 10)))
            (is (>= f 0.0)) (is (< f 1.0))
            (is (>= k 5)) (is (< k 10))
            (loop (+ i 1))))))
  ;; degenerate / error cases
  (throws (rng-int! (make-rng 1) 5 5))     ; empty half-open range
  (throws (rng-int! (make-rng 1) 9 2)))    ; hi < lo

(deftest dist/rng-golden
  (let ((r (make-rng 42)))
    (=check (rng-next! r) 660444221)
    (=check (rng-next! r) 3652823732)
    (=check (rng-next! r) 77672526)))

(run-tests)
