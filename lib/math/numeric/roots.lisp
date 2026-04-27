(module math/numeric/roots
  (export bisect-root newton-root secant-root)

  (define (almost-zero? x) (< (abs x) 1e-12))

  (define (bisect-iter f a b iter max-iter tol)
    (if (>= iter max-iter)
        (error "bisect-root: max iterations reached"))
    (let* ((mid (/ (+ a b) 2.0))
           (fmid (f mid)))
      (if (or (almost-zero? fmid) (< (- b a) (* 2 tol)))
          mid
          (if (< (* (f a) fmid) 0)
              (bisect-iter f a mid (+ iter 1) max-iter tol)
              (bisect-iter f mid b (+ iter 1) max-iter tol)))))

  (define (bisect-root f lo hi :tol 1e-9 :max-iter 1000)
    (if (> (* (f lo) (f hi)) 0)
        (error "bisect-root: f(lo) and f(hi) must have opposite signs"))
    (bisect-iter f lo hi 0 max-iter tol))

  (define (newton-iter f df x iter max-iter tol)
    (if (>= iter max-iter)
        (error "newton-root: max iterations reached"))
    (let* ((fx (f x))
           (dfx (df x)))
      (if (almost-zero? dfx) (error "newton-root: zero derivative"))
      (let ((x1 (- x (/ fx dfx))))
        (if (< (abs (- x1 x)) tol)
            x1
            (newton-iter f df x1 (+ iter 1) max-iter tol)))))

  (define (newton-root f df x0 :tol 1e-9 :max-iter 100)
    (newton-iter f df x0 0 max-iter tol))

  (define (secant-iter f xa xb iter max-iter tol)
    (if (>= iter max-iter)
        (error "secant-root: max iterations reached"))
    (let* ((fa (f xa)) (fb (f xb))
           (denom (- fb fa)))
      (if (almost-zero? denom) (error "secant-root: division by near-zero"))
      (let ((xc (- xb (* fb (/ (- xb xa) denom)))))
        (if (< (abs (- xc xb)) tol)
            xc
            (secant-iter f xb xc (+ iter 1) max-iter tol)))))

  (define (secant-root f x0 x1 :tol 1e-9 :max-iter 100)
    (secant-iter f x0 x1 0 max-iter tol)))
