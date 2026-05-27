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

(deftest tensor/factories-values
  (let ((z (zeros (list 3)))) (is (abs-close? (tref z 0) 0 1e-9)))
  (let ((o (ones (list 3))))  (is (abs-close? (tref o 2) 1 1e-9)))
  (let ((f (full (list 2 2) 7))) (is (abs-close? (tref f 1 1) 7 1e-9)))
  (let ((a (arange 5)))
    (=check (tref a 0) 0)
    (=check (tref a 4) 4)))

(deftest tensor/nested
  (let ((t (from-nested (list (list 1 2 3) (list 4 5 6)))))
    (=check (shape t) (list 2 3))
    (=check (tensor->nested t) (list (list 1 2 3) (list 4 5 6))))
  (let ((t (from-nested (list 1 2 3 4))))    ; 1-D
    (=check (shape t) (list 4))
    (=check (tensor->nested t) (list 1 2 3 4)))
  (throws (from-nested (list (list 1 2) (list 3))))   ; ragged
  (throws (from-nested (quote ()))))                   ; empty

(deftest tensor/index
  (let ((t (from-nested (list (list 1 2 3) (list 4 5 6)))))
    (=check (tref t 0 0) 1)
    (=check (tref t 1 2) 6)
    (tset! t 99 0 1)
    (=check (tref t 0 1) 99)
    (throws (tref t 0))        ; too few indices (rank 2)
    (throws (tref t 0 5))      ; out of bounds
    (throws (tref t -1 0))     ; negative index
    (throws (tref t 2 0))))    ; out of bounds

(deftest tensor/reshape
  (let* ((a (arange 6))                 ; 0..5, shape (6)
         (b (reshape a (list 2 3))))
    (=check (shape b) (list 2 3))
    (=check (tref b 0 0) 0)
    (=check (tref b 1 2) 5)
    (let ((c (reshape b (list 3 2))))
      (=check (shape c) (list 3 2))
      (=check (tref c 2 1) 5)))
  (throws (reshape (arange 6) (list 2 2))))   ; size mismatch (4 != 6)

(deftest tensor/transpose
  (let* ((a (from-nested (list (list 1 2 3) (list 4 5 6))))   ; 2x3
         (b (transpose a)))                                    ; 3x2
    (=check (shape b) (list 3 2))
    (=check (tensor->nested b) (list (list 1 4) (list 2 5) (list 3 6))))
  (let ((a (from-nested (list (list 1 2) (list 3 4)))))
    (=check (tensor->nested (transpose (transpose a))) (list (list 1 2) (list 3 4)))))

(deftest tensor/slice
  (let* ((a (from-nested (list (list 1 2 3 4)        ; 3x4
                               (list 5 6 7 8)
                               (list 9 10 11 12))))
         (b (slice a 1 1 3)))                          ; cols [1,3) -> 3x2
    (=check (shape b) (list 3 2))
    (=check (tensor->nested b) (list (list 2 3) (list 6 7) (list 10 11))))
  (let ((a (from-nested (list (list 1 2) (list 3 4) (list 5 6)))))  ; 3x2
    (=check (tensor->nested (slice a 0 1 3)) (list (list 3 4) (list 5 6))))  ; rows [1,3)
  (throws (slice (arange 5) 1 0 2))     ; axis out of range
  (throws (slice (arange 5) 0 2 2))     ; start not < end
  (throws (slice (arange 5) 0 0 9)))    ; end > dim

(run-tests)






