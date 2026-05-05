; nqueens.lisp — count distinct N-queens solutions.
; stdin: a single integer n. output: the solution count.
;
; Backtracking row-by-row. Track three sets — taken columns and the
; two diagonal classes (row+col, row-col) — as plain lists. Membership
; via `member` is O(n), which is fine: n=12 explores ~3.4M nodes and
; the bottleneck is allocation, not the linear scans.

(define (queens n)
  (let solve ((row 0) (cols (quote ())) (d1 (quote ())) (d2 (quote ())))
    (if (= row n) 1
        (let try ((col 0) (count 0))
          (if (= col n) count
              (let ((b (+ row col)) (c (- row col)))
                (try (+ col 1)
                     (if (or (member col cols) (member b d1) (member c d2))
                         count
                         (+ count (solve (+ row 1)
                                         (cons col cols)
                                         (cons b d1)
                                         (cons c d2)))))))))))

(display (queens (string->number (string-trim (file-read-string "/dev/stdin")))))
(newline)
