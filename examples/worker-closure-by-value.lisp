;; "Pass a closure by value" to a worker: author a form with captured values
;; spliced in via unquote, send it over a channel, worker compiles + runs it
;; with (eval). Two channels (shared-FIFO channels would let the parent read
;; its own send). Quoting rule: a captured LIST is quoted (',labels) so the
;; worker does not try to evaluate it as code.
(define in-ch (make-channel))
(define out-ch (make-channel))
(define multiplier 3)
(define labels (list "a" "b" "c"))

(define w
  (spawn-worker
    `(lambda (in-ch out-ch)
       (let ((task (channel-recv! in-ch)))
         (channel-send! out-ch (eval task))))
    in-ch out-ch))

;; Build a task form: captured value (multiplier) spliced; captured list quoted.
(define task `(cons (* 14 ,multiplier) ',labels))   ; => (cons (* 14 3) '("a" "b" "c"))
(channel-send! in-ch task)
(display (channel-recv! out-ch))   ; expect (42 a b c)
(newline)
