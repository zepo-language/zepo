(module math/dist
  (export make-rng rng-next! rng-float! rng-int! erf erfc)

  (import math/core)   ; pi, square (used later)

  ;; zepo-7uu: 32-bit helpers. Lanes are kept as non-negative fixnums < 2^32.
  (define mask32 4294967295)            ; #xFFFFFFFF
  (define (m32 x) (bitwise-and x mask32))
  (define (rotl x k)
    (m32 (bitwise-or (m32 (arithmetic-shift x k))
                     (arithmetic-shift x (- k 32)))))

  ;; zepo-7uu: 32-bit modular multiply via 16-bit split. A full 32x32 product
  ;; (~2^64) exceeds Zepo's fixnum range and would silently promote to float and
  ;; LOSE the low bits the PRNG relies on. Splitting b into hi/lo 16-bit halves
  ;; keeps every intermediate < 2^48 (well within fixnum range).
  (define (mul32 a b)
    (m32 (+ (m32 (* a (bitwise-and b 65535)))
            (arithmetic-shift (m32 (* a (arithmetic-shift b -16))) 16))))

  ;; splitmix32 step — expands a seed into well-mixed 32-bit words (mul32 keeps
  ;; the multiplies overflow-safe).
  (define (splitmix32-next state)        ; returns (cons new-state output)
    (let* ((z0 (m32 (+ state 2654435769)))           ; +0x9E3779B9
           (z1 (mul32 (bitwise-xor z0 (arithmetic-shift z0 -16)) 569420461))  ; *0x21F0AAAD
           (z2 (mul32 (bitwise-xor z1 (arithmetic-shift z1 -15)) 1935289751)) ; *0x735A2D97
           (z3 (m32 (bitwise-xor z2 (arithmetic-shift z2 -15)))))
      (cons z0 z3)))

  ;; rng state = a length-4 vector of 32-bit lanes.
  (define (make-rng seed)
    (let ((st (make-vector 4 0)))
      (let loop ((i 0) (s (m32 seed)))
        (if (= i 4)
            (begin
              ;; guard against the all-zero state
              (if (and (= (vector-ref st 0) 0) (= (vector-ref st 1) 0)
                       (= (vector-ref st 2) 0) (= (vector-ref st 3) 0))
                  (vector-set! st 0 1))
              st)
            (let ((p (splitmix32-next s)))
              (vector-set! st i (cdr p))
              (loop (+ i 1) (car p)))))))

  ;; xoshiro128** next 32-bit output; advances state in place.
  (define (rng-next! st)
    (let* ((s0 (vector-ref st 0)) (s1 (vector-ref st 1))
           (s2 (vector-ref st 2)) (s3 (vector-ref st 3))
           (result (m32 (* (rotl (m32 (* s1 5)) 7) 9)))
           (t (m32 (arithmetic-shift s1 9))))
      (let ((n2 (bitwise-xor s2 s0))
            (n3 (bitwise-xor s3 s1)))
        (let ((n1 (bitwise-xor s1 n2))
              (n0 (bitwise-xor s0 n3)))
          (vector-set! st 0 n0)
          (vector-set! st 1 n1)
          (vector-set! st 2 (bitwise-xor n2 t))
          (vector-set! st 3 (rotl n3 11))
          result))))

  ;; zepo-7uu: Abramowitz & Stegun 7.1.26 rational approximation, |err| <= 1.5e-7.
  (define (erf x)
    (let* ((ax (abs x))
           (tt (/ 1.0 (+ 1.0 (* 0.3275911 ax))))
           (poly (* tt (+ 0.254829592
                          (* tt (+ -0.284496736
                                   (* tt (+ 1.421413741
                                            (* tt (+ -1.453152027
                                                     (* tt 1.061405429))))))))))
           (y (- 1.0 (* poly (exp (- (* ax ax)))))))
      (if (< x 0) (- y) y)))

  (define (erfc x) (- 1.0 (erf x)))

  (define two32 4294967296.0)           ; 2^32 as float

  ;; uniform float in [0,1) at 32-bit precision.
  (define (rng-float! st) (/ (rng-next! st) two32))

  ;; zepo-7uu: uniform integer in [lo,hi) — rejection sampling to avoid modulo bias.
  (define (rng-int! st lo hi)
    (let ((range (- hi lo)))
      (if (<= range 0) (error "rng-int!: hi must be > lo"))
      (let ((threshold (- 4294967296 (modulo 4294967296 range))))
        (let loop ()
          (let ((x (rng-next! st)))
            (if (< x threshold) (+ lo (modulo x range)) (loop))))))))
