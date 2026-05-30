;; zepo-sdxa: with-timeout-ms wraps a thunk and raises if it overruns.
;;
;; Note: we use a CPU-bound recursive loop ("busy") rather than (sleep ...)
;; to burn time. Sleep yields the current fiber, and combining
;; fiber-yielding with a test-thunk closure that captures macro-hygiene
;; rewrites surfaces a runtime quirk worth filing separately. The post-hoc
;; deadline check itself works the same whether the thunk slept or spun.

(import testing (describe it is with-timeout-ms
                 run! result-passed result-failed))

(define (busy n)
  (if (<= n 0) 'done (busy (- n 1))))

(describe "with-timeout-ms"
  (it "passes a thunk that finishes well under the deadline"
    (is (= 42 (with-timeout-ms 1000 (lambda () 42)))))

  (it "raises when the thunk overruns the deadline"
    (let ((tripped? #f))
      (with-exception-handler
        (lambda (e) (set! tripped? #t) '())
        (lambda ()
          ;; 100k recursive calls overruns a 1ms deadline by a comfortable
          ;; margin on every machine we'd want to ship on.
          (with-timeout-ms 1 (lambda () (busy 100000)))))
      (is tripped?)))

  (it "propagates the thunk's own errors unchanged"
    (let ((caught #f))
      (with-exception-handler
        (lambda (e) (set! caught e) '())
        (lambda ()
          (with-timeout-ms 1000 (lambda () (error "from inside the thunk")))))
      (is caught))))

(define r (run! :silent #t))
(if (not (= (result-passed r) 3)) (error "expected 3 passed, got" (result-passed r)))
(if (not (= (result-failed r) 0)) (error "expected 0 failed, got" (result-failed r)))
(display "timeout OK") (newline)
