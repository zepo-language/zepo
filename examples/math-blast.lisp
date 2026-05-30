;; zepo-8rd: integrated blast-test + benchmark for the math layer —
;; math/dist (seeded PRNG + distributions), math/stats (descriptive + regression),
;; and math/tensor (n-dimensional arrays). The point is that they COMPOSE: we
;; generate data with dist, summarize it with stats, shape/reduce it with tensor,
;; and cross-check the three against each other. Any mismatch aborts via (error).
;; A timed benchmark phase follows; tune volume with:  zepo math-blast.lisp -- 4
(import math/core   (abs-close?)) ; zepo-y1a4
(import math/tensor (from-nested shape transpose tensor->nested reshape ; zepo-y1a4
                     slice t* t+ t-zip t-sum t-equal? matmul tensor t-mean))
(import math/stats  (mean stdev median quantile correlation summary linreg sum)) ; zepo-y1a4
(import math/dist   (make-rng rng-next! rng-float! erf ; zepo-y1a4
                     normal-cdf normal-sample! uniform-sample!))

(define checks 0)
(define (check label got want)
  (set! checks (+ checks 1))
  (if (equal? got want)
      (begin (display "  ok  ") (display label) (newline))
      (error "FAIL" label 'got got 'want want)))
(define (check~ label got want tol)   ; approximate (floats)
  (set! checks (+ checks 1))
  (if (abs-close? got want tol)
      (begin (display "  ok  ") (display label) (newline))
      (error "FAIL~" label 'got got 'want want)))

;; fill a fresh Scheme vector with n samples from (thunk)
(define (gen-vec n thunk)
  (let ((v (make-vector n 0)))
    (let loop ((i 0))
      (if (= i n) v (begin (vector-set! v i (thunk)) (loop (+ i 1)))))))

;; ── Section 1: math/dist — seeded PRNG + distributions ──────────────────────
(display "Section 1: dist (seeded PRNG + distributions)") (newline)
(check "rng golden (seed 42, draw 1)" (rng-next! (make-rng 42)) 660444221)
(let ((a (make-rng 7)) (b (make-rng 7)))
  (check "same seed => same stream" (rng-next! a) (rng-next! b)))
(check~ "erf(1)"            (erf 1)            0.8427007  1e-6)
(check~ "erf is odd"        (erf -1)           (- (erf 1)) 1e-9)
(check~ "normal-cdf at mu"  (normal-cdf 0 0 1) 0.5        1e-9)
(check~ "normal-cdf mu+sigma" (normal-cdf 1 0 1) 0.8413447 1e-6)
;; 20k normal(5,2) draws: sample moments must land near the parameters
(let* ((r  (make-rng 12345))
       (xs (gen-vec 20000 (lambda () (normal-sample! r 5 2)))))
  (check~ "normal sample mean ~ 5"  (mean xs)  5.0 0.1)
  (check~ "normal sample stdev ~ 2" (stdev xs) 2.0 0.1))
;; 20k uniform(0,10): mean ~ 5
(let* ((r  (make-rng 99))
       (us (gen-vec 20000 (lambda () (uniform-sample! r 0 10)))))
  (check~ "uniform sample mean ~ 5" (mean us) 5.0 0.15))

;; ── Section 2: math/stats — descriptive + regression ────────────────────────
(display "Section 2: stats (descriptive + regression)") (newline)
(define sample (list 2 4 4 4 5 5 7 9))
(check~ "mean"     (mean sample)     5.0 1e-9)
(check~ "stdev"    (stdev sample)    2.1380899353 1e-9)
(check~ "median"   (median sample)   4.5          1e-9)
(check~ "q1"       (quantile sample 0.25) 4.0      1e-9)
(check~ "corr of y=2x+1 is 1" (correlation (list 1 2 3 4) (list 3 5 7 9)) 1.0 1e-9)
(let ((s (summary (list 1 2 3 4 5 6 7 8))))
  (check "summary n" (hash-get s 'n 0) 8)
  (check~ "summary median" (hash-get s 'median 0) 4.5 1e-9)
  (check~ "summary q3"     (hash-get s 'q3 0)     6.25 1e-9))
(let ((m (linreg (list 1 2 3 4) (list 3 5 7 9))))   ; exact y = 2x+1
  (check~ "linreg slope"     (hash-get m 'slope 0)     2.0 1e-9)
  (check~ "linreg intercept" (hash-get m 'intercept 0) 1.0 1e-9)
  (check~ "linreg r2"        (hash-get m 'r2 0)        1.0 1e-9))

;; ── Section 3: math/tensor — shaping, reduction, linear algebra ─────────────
(display "Section 3: tensor (shape ops + reductions + matmul)") (newline)
(define A (from-nested (list (list 1 2 3) (list 4 5 6))))    ; 2x3
(check "shape"            (shape A)            (list 2 3))
(check "transpose shape"  (shape (transpose A)) (list 3 2))
(check "transpose data"   (tensor->nested (transpose A)) (list (list 1 4) (list 2 5) (list 3 6)))
(check "reshape"          (tensor->nested (reshape A (list 3 2))) (list (list 1 2) (list 3 4) (list 5 6)))
(check "slice axis1 [1,3)" (tensor->nested (slice A 1 1 3)) (list (list 2 3) (list 5 6)))
(check "scalar t* (order-free)" (tensor->nested (t* A 10)) (list (list 10 20 30) (list 40 50 60)))
(check "elementwise t+"   (tensor->nested (t+ A A)) (list (list 2 4 6) (list 8 10 12)))
(check "t-zip max"        (tensor->nested (t-zip max A (t* A 0))) (list (list 1 2 3) (list 4 5 6)))
(check "t-sum axis0 (cols)" (tensor->nested (t-sum A 0)) (list 5 7 9))
(check "t-sum axis1 (rows)" (tensor->nested (t-sum A 1)) (list 6 15))
(check "matmul A·Aᵀ"      (tensor->nested (matmul A (transpose A))) (list (list 14 32) (list 32 77)))
(check "t-equal? self"    (t-equal? A A) #t)

;; ── Section 4: integration — the three modules cross-checking each other ────
(display "Section 4: integration (stats × dist × tensor)") (newline)
;; (4a) tensor whole-reduce must equal the stats fold over the same flat data.
(define flat (list 3 1 4 1 5 9 2 6 5 3 5 8))
(define T (tensor (list 3 4) flat))
(check  "tensor t-sum == stats sum"  (t-sum T)  (sum flat))
(check~ "tensor t-mean == stats mean" (t-mean T) (mean flat) 1e-9)
;; (4b) seeded samples: a tensor built from them reduces to the same mean stats sees.
(let* ((r  (make-rng 2024))
       (xs (gen-vec 4000 (lambda () (normal-sample! r 10 3))))
       (tx (tensor (list 4000) xs)))
  (check~ "tensor-of-samples mean == stats mean" (t-mean tx) (mean xs) 1e-9)
  (check~ "sample mean ~ 10"  (t-mean tx) 10.0 0.2))
;; (4c) regression recovers a planted line through noisy, RNG-generated data.
(let* ((r  (make-rng 555))
       (n  3000)
       (xs (gen-vec n (lambda () (uniform-sample! r 0 100))))
       (ys (let ((v (make-vector n 0)))
             (let loop ((i 0))
               (if (= i n) v
                   (begin
                     (vector-set! v i (+ (* 3.0 (vector-ref xs i)) 5.0 (normal-sample! r 0 1)))
                     (loop (+ i 1)))))))
       (m  (linreg xs ys)))
  (check~ "noisy linreg slope ~ 3"     (hash-get m 'slope 0)     3.0 0.05)
  (check~ "noisy linreg intercept ~ 5" (hash-get m 'intercept 0) 5.0 1.0)
  (check~ "noisy linreg r2 ~ 1"        (hash-get m 'r2 0)        1.0 0.01))

;; ── Correctness summary ─────────────────────────────────────────────────────
(display "ALL ") (display checks) (display " CHECKS PASSED") (newline)
(newline)

;; ── Benchmark phase ─────────────────────────────────────────────────────────
;;   zepo examples/math-blast.lisp -- <scale>   (default 1)
(define (parse-scale args)
  (let loop ((a args) (found 1))
    (if (null? a) found
        (let ((n (string->number (car a))))
          (loop (cdr a) (if (and n (> n 0)) n found))))))
(define scale (parse-scale (argv)))

(define (repeat n thunk)
  (let loop ((i 0)) (if (< i n) (begin (thunk) (loop (+ i 1))))))

(define (bench label ops thunk)
  (let ((t0 (current-time-ms)))
    (thunk)
    (let ((dt (- (current-time-ms) t0)))
      (display "  ") (display label) (display ": ")
      (display ops) (display " ops in ") (display dt) (display " ms")
      (if (> dt 0)
          (begin (display "  (") (display (quotient (* ops 1000) dt)) (display " ops/sec)")))
      (newline))))

(display "Benchmark (scale=") (display scale) (display ")") (newline)
;; Data sizes are FIXED (pure-Lisp tensors hold individually boxed floats, so
;; large buffers are memory-heavy — the deferred f64vector primitive is what
;; would lift that). `scale` repeats each workload instead, scaling work without
;; growing peak memory.

;; B1: dense matmul (N×N)·(N×N), repeated. ops = scale·2·N³ multiply-adds.
(define N 50)
(let* ((r  (make-rng 1))
       (MA (tensor (list N N) (gen-vec (* N N) (lambda () (rng-float! r)))))
       (MB (tensor (list N N) (gen-vec (* N N) (lambda () (rng-float! r))))))
  (bench "matmul N×N" (* scale 2 N N N) (lambda () (repeat scale (lambda () (matmul MA MB))))))

;; B2/B3: elementwise + whole-tensor reduction over a big 1-D tensor, repeated.
(define M 50000)
(let* ((r (make-rng 2))
       (big (tensor (list M) (gen-vec M (lambda () (rng-float! r))))))
  (bench "tensor elementwise t*" (* scale M) (lambda () (repeat scale (lambda () (t* big 1.5)))))
  (bench "tensor reduce t-sum"   (* scale M) (lambda () (repeat scale (lambda () (t-sum big))))))

;; B4: distribution sampling throughput (results discarded — memory-flat, so it scales by count).
(define S (* 50000 scale))
(let ((r (make-rng 3)))
  (bench "normal-sample!" S (lambda ()
    (let loop ((i 0)) (if (< i S) (begin (normal-sample! r 0 1) (loop (+ i 1))))))))

;; B5: stats summary, repeated. summary sorts (for quantiles) so it is the
;; O(n log n) heavy op. Post-zepo-sb7 stats has a vector-based bottom-up
;; merge sort. The default 4 MiB heap caps this around ~50k elements; bump
;; with `--max-heap=16M` (or ZEPO_MAX_HEAP=16M) to run 100k+ comfortably
;; (zepo-nmqj).
(let ((xs (gen-vec 50000 (let ((r (make-rng 4))) (lambda () (rng-float! r))))))
  (bench "stats summary (sort-bound)" (* scale 50000)
         (lambda () (repeat scale (lambda () (summary xs))))))
