;; spawn-worker with a FORM entry (built with quasiquote, value spliced in).
;; Two channels: a single shared FIFO would let the parent read its own send.
(define in-ch (make-channel))
(define out-ch (make-channel))
(define base 1000)
(define w
  (spawn-worker
    `(lambda (in-ch out-ch)
       (channel-send! out-ch (+ ,base (channel-recv! in-ch))))
    in-ch out-ch))
(channel-send! in-ch 7)
(display (channel-recv! out-ch))   ; expect 1007
(newline)
