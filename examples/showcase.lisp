; showcase.lisp — exercises string ports, values, vector ops, and hooks/advice

(import hooks (add-hook run-hooks)) ; zepo-y1a4
; zepo-8tow: advise/unadvise/advised? are prelude globals (no import), not hooks
; macros; the old (defadvice ...) form never existed.
(import format (format)) ; zepo-y1a4

; ── String ports: build strings without concatenation ────────────────────────

(define (join sep items)
  (let ((port (open-output-string)))
    (let loop ((lst items) (first #t))
      (when (pair? lst)
        (unless first (port-display port sep))
        (port-display port (car lst))
        (loop (cdr lst) #f)))
    (get-output-string port)))

(display (join ", " '("alpha" "beta" "gamma")))
(newline)
; → alpha, beta, gamma

; ── Multiple values: return several things at once ───────────────────────────

(define (min-max vec)
  (let loop ((i 1) (lo (vector-ref vec 0)) (hi (vector-ref vec 0)))
    (if (= i (vector-length vec))
        (values lo hi)
        (loop (+ i 1)
              (if (< (vector-ref vec i) lo) (vector-ref vec i) lo)
              (if (> (vector-ref vec i) hi) (vector-ref vec i) hi)))))

(call-with-values
  (lambda () (min-max (vector 3 1 4 1 5 9 2 6)))
  (lambda (lo hi)
    (display (format "min=~a  max=~a" lo hi))
    (newline)))
; → min=1  max=9

; ── Vector ops: sliding-window average ───────────────────────────────────────

(define (running-avg data window)
  (let* ((n   (vector-length data))
         (out (make-vector (- n window -1) 0)))
    (let loop ((i 0))
      (when (<= i (- n window))
        (let ((buf (vector-copy data i (+ i window))))
          (let ((sum (let s ((j 0) (acc 0))
                       (if (= j window) acc
                           (s (+ j 1) (+ acc (vector-ref buf j)))))))
            (vector-set! out i (/ sum window))))
        (loop (+ i 1))))
    out))

(display (running-avg (vector 1 2 3 4 5 6 7) 3))
(newline)
; → #(2 3 4 5 6)

; ── Hooks: lifecycle events ───────────────────────────────────────────────────

(define *pipeline-log* (vector))

(add-hook 'pipeline/before
  (lambda ()
    (set! *pipeline-log*
          (vector-append *pipeline-log* (vector "pipeline starting")))))

(add-hook 'pipeline/after
  (lambda ()
    (set! *pipeline-log*
          (vector-append *pipeline-log* (vector "pipeline done")))))

; ── Advice: instrument a function transparently ──────────────────────────────

(define (process items)
  (map (lambda (x) (* x x)) items))

(advise 'process :around
  (lambda (next items)
    (set! *pipeline-log*
          (vector-append *pipeline-log*
                         (vector (format "processing ~a items" (length items)))))
    (next items)))

; ── Run the pipeline ─────────────────────────────────────────────────────────

(run-hooks 'pipeline/before)
(let ((result (process '(1 2 3 4 5))))
  (run-hooks 'pipeline/after)
  (display (format "result: ~a" result))
  (newline))

; Print the log using string ports
(let ((port (open-output-string)))
  (port-display port "--- log ---\n")
  (let loop ((i 0))
    (when (< i (vector-length *pipeline-log*))
      (port-display port (format "  ~a. ~a\n" (+ i 1) (vector-ref *pipeline-log* i)))
      (loop (+ i 1))))
  (display (get-output-string port)))
