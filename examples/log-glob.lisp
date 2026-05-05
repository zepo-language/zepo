; log-glob.lisp — count log lines matching each glob pattern.
;
; stdin format: patterns, one per line; one blank line; then log lines.
; Wildcards: * = any sequence (incl. empty), ? = exactly one character.
; Output: one line per pattern — "<pattern> <count>".

; Iterative two-pointer glob matcher. O(n*m) regardless of star count —
; each `*` records the latest backtrack anchor; on a mismatch we just
; extend the most-recent star's match by one more character. Never
; explores the combinatorial split-points that the naive recursive form
; falls into for patterns like *a*a*a*a*.
(define (m p t pl tl)
  (let loop ((pi 0) (ti 0) (sp -1) (st 0))
    (cond
      ; Both consumed → success. Pattern done but text remaining → handled
      ; below (we trail to consume more text via the star anchor).
      ((= ti tl)
       (let trail ((pi pi))
         (cond ((= pi pl) #t)
               ((char=? (string-ref p pi) #\*) (trail (+ pi 1)))
               (else #f))))
      ; Pattern char matches text char (literal or ?) → advance both.
      ((and (< pi pl)
            (or (char=? (string-ref p pi) #\?)
                (char=? (string-ref p pi) (string-ref t ti))))
       (loop (+ pi 1) (+ ti 1) sp st))
      ; Pattern char is *: record anchor, advance pattern only.
      ((and (< pi pl) (char=? (string-ref p pi) #\*))
       (loop (+ pi 1) ti pi (+ ti 1)))
      ; Mismatch but we have a remembered star: backtrack to it,
      ; consuming one more text char than last time.
      ((>= sp 0)
       (loop (+ sp 1) st sp (+ st 1)))
      ; No anchor available → fail.
      (else #f))))

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
              ((m p (car ls) pl (string-length (car ls)))
               (cnt (cdr ls) (+ n 1)))
              (else (cnt (cdr ls) n))))))
  patterns)
