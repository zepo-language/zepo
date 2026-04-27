(module format
  (export format)

  ; Scheme-style format — directives:
  ;   ~a   display (no quotes on strings)
  ;   ~s   write   (machine-readable, strings quoted)
  ;   ~%   newline
  ;   ~~   literal tilde

  (define (format fmt . args)
    (let ((tilde (string-ref "~" 0))
          (ch-a  (string-ref "a" 0))
          (ch-s  (string-ref "s" 0))
          (ch-pct (string-ref "%" 0))
          (len   (string-length fmt)))
      (letrec
        ((go (lambda (i args acc)
           (cond
             ((= i len)
              (apply string-append (reverse acc)))
             ((char=? (string-ref fmt i) tilde)
              (if (= (+ i 1) len)
                (error "format: incomplete directive at end of string")
                (let ((d (string-ref fmt (+ i 1))))
                  (cond
                    ((char=? d ch-a)
                     (if (null? args)
                       (error "format: not enough arguments for ~a")
                       (go (+ i 2) (cdr args)
                           (cons (display-to-string (car args)) acc))))
                    ((char=? d ch-s)
                     (if (null? args)
                       (error "format: not enough arguments for ~s")
                       (go (+ i 2) (cdr args)
                           (cons (write-to-string (car args)) acc))))
                    ((char=? d ch-pct)
                     (go (+ i 2) args (cons "\n" acc)))
                    ((char=? d tilde)
                     (go (+ i 2) args (cons "~" acc)))
                    (else
                     (error "format: unknown directive" (char->string d)))))))
             (else
              (go (+ i 1) args
                  (cons (char->string (string-ref fmt i)) acc)))))))
        (go 0 args '())))))
