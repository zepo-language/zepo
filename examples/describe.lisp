;; zepo-4yf: one-page statistical summary of a numeric CSV column.
;; Usage:  zepo examples/describe.lisp -- <file.csv> <column> [nbuckets]
;; Opens the CSV with csvdb, pulls the named column, coerces each field with
;; string->number (skipping blank/non-numeric cells), then prints n, mean,
;; stdev, the five-number summary, and an equal-width ASCII histogram.
(import csvdb/api (csv-open csv-columns csv-select)) ; zepo-y1a4
(import math/stats (summary)) ; zepo-y1a4

;; argv after the script path is (script "--" file column [nbuckets]); drop the
;; script path and the "--" separator to get the positional args.
(define raw (filter (lambda (s) (not (equal? s "--"))) (cdr (argv))))
(if (< (length raw) 2)
    (error "usage: zepo examples/describe.lisp -- <file.csv> <column> [nbuckets]"))

(define file    (car raw))
(define column  (cadr raw))
(define nbuckets (if (>= (length raw) 3) (string->number (caddr raw)) 10))
(if (or (not nbuckets) (< nbuckets 1)) (error "describe: nbuckets must be a positive integer"))

;; ── load + validate column ──────────────────────────────────────────────────
(define table (csv-open file (make-hash-table)))
(define col-names (csv-columns table))
(if (not (member column col-names))
    (error (string-append "describe: no column '" column "'; available: "
                          (apply string-append
                                 (map (lambda (c) (string-append c " ")) col-names)))))

;; ── pull the column as numbers (skip blanks / non-numeric) ───────────────────
(define opts (make-hash-table))
(hash-set! opts 'as ':maps)
(define rows (csv-select table opts))

(define pulled
  (let loop ((i 0) (acc (quote ())) (skipped 0))
    (if (= i (vector-length rows))
        (cons (list->vector (reverse acc)) skipped)
        (let ((x (string->number (hash-get (vector-ref rows i) column ""))))
          (if x
              (loop (+ i 1) (cons x acc) skipped)
              (loop (+ i 1) acc (+ skipped 1)))))))
(define v       (car pulled))
(define skipped (cdr pulled))
(if (= (vector-length v) 0)
    (error (string-append "describe: column '" column "' has no numeric values")))

;; ── histogram: equal-width buckets over [min,max], top edge in last bucket ───
(define s   (summary v))
(define lo  (hash-get s 'min 0))
(define hi  (hash-get s 'max 0))
(define width (if (= hi lo) 1.0 (/ (- hi lo) nbuckets)))
(define counts (make-vector nbuckets 0))
(let loop ((i 0))
  (if (< i (vector-length v))
      (let* ((x  (vector-ref v i))
             (b0 (if (= hi lo) 0 (inexact->exact (floor (/ (- x lo) width)))))
             (b  (if (>= b0 nbuckets) (- nbuckets 1) (if (< b0 0) 0 b0))))
        (vector-set! counts b (+ 1 (vector-ref counts b)))
        (loop (+ i 1)))))

;; ── formatting helpers ───────────────────────────────────────────────────────
(define (r4 x) (/ (round (* x 10000.0)) 10000.0))   ; round to 4 decimals
(define (bar-str n)
  (let loop ((i 0) (acc ""))
    (if (= i n) acc (loop (+ i 1) (string-append acc "#")))))
(define (max-count)
  (let loop ((i 0) (m 1))
    (if (= i nbuckets) m
        (loop (+ i 1) (if (> (vector-ref counts i) m) (vector-ref counts i) m)))))

;; ── report ───────────────────────────────────────────────────────────────────
(display "── describe: ") (display column) (display "  (") (display file) (display ") ──") (newline)
(display "  n        ") (display (hash-get s 'n 0)) (newline)
(display "  mean     ") (display (r4 (hash-get s 'mean 0))) (newline)
(display "  stdev    ") (display (r4 (hash-get s 'stdev 0))) (newline)
(display "  min      ") (display (r4 (hash-get s 'min 0))) (newline)
(display "  q1       ") (display (r4 (hash-get s 'q1 0))) (newline)
(display "  median   ") (display (r4 (hash-get s 'median 0))) (newline)
(display "  q3       ") (display (r4 (hash-get s 'q3 0))) (newline)
(display "  max      ") (display (r4 (hash-get s 'max 0))) (newline)
(if (> skipped 0)
    (begin (display "  (skipped ") (display skipped) (display " non-numeric cells)") (newline)))
(newline)
(display "  histogram (") (display nbuckets) (display " buckets, width ") (display (r4 width)) (display ")") (newline)
(let ((mc (max-count)))
  (let loop ((b 0))
    (if (< b nbuckets)
        (let* ((e0 (+ lo (* b width)))
               (e1 (+ lo (* (+ b 1) width)))
               (c  (vector-ref counts b))
               (len (inexact->exact (round (/ (* 40 c) mc)))))
          (display "  [") (display (r4 e0)) (display ", ") (display (r4 e1))
          (display (if (= b (- nbuckets 1)) "]  " ")  "))
          (display c) (display "  ") (display (bar-str len)) (newline)
          (loop (+ b 1))))))
