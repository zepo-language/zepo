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
    (is (t-equal? (transpose (transpose a)) a))))

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

(deftest tensor/elementwise
  (let ((a (from-nested (list (list 1 2) (list 3 4))))
        (b (from-nested (list (list 10 20) (list 30 40)))))
    (=check (tensor->nested (t+ a b)) (list (list 11 22) (list 33 44)))
    (=check (tensor->nested (t* a 2)) (list (list 2 4) (list 6 8)))
    (=check (tensor->nested (t* 2 a)) (list (list 2 4) (list 6 8)))
    (=check (tensor->nested (t- b a)) (list (list 9 18) (list 27 36)))
    (=check (tensor->nested (t-map (lambda (x) (* x x)) a)) (list (list 1 4) (list 9 16)))
    (=check (tensor->nested (t-zip max a b)) (list (list 10 20) (list 30 40)))
    (is (t-equal? a a))
    (is (not (t-equal? a b))))
  (throws (t+ (from-nested (list 1 2 3)) (from-nested (list 1 2)))))  ; shape mismatch

(deftest tensor/reductions
  (let ((a (from-nested (list (list 1 2 3) (list 4 5 6)))))   ; 2x3
    ;; whole-tensor
    (=check (t-sum a) 21)
    (is (abs-close? (t-mean a) 3.5 1e-9))
    (=check (t-max a) 6)
    (=check (t-min a) 1)
    ;; along axis 0 -> length-3 (column sums)
    (=check (tensor->nested (t-sum a 0)) (list 5 7 9))
    ;; along axis 1 -> length-2 (row sums)
    (=check (tensor->nested (t-sum a 1)) (list 6 15))
    (=check (tensor->nested (t-max a 0)) (list 4 5 6))
    (is (abs-close? (car (tensor->nested (t-mean a 1))) 2.0 1e-9)))
  ;; reducing a 1-D tensor's only axis -> scalar
  (=check (t-sum (from-nested (list 1 2 3 4)) 0) 10)
  (throws (t-sum (arange 3) 1))    ; axis out of range
  ;; 3-D axis-at-end check: (2,2,2) reduce axis 2
  (let ((t3 (from-nested (list (list (list 1 2) (list 3 4)) (list (list 5 6) (list 7 8))))))
    (=check (tensor->nested (t-sum t3 2)) (list (list 3 7) (list 11 15)))))

(deftest tensor/matmul
  (let ((a (from-nested (list (list 1 2 3) (list 4 5 6))))      ; 2x3
        (b (from-nested (list (list 7 8) (list 9 10) (list 11 12)))))  ; 3x2
    ;; [[1*7+2*9+3*11, 1*8+2*10+3*12],[4*7+5*9+6*11, 4*8+5*10+6*12]]
    (=check (tensor->nested (matmul a b)) (list (list 58 64) (list 139 154))))
  (let ((id (from-nested (list (list 1 0) (list 0 1))))
        (m  (from-nested (list (list 5 6) (list 7 8)))))
    (is (t-equal? (matmul id m) m)))
  (throws (matmul (from-nested (list (list 1 2) (list 3 4)))      ; 2x2
                  (from-nested (list (list 1 2 3)))))             ; 1x3 (inner 2 != 1)
  (throws (matmul (arange 4) (arange 4))))   ; not rank 2

(deftest tensor/errors
  (throws (tensor (list 2 2) (list 1 2 3)))     ; data length != product
  (throws (tensor (list 0 2) (list)))           ; dim < 1
  (throws (tensor (list 2) (list "a" "b")))     ; non-numeric data
  (throws (arange 0))                           ; n < 1
  (throws (from-nested (list (list 1 2) (list 3))))  ; ragged
  (throws (reshape (arange 6) (list 4)))        ; size mismatch
  (throws (slice (arange 5) 0 3 1))             ; start >= end
  (throws (t* (from-nested (list 1 2)) (from-nested (list 1 2 3))))  ; shape mismatch
  (throws (matmul (arange 3) (arange 3))))      ; not rank 2

(run-tests)










