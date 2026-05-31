;; zepo-sdxa: with-timeout-ms wraps a thunk and raises if it overruns.
;; The over-deadline test originally used a CPU-bound loop because of
;; the zepo-ewdc bug — that was fixed in zepo-mi9x, so we now use the
;; natural (sleep ...) to burn time. Either pattern is fine; sleep
;; communicates intent better.

(import testing (describe it is with-timeout-ms
                 run! result-passed result-failed))

(describe "with-timeout-ms"
  (it "passes a thunk that finishes well under the deadline"
    (is (= 42 (with-timeout-ms 1000 (lambda () 42)))))

  (it "raises when the thunk overruns the deadline"
    (let ((tripped? #f))
      (with-exception-handler
        (lambda (e) (set! tripped? #t) '())
        (lambda ()
          (with-timeout-ms 10 (lambda () (sleep 0.1) 'too-late))))
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
