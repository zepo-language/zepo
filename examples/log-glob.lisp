; log-glob.lisp — count log lines matching each glob pattern.
;
; stdin format: patterns, one per line; one blank line; then log lines.
; Wildcards: * = any sequence (incl. empty), ? = exactly one character.
; Output: one line per pattern — "<pattern> <count>".

(define (m p t pi ti pl tl)
  (cond ((= pi pl) (= ti tl))
        ((char=? (string-ref p pi) #\*)
         (or (m p t (+ pi 1) ti pl tl)
             (and (< ti tl) (m p t pi (+ ti 1) pl tl))))
        ((= ti tl) #f)
        ((char=? (string-ref p pi) #\?)
         (m p t (+ pi 1) (+ ti 1) pl tl))
        ((char=? (string-ref p pi) (string-ref t ti))
         (m p t (+ pi 1) (+ ti 1) pl tl))
        (else #f)))

(define (split-blank ls)
  (let loop ((ps '()) (ls ls))
    (cond ((null? ls)             (cons (reverse ps) '()))
          ((string=? (car ls) "") (cons (reverse ps) (cdr ls)))
          (else                   (loop (cons (car ls) ps) (cdr ls))))))

(define halves   (split-blank (string-split (file-read-string "/dev/stdin") "\n")))
(define patterns (car halves))
(define logs     (cdr halves))

(for-each
  (lambda (p)
    (let ((pl (string-length p)))
      (let cnt ((ls logs) (n 0))
        (cond ((null? ls) (display p) (display " ") (display n) (newline))
              ((m p (car ls) 0 0 pl (string-length (car ls)))
               (cnt (cdr ls) (+ n 1)))
              (else (cnt (cdr ls) n))))))
  patterns)
