; van-eck.lisp — print the first 1000 terms of the Van Eck sequence.
;
; Rules:
;   a(0) = 0
;   a(n+1) = 0                         if a(n) has not appeared in a(0..n-1)
;   a(n+1) = n - last_index_of(a(n))   otherwise
;
; OEIS A181391.
;
; Implementation: walk a(0)..a(999), keeping a hash table from value to its
; most recent index. For each step, compute the next term BEFORE recording
; the current index — "previously" means strictly before n.

(define n-terms 1000)

(define seen (make-hash-table))

(let loop ((i 0) (cur 0))
  (display cur) (newline)
  (if (= i (- n-terms 1))
      #f
      (let ((next (let ((prev (hash-get seen cur #f)))
                    (if prev (- i prev) 0))))
        (hash-set! seen cur i)
        (loop (+ i 1) next))))
