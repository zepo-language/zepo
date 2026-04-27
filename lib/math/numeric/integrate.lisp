(module math/numeric/integrate
  (export midpoint trapz simpson)

  (define (midpoint f a b n)
    (let* ((h (/ (- b a) n))
           (half (* h 0.5)))
      (let loop ((i 0) (acc 0))
        (if (= i n)
            (* h acc)
            (loop (+ i 1) (+ acc (f (+ a (* i h) half))))))))

  (define (trapz f a b n)
    (let* ((h (/ (- b a) n)))
      (let loop ((i 1) (acc (+ (f a) (f b))))
        (if (= i n)
            (* (/ h 2.0) acc)
            (loop (+ i 1) (+ acc (* 2 (f (+ a (* i h))))))))))

  (define (simpson f a b n)
    ; n must be even
    (let* ((n2 (if (= (modulo n 2) 0) n (+ n 1)))
           (h (/ (- b a) n2)))
      (let loop ((i 1) (acc (+ (f a) (f b))))
        (if (= i n2)
            (* (/ h 3.0) acc)
            (let ((coeff (if (= (modulo i 2) 0) 2 4)))
              (loop (+ i 1) (+ acc (* coeff (f (+ a (* i h))))))))))))
