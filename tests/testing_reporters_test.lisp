;; zepo-nitj: pluggable reporters.

(import testing
  (describe it xit is
   run! make-reporter reporter-tap reporter-junit reporter-json
   result-passed result-failed result-skipped clear-tests!))

;; Build a known suite once.
(describe "rep"
  (it  "passes"  (is #t))
  (it  "fails"   (is #f))
  (xit "skipped" (is #t)))

;; ── Custom reporter via make-reporter — count events ───────────────────
(define event-log '())
(define (note! ev . rest) (set! event-log (append event-log (list (cons ev rest)))))
(define my-rep
  (make-reporter
    (list
      (cons 'on-start     (lambda (n) (note! 'start n)))
      (cons 'on-test-pass (lambda (path duration) (note! 'pass path)))
      (cons 'on-test-fail (lambda (path msg)      (note! 'fail path msg)))
      (cons 'on-test-skip (lambda (path reason)   (note! 'skip path)))
      (cons 'on-end       (lambda (r) (note! 'end (result-passed r) (result-failed r) (result-skipped r)))))))

(define r (run! :reporter my-rep))

;; Verify each event fired in the right order with the right payload.
(if (not (= (length event-log) 5))
    (error "expected 5 events, got" (length event-log) ":" event-log))
(if (not (eq? (car (car event-log)) 'start))
    (error "first event should be 'start, got" (car (car event-log))))
(if (not (eq? (car (list-ref event-log 1)) 'pass))
    (error "second event should be 'pass, got" (car (list-ref event-log 1))))
(if (not (eq? (car (list-ref event-log 2)) 'fail))
    (error "third event should be 'fail, got" (car (list-ref event-log 2))))
(if (not (eq? (car (list-ref event-log 3)) 'skip))
    (error "fourth event should be 'skip, got" (car (list-ref event-log 3))))
(if (not (eq? (car (list-ref event-log 4)) 'end))
    (error "fifth event should be 'end, got" (car (list-ref event-log 4))))

(display "custom reporter dispatched 5 events in correct order OK") (newline)

;; ── Built-ins are constructible and return non-#f hash-tables ──────────
(if (not (hash-table? (reporter-tap)))    (error "reporter-tap should return a hash-table"))
(if (not (hash-table? (reporter-junit)))  (error "reporter-junit should return a hash-table"))
(if (not (hash-table? (reporter-json)))   (error "reporter-json should return a hash-table"))

(display "built-in reporters constructible OK") (newline)
(display "reporters OK") (newline)
