; mandelbrot.lisp — ASCII Mandelbrot poster.
;
; stdin: 4 reals + 2 ints, whitespace-separated:
;   re-min re-max im-min im-max width height
; output: height lines × width chars. Palette goes shallow→deep:
;   set members print as space, fastest escapes as '@'. Inner loop
;   is a self-tail-recursive named let so TCO kicks in (no Zig stack
;   growth per iteration). zr², zi² are computed once per step to
;   shave float allocations from the hot path.

(define palette " .:-=+*#%@")
(define pal-len (string-length palette))
(define max-iter 64)

(define toks
  (filter (lambda (s) (> (string-length s) 0))
          (apply append
                 (map (lambda (l) (string-split l " "))
                      (string-split (file-read-string "/dev/stdin") "\n")))))

(define (n i) (string->number (list-ref toks i)))
(define re-min (n 0)) (define re-max (n 1))
(define im-min (n 2)) (define im-max (n 3))
(define w (n 4))      (define h (n 5))

(define dx (/ (- re-max re-min) (- w 1)))
(define dy (/ (- im-max im-min) (- h 1)))

(define (escape cre cim)
  (let loop ((i 0) (zr 0.0) (zi 0.0))
    (let ((zr2 (* zr zr)) (zi2 (* zi zi)))
      (cond ((>= i max-iter) max-iter)
            ((> (+ zr2 zi2) 4.0) i)
            (else (loop (+ i 1)
                        (+ (- zr2 zi2) cre)
                        (+ (* 2.0 zr zi) cim)))))))

(define (pchar n)
  (string-ref palette (if (= n max-iter) 0 (modulo n pal-len))))

(let row ((y 0))
  (if (= y h) #f
      (let ((cim (- im-max (* y dy))))
        (let col ((x 0))
          (if (= x w)
              (newline)
              (begin
                (display (char->string (pchar (escape (+ re-min (* x dx)) cim))))
                (col (+ x 1)))))
        (row (+ y 1)))))
