;; zepo-wiv: worker blast-test. Hammers the recently-landed worker features:
;;   1. quasiquoted form entry with NO captures (worker computes from channel input)
;;   2. quasiquoted form entry WITH captured values — scalars spliced via `,`,
;;      compound data quoted via `',x` so the worker treats it as a literal datum
;;      rather than evaluating it as code
;;   3. portable hashtables crossing worker channels in BOTH directions:
;;      multi-entry, nested list values, and hashtable-valued entries, plus a
;;      streamed batch of 20 tables through one long-lived worker.
;; Channels are shared FIFOs, so each worker gets its own in/out pair to avoid a
;; sender dequeuing its own message. Any mismatch aborts via (error ...); reach
;; the end and every assertion held.

(define checks 0)                                          ; zepo-wiv
(define (check label got want)
  (set! checks (+ checks 1))
  (if (equal? got want)
      (begin (display "  ok  ") (display label) (newline))
      (error "FAIL" label 'got got 'want want)))

;; ── Section 1: quasiquoted form, no captures ────────────────────────────────
(display "Section 1: quasiquoted form, no captures") (newline)
(let loop ((i 0))
  (if (< i 8)
      (let ((in (make-channel 1)) (out (make-channel 1)))
        (spawn-worker
          `(lambda (in out)
             (let ((n (channel-recv! in)))
               (channel-send! out (* n n))))
          in out)
        (channel-send! in i)
        (check (string-append "square " (number->string i))
               (channel-recv! out) (* i i))
        (loop (+ i 1)))))

;; ── Section 2: quasiquoted form, captured values ────────────────────────────
(display "Section 2: quasiquoted form, captured values") (newline)
(define multiplier 3)
(define offset 100)
(define labels (list "alpha" "beta" "gamma"))
(let ((in (make-channel 1)) (out (make-channel 1)))
  ;; scalars (multiplier, offset) spliced by value; labels list embedded as a
  ;; quoted literal so the worker does not try to call "alpha".
  (spawn-worker
    `(lambda (in out)
       (let ((n (channel-recv! in)))
         (channel-send! out
           (cons (+ (* n ,multiplier) ,offset) ',labels))))
    in out)
  (channel-send! in 7)
  (check "captured scalars + quoted list"
         (channel-recv! out)
         (cons (+ (* 7 multiplier) offset) labels)))   ; => (121 "alpha" "beta" "gamma")

(define nums (list 5 10 15 20))
(define base 1)
(let ((out (make-channel 1)))
  ;; a captured numeric list, quoted, folded by the worker with a captured base.
  (spawn-worker
    `(lambda (out)
       (channel-send! out (apply + ,base ',nums)))
    out)
  (check "captured numeric list folded"
         (channel-recv! out)
         (apply + base nums)))                          ; => 51

;; ── Section 3: portable hashtables across channels ──────────────────────────
(display "Section 3: portable hashtables across channels") (newline)

;; 3a. multi-entry table in, derived table back (scalar, string, nested list).
(let ((in (make-channel 1)) (out (make-channel 1)))
  (spawn-worker
    `(lambda (in out)
       (let ((cfg (channel-recv! in)))
         (let ((res (make-hash-table)))
           (hash-set! res "limit2" (* 2 (hash-get cfg "limit" 0)))
           (hash-set! res "name" (hash-get cfg "name" ""))
           (hash-set! res "tags" (hash-get cfg "tags" (quote ())))
           (channel-send! out res))))
    in out)
  (define cfg (make-hash-table))
  (hash-set! cfg "limit" 100)
  (hash-set! cfg "name" "zepo")
  (hash-set! cfg "tags" (list "x" "y" "z"))
  (channel-send! in cfg)
  (define res (channel-recv! out))
  (check "ht roundtrip: derived scalar"      (hash-get res "limit2" 0) 200)
  (check "ht roundtrip: passthrough string"  (hash-get res "name" "")  "zepo")
  (check "ht roundtrip: nested list value"   (hash-get res "tags" (quote ())) (list "x" "y" "z")))

;; 3b. a hashtable nested as a value inside another hashtable.
(let ((in (make-channel 1)) (out (make-channel 1)))
  (spawn-worker
    `(lambda (in out)
       (let ((outer (channel-recv! in)))
         (let ((inner (hash-get outer "inner" (make-hash-table))))
           (channel-send! out (hash-get inner "deep" -1)))))
    in out)
  (define inner (make-hash-table))
  (hash-set! inner "deep" 42)
  (define outer (make-hash-table))
  (hash-set! outer "inner" inner)
  (channel-send! in outer)
  (check "nested hashtable value crosses channel"
         (channel-recv! out) 42))

;; 3c. stream 20 tables through one long-lived worker; non-table sentinel stops it.
(let ((in (make-channel 4)) (out (make-channel 4)))
  (spawn-worker
    `(lambda (in out)
       (let loop ()
         (let ((msg (channel-recv! in)))
           (if (hash-table? msg)
               (begin
                 (channel-send! out (* (hash-get msg "v" 0) (hash-get msg "w" 1)))
                 (loop))))))   ; non-table msg -> one-armed if yields void, worker returns
    in out)
  (let loop ((i 1) (sum 0))
    (if (<= i 20)
        (let ((m (make-hash-table)))
          (hash-set! m "v" i)
          (hash-set! m "w" 2)
          (channel-send! in m)
          (loop (+ i 1) (+ sum (channel-recv! out))))
        (begin
          (channel-send! in 'done)                       ; sentinel: stop worker loop
          (check "20 hashtables streamed, products summed" sum 420)))))

;; ── Summary ─────────────────────────────────────────────────────────────────
(display "ALL ") (display checks) (display " CHECKS PASSED") (newline)
