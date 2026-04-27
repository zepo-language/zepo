(import test)

(deftest math-works
  (is (> 2 1))
  (=check (+ 1 2) 3))

(deftest throws-error
  (throws (error "boom")))

(define (main)
  (run-tests))

(main)
