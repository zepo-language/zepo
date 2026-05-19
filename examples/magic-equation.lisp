; magic-equation.lisp — detect the pattern in a number series and predict the next term.
;
; Handles two common patterns:
;   Arithmetic:  constant difference between consecutive terms  (e.g. 3 6 9 12)
;   Geometric:   constant ratio between consecutive terms       (e.g. 2 4 8 16)
;
; Usage:
;   zepo examples/magic-equation.lisp -- 2 4 8 16 32 64 128
;   zepo examples/magic-equation.lisp -- 3 6 9 12 15
;   zepo examples/magic-equation.lisp -- 1 3 9 27 81

(define (differences xs)
  (let loop ((xs xs) (acc (quote ())))
    (if (or (null? xs) (null? (cdr xs)))
        (reverse acc)
        (loop (cdr xs) (cons (- (cadr xs) (car xs)) acc)))))

(define (ratios xs)
  (let loop ((xs xs) (acc (quote ())))
    (if (or (null? xs) (null? (cdr xs)))
        (reverse acc)
        (let ((a (car xs))
              (b (cadr xs)))
          (if (= a 0)
              #f
              (loop (cdr xs) (cons (/ b a) acc)))))))

(define (all-equal? xs)
  (if (or (null? xs) (null? (cdr xs)))
      #t
      (and (= (car xs) (cadr xs))
           (all-equal? (cdr xs)))))

(define (predict series)
  (if (< (length series) 2)
      (error "need at least 2 terms" series)
      (let* ((diffs (differences series))
             (last  (car (reverse series))))
        (if (all-equal? diffs)
            (let ((d (car diffs)))
              (list 'arithmetic d (+ last d)))
            (let ((rs (ratios series)))
              (if (and rs (all-equal? rs))
                  (let ((r (car rs)))
                    (list 'geometric r (* last r)))
                  (list 'unknown #f #f)))))))

(define (number->display n)
  (if (and (not (integer? n)) (= n (floor n)))
      (number->string (inexact->exact (floor n)))
      (number->string n)))

(define (show-series xs)
  (let loop ((xs xs) (first #t))
    (if (null? xs)
        (display " ...")
        (begin
          (if (not first) (display ", "))
          (display (number->display (car xs)))
          (loop (cdr xs) #f)))))

(define (run series)
  (display "Series: ")
  (show-series series)
  (newline)
  (let ((result (predict series)))
    (let ((kind (car result))
          (param (cadr result))
          (next  (caddr result)))
      (cond
        ((eq? kind 'arithmetic)
         (display "Pattern: arithmetic (add ")
         (display (number->display param))
         (display " each step)")
         (newline)
         (display "Next:    ")
         (display (number->display next))
         (newline))
        ((eq? kind 'geometric)
         (display "Pattern: geometric (multiply by ")
         (display (number->display param))
         (display " each step)")
         (newline)
         (display "Next:    ")
         (display (number->display next))
         (newline))
        (else
         (display "Pattern: unrecognised (not arithmetic or geometric)")
         (newline)))))
  (newline))

; Parse command-line args if provided, otherwise run built-in demos.
; argv = (binary script -- arg...) — skip binary, script, and "--" separator.
(define raw-argv (argv))
(define args (if (>= (length raw-argv) 3) (cddr raw-argv) (quote ())))

(if (not (null? args))
    (let ((series (map (lambda (s)
                         (let ((n (string->number s)))
                           (if n n (error "not a number" s))))
                       args)))
      (run series))
    (begin
      (run '(2 4 8 16 32 64 128))
      (run '(3 6 9 12 15))
      (run '(1 3 9 27 81))
      (run '(100 50 25))
      (run '(7 14 21 28 35))))
