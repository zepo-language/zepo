;; zepo-g77k: migrated to the new testing framework.
(import testing
  (describe it is =check =check~ throws
   run!/exit))
(import math/tensor (tensor tensor? shape rank size zeros ones full arange
                     from-nested tensor->nested tref tset! reshape transpose
                     slice t+ t- t* t/ t-map t-zip t-equal? t-sum t-mean
                     t-max t-min matmul))

(describe "tensor"

  (describe "construction"
    (it "tensor from flat data has the right shape / rank / size"
      (let ((t (tensor (list 2 3) (list 1 2 3 4 5 6))))
        (is (tensor? t))
        (=check (shape t) (list 2 3))
        (=check (rank t) 2)
        (=check (size t) 6)))
    (it "shape and data accept vectors"
      (let ((t (tensor (vector 4) (vector 9 9 9 9))))
        (=check (shape t) (list 4))
        (=check (rank t) 1)))
    (it "tensor? rejects non-tensors"
      (is (not (tensor? 5)))
      (is (not (tensor? (list 1 2))))))

  (describe "factories"
    (it "shapes are correct"
      (=check (shape (zeros (list 2 2))) (list 2 2))
      (=check (size (zeros (list 2 2))) 4)
      (=check (shape (ones (list 3))) (list 3))
      (=check (shape (full (list 2 2) 7)) (list 2 2)))
    (it "arange has right shape"
      (let ((a (arange 5))) (=check (shape a) (list 5)) (=check (size a) 5)))
    (it "arange rejects n<1"  (throws (arange 0)))
    (it "factory values are correct"
      (let ((z (zeros (list 3)))) (=check~ (tref z 0) 0 1e-9))
      (let ((o (ones (list 3))))  (=check~ (tref o 2) 1 1e-9))
      (let ((f (full (list 2 2) 7))) (=check~ (tref f 1 1) 7 1e-9))
      (let ((a (arange 5))) (=check (tref a 0) 0) (=check (tref a 4) 4))))

  (describe "nested"
    (it "from-nested round-trip"
      (let ((t (from-nested (list (list 1 2 3) (list 4 5 6)))))
        (=check (shape t) (list 2 3))
        (=check (tensor->nested t) (list (list 1 2 3) (list 4 5 6)))))
    (it "from-nested 1-D"
      (let ((t (from-nested (list 1 2 3 4))))
        (=check (shape t) (list 4))
        (=check (tensor->nested t) (list 1 2 3 4))))
    (it "from-nested rejects ragged input"
      (throws (from-nested (list (list 1 2) (list 3)))))
    (it "from-nested rejects empty"
      (throws (from-nested (quote ())))))

  (describe "indexing"
    (it "tref and tset!"
      (let ((t (from-nested (list (list 1 2 3) (list 4 5 6)))))
        (=check (tref t 0 0) 1)
        (=check (tref t 1 2) 6)
        (tset! t 99 0 1)
        (=check (tref t 0 1) 99)))
    (it "tref rejects malformed indices"
      (let ((t (from-nested (list (list 1 2 3) (list 4 5 6)))))
        (throws (tref t 0))
        (throws (tref t 0 5))
        (throws (tref t -1 0))
        (throws (tref t 2 0)))))

  (describe "reshape"
    (it "preserves elements through reshapes"
      (let* ((a (arange 6)) (b (reshape a (list 2 3))))
        (=check (shape b) (list 2 3))
        (=check (tref b 0 0) 0)
        (=check (tref b 1 2) 5)
        (let ((c (reshape b (list 3 2))))
          (=check (shape c) (list 3 2))
          (=check (tref c 2 1) 5))))
    (it "rejects shape mismatch"
      (throws (reshape (arange 6) (list 2 2)))))

  (describe "transpose"
    (it "swaps axes correctly"
      (let* ((a (from-nested (list (list 1 2 3) (list 4 5 6))))
             (b (transpose a)))
        (=check (shape b) (list 3 2))
        (=check (tensor->nested b) (list (list 1 4) (list 2 5) (list 3 6)))))
    (it "is its own inverse"
      (let ((a (from-nested (list (list 1 2) (list 3 4)))))
        (is (t-equal? (transpose (transpose a)) a)))))

  (describe "slice"
    (it "slices along axis 1"
      (let* ((a (from-nested (list (list 1 2 3 4) (list 5 6 7 8) (list 9 10 11 12))))
             (b (slice a 1 1 3)))
        (=check (shape b) (list 3 2))
        (=check (tensor->nested b) (list (list 2 3) (list 6 7) (list 10 11)))))
    (it "slices along axis 0"
      (let ((a (from-nested (list (list 1 2) (list 3 4) (list 5 6)))))
        (=check (tensor->nested (slice a 0 1 3)) (list (list 3 4) (list 5 6)))))
    (it "rejects bad parameters"
      (throws (slice (arange 5) 1 0 2))
      (throws (slice (arange 5) 0 2 2))
      (throws (slice (arange 5) 0 0 9))))

  (describe "elementwise"
    (it "t+ t* t- t-map t-zip across two 2x2 tensors"
      (let ((a (from-nested (list (list 1 2) (list 3 4))))
            (b (from-nested (list (list 10 20) (list 30 40)))))
        (=check (tensor->nested (t+ a b)) (list (list 11 22) (list 33 44)))
        (=check (tensor->nested (t* a 2)) (list (list 2 4) (list 6 8)))
        (=check (tensor->nested (t* 2 a)) (list (list 2 4) (list 6 8)))
        (=check (tensor->nested (t- b a)) (list (list 9 18) (list 27 36)))
        (=check (tensor->nested (t-map (lambda (x) (* x x)) a))
                (list (list 1 4) (list 9 16)))
        (=check (tensor->nested (t-zip max a b))
                (list (list 10 20) (list 30 40)))
        (is (t-equal? a a))
        (is (not (t-equal? a b)))))
    (it "rejects shape mismatch"
      (throws (t+ (from-nested (list 1 2 3)) (from-nested (list 1 2))))))

  (describe "reductions"
    (it "whole-tensor reductions on 2x3"
      (let ((a (from-nested (list (list 1 2 3) (list 4 5 6)))))
        (=check (t-sum a) 21)
        (=check~ (t-mean a) 3.5 1e-9)
        (=check (t-max a) 6)
        (=check (t-min a) 1)))
    (it "reductions along an axis"
      (let ((a (from-nested (list (list 1 2 3) (list 4 5 6)))))
        (=check (tensor->nested (t-sum a 0)) (list 5 7 9))
        (=check (tensor->nested (t-sum a 1)) (list 6 15))
        (=check (tensor->nested (t-max a 0)) (list 4 5 6))
        (=check~ (car (tensor->nested (t-mean a 1))) 2.0 1e-9)))
    (it "1-D axis-0 reduction yields scalar"
      (=check (t-sum (from-nested (list 1 2 3 4)) 0) 10))
    (it "rejects out-of-range axis"
      (throws (t-sum (arange 3) 1)))
    (it "3-D axis-2 reduction"
      (let ((t3 (from-nested (list (list (list 1 2) (list 3 4))
                                   (list (list 5 6) (list 7 8))))))
        (=check (tensor->nested (t-sum t3 2)) (list (list 3 7) (list 11 15))))))

  (describe "matmul"
    (it "2x3 · 3x2 = 2x2"
      (let ((a (from-nested (list (list 1 2 3) (list 4 5 6))))
            (b (from-nested (list (list 7 8) (list 9 10) (list 11 12)))))
        (=check (tensor->nested (matmul a b)) (list (list 58 64) (list 139 154)))))
    (it "identity · m = m"
      (let ((id (from-nested (list (list 1 0) (list 0 1))))
            (m  (from-nested (list (list 5 6) (list 7 8)))))
        (is (t-equal? (matmul id m) m))))
    (it "rejects inner-dim mismatch"
      (throws (matmul (from-nested (list (list 1 2) (list 3 4)))
                      (from-nested (list (list 1 2 3))))))
    (it "rejects non-rank-2"
      (throws (matmul (arange 4) (arange 4)))))

  (describe "errors"
    (it "rejects non-numeric (full)"   (throws (full (list 2 2) "oops")))
    (it "rejects data length mismatch" (throws (tensor (list 2 2) (list 1 2 3))))
    (it "rejects dim < 1"              (throws (tensor (list 0 2) (list))))
    (it "rejects non-numeric data"     (throws (tensor (list 2) (list "a" "b"))))
    (it "rejects ragged from-nested"   (throws (from-nested (list (list 1 2) (list 3)))))
    (it "rejects reshape mismatch"     (throws (reshape (arange 6) (list 4))))
    (it "rejects bad slice"            (throws (slice (arange 5) 0 3 1)))
    (it "rejects elementwise shape mismatch"
      (throws (t* (from-nested (list 1 2)) (from-nested (list 1 2 3)))))
    (it "rejects matmul on non-rank-2" (throws (matmul (arange 3) (arange 3))))))

(run!/exit)
