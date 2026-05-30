;; zepo-g77k: migrated to the new testing framework.
;; Compared with the previous flat (deftest dist/foo ...) form, the suite
;; is now grouped under a top-level (describe "dist" ...) with one (it ...)
;; per behavior. Approximate float comparisons use =check~ directly instead
;; of (is (abs-close? ...)).
(import testing
  (describe it is =check =check~ throws
   run!/exit))
(import math/dist  (make-rng rng-next! rng-float! rng-int!
                    erf erfc
                    uniform-pdf uniform-cdf uniform-sample!
                    normal-pdf normal-cdf normal-sample!))
(import math/stats (mean stdev))   ; test-time only: validate sample moments

(describe "dist"

  (describe "rng"
    (it "is deterministic for the same seed"
      (let ((a (make-rng 42)) (b (make-rng 42)))
        (=check (rng-next! a) (rng-next! b))
        (=check (rng-next! a) (rng-next! b))
        (=check (rng-next! a) (rng-next! b))))
    (it "produces different streams for different seeds"
      (let ((a (make-rng 1)) (b (make-rng 2)))
        (is (not (= (rng-next! a) (rng-next! b))))))
    (it "produces non-negative 32-bit fixnums"
      (let ((r (make-rng 7)))
        (let ((x (rng-next! r)))
          (is (>= x 0))
          (is (< x 4294967296)))))
    (it "matches golden values for seed 42"
      (let ((r (make-rng 42)))
        (=check (rng-next! r) 660444221)
        (=check (rng-next! r) 3652823732)
        (=check (rng-next! r) 77672526)))
    (it "rng-float! lies in [0, 1) and rng-int! in [lo, hi)"
      (let ((r (make-rng 99)))
        (let loop ((i 0))
          (if (< i 1000)
              (let ((f (rng-float! r)) (k (rng-int! r 5 10)))
                (is (>= f 0.0)) (is (< f 1.0))
                (is (>= k 5)) (is (< k 10))
                (loop (+ i 1)))))))
    (it "rng-int! errors on degenerate ranges"
      (throws (rng-int! (make-rng 1) 5 5))     ; empty half-open
      (throws (rng-int! (make-rng 1) 9 2))))   ; hi < lo

  (describe "normal"
    (it "pdf at 0 with N(0,1) is 1/sqrt(2pi)"
      (=check~ (normal-pdf 0 0 1) 0.3989422804 1e-9))
    (it "cdf at mu of N(0,1) is 0.5"
      (=check~ (normal-cdf 0 0 1) 0.5 1e-9))
    (it "cdf at mu+sigma is ~0.8413"
      (=check~ (normal-cdf 1 0 1) 0.8413447 1e-6))
    (it "cdf is symmetric: F(-x) + F(x) = 1"
      (=check~ (normal-cdf -1 0 1) 0.1586553 1e-6))
    (it "rejects sigma <= 0"
      (throws (normal-pdf 0 0 0))
      (throws (normal-sample! (make-rng 1) 0 -1))))

  (describe "uniform"
    (it "pdf inside the range is 1/(b-a)"
      (=check~ (uniform-pdf 5 0 10) 0.1 1e-9))
    (it "pdf outside the range is 0"
      (=check~ (uniform-pdf -1 0 10) 0.0 1e-9))
    (it "cdf has the right shape"
      (=check~ (uniform-cdf 2.5 0 10) 0.25 1e-9)
      (=check~ (uniform-cdf -5  0 10) 0.0  1e-9)
      (=check~ (uniform-cdf 99  0 10) 1.0  1e-9))
    (it "uniform-sample! stays in range across 1000 draws"
      (let ((r (make-rng 3)))
        (let loop ((i 0))
          (if (< i 1000)
              (let ((x (uniform-sample! r 2 8)))
                (is (>= x 2)) (is (< x 8)) (loop (+ i 1)))))))
    (it "rejects degenerate range b<a"
      (throws (uniform-pdf 5 10 0))))

  (describe "erf"
    (it "erf(0) = 0"  (=check~ (erf 0)  0.0       1e-7))
    (it "erf(1) ≈ 0.8427"  (=check~ (erf 1)  0.8427007 1e-6))
    (it "is odd: erf(-x) = -erf(x)"  (=check~ (erf -1) -0.8427007 1e-6))
    (it "erf(2) ≈ 0.9953"  (=check~ (erf 2)  0.9953222 1e-6))
    (it "erfc(x) = 1 - erf(x)"  (=check~ (erfc 1) (- 1.0 (erf 1)) 1e-9)))

  (describe "sampling-moments"
    (it "10k normal(5,2) draws have mean ~5 and stdev ~2"
      (let ((r (make-rng 12345)) (n 10000))
        (let ((xs (make-vector n 0)))
          (let loop ((i 0))
            (if (< i n) (begin (vector-set! xs i (normal-sample! r 5 2)) (loop (+ i 1)))))
          (=check~ (mean xs)  5.0 0.1)
          (=check~ (stdev xs) 2.0 0.1))))
    (it "10k uniform(0,10) draws have mean ~5"
      (let ((r (make-rng 678)) (n 10000))
        (let ((xs (make-vector n 0)))
          (let loop ((i 0))
            (if (< i n) (begin (vector-set! xs i (uniform-sample! r 0 10)) (loop (+ i 1)))))
          (=check~ (mean xs) 5.0 0.15))))))

(run!/exit)
