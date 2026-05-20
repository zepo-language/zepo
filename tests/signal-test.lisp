;;; Signal primitive tests — zepo-6qx

;; Test signal-number returns correct integers
(define n-sigterm (signal-number 'SIGTERM))
(define n-sigint  (signal-number 'SIGINT))
(define n-sighup  (signal-number 'SIGHUP))
(define n-unknown (signal-number 'SIGFOO))

(if (= n-sigterm 15)
    (println "PASS: signal-number SIGTERM = 15")
    (println "FAIL: signal-number SIGTERM"))

(if (= n-sigint 2)
    (println "PASS: signal-number SIGINT = 2")
    (println "FAIL: signal-number SIGINT"))

(if (= n-sighup 1)
    (println "PASS: signal-number SIGHUP = 1")
    (println "FAIL: signal-number SIGHUP"))

(if (equal? n-unknown #f)
    (println "PASS: signal-number unknown = #f")
    (println "FAIL: signal-number unknown"))

;; Test signal-set! registers handler; send SIGUSR1 to ourselves and
;; verify the handler fires within a tight loop.
(define handler-fired #f)

(signal-set! 'SIGUSR1 (lambda ()
  (set! handler-fired #t)))

;; Send SIGUSR1 (signal 10) to our own process via shell using getpid.
;; Use numeric form for portability across shells.
(define my-pid (getpid))
(shell (string-append "kill -10 " (number->string my-pid)))

;; Spin for up to 2 seconds waiting for handler to fire (polls happen
;; every 1000 opcodes, so a tight loop will trigger many polls quickly).
(define deadline (+ (current-time-ms) 2000))
(let loop ()
  (if (or handler-fired (>= (current-time-ms) deadline))
      #t
      (loop)))

(if handler-fired
    (println "PASS: SIGUSR1 handler fired")
    (println "FAIL: SIGUSR1 handler did not fire within 2s"))
