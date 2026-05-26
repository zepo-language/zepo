;; Send a hashtable through a channel to a worker; worker reads a key.
;; Channels are shared FIFOs (not bidirectional rendezvous), so a sender can
;; dequeue its own message. Use a separate in/out channel pair so the parent
;; reliably receives the worker's reply rather than its own request.
(define in-ch (make-channel))
(define out-ch (make-channel))
(define w
  (spawn-worker
    "(lambda (in-ch out-ch)
       (let ((cfg (channel-recv! in-ch)))
         (channel-send! out-ch (hash-get cfg \"limit\" 0))))"
    in-ch out-ch))
(define cfg (make-hash-table))
(hash-set! cfg "limit" 100)
(channel-send! in-ch cfg)
(display (channel-recv! out-ch))   ; expect 100
(newline)
