(module math/core
  (export pi tau e phi inf neg-inf nan epsilon
          number? integer? float? finite? infinite? nan?
          zero? positive? negative? even? odd?
          sign clamp between? almost-eq? abs-close? rel-close?
          abs floor ceiling round truncate frac modulo remainder
          sqrt cbrt pow exp ln log10 log2 log-base
          sin cos tan asin acos atan atan2 sinh cosh tanh
          hypot fmod
          deg->rad rad->deg square cube copy-sign
          lerp invlerp normalize-range)

  ; Re-export primitives into module env
  (define abs      abs)
  (define floor    floor)
  (define ceiling  ceiling)
  (define round    round)
  (define truncate truncate)
  (define modulo   modulo)
  (define remainder remainder)
  (define sqrt     sqrt)
  (define cbrt     cbrt)
  (define pow      pow)
  (define exp      exp)
  (define ln       ln)
  (define log10    log10)
  (define log2     log2)
  (define sin      sin)
  (define cos      cos)
  (define tan      tan)
  (define asin     asin)
  (define acos     acos)
  (define atan     atan)
  (define atan2    atan2)
  (define sinh     sinh)
  (define cosh     cosh)
  (define tanh     tanh)
  (define hypot    hypot)
  (define fmod     fmod)
  (define number?  number?)
  (define integer? integer?)
  (define float?   float?)
  (define finite?  finite?)
  (define infinite? infinite?)
  (define nan?     nan?)

  ; Constants
  (define pi      3.141592653589793)
  (define tau     6.283185307179586)
  (define e       2.718281828459045)
  (define phi     1.618033988749895)
  (define epsilon 2.220446049250313e-16)
  (define inf     (prim-inf))
  (define neg-inf (prim-neg-inf))
  (define nan     (prim-nan))

  ; Predicates
  (define (zero?     x) (= x 0))
  (define (positive? x) (> x 0))
  (define (negative? x) (< x 0))
  (define (even?     n) (= (modulo n 2) 0))
  (define (odd?      n) (not (even? n)))

  ; Comparison
  (define (sign x)
    (cond ((> x 0)  1)
          ((< x 0) -1)
          (#t       0)))

  (define (clamp x lo hi)
    (if (< x lo) lo (if (> x hi) hi x)))

  (define (between? x lo hi)
    (and (>= x lo) (<= x hi)))

  (define (abs-close? a b tol)
    (<= (abs (- a b)) tol))

  (define (rel-close? a b tol)
    (let ((scale (if (> (abs a) (abs b)) (abs a) (abs b))))
      (<= (abs (- a b)) (* tol scale))))

  (define (almost-eq? a b)
    (let ((diff  (abs (- a b)))
          (scale (if (> (abs a) (abs b)) (abs a) (abs b))))
      (<= diff (if (> 1e-12 (* 1e-9 scale)) 1e-12 (* 1e-9 scale)))))

  ; Rounding
  (define (frac x) (- x (floor x)))

  ; Elementary
  (define (log-base b x) (/ (ln x) (ln b)))

  ; Utilities
  (define (deg->rad d) (* d (/ pi 180.0)))
  (define (rad->deg r) (* r (/ 180.0 pi)))
  (define (square x)   (* x x))
  (define (cube   x)   (* x x x))
  (define (copy-sign x y) (copysign x y))
  (define (lerp    a b t) (+ (* (- 1.0 t) a) (* t b)))
  (define (invlerp a b x) (/ (- x a) (- b a)))
  (define (normalize-range x lo hi) (invlerp lo hi x)))
