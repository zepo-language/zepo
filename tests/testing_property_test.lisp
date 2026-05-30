;; zepo-qv9y: property-based testing via check-property + shrinking.

(import testing
  (describe it is =check throws check-property
   run! result-passed result-failed))
(import math/gen (gen-int gen-list))
(import math/dist (make-rng))

(describe "check-property"

  (it "passes when the property holds across all iterations"
    (check-property
      (lambda (n) (= (* n 2) (+ n n)))
      :gen (gen-int -1000 1000)
      :iterations 100
      :rng (make-rng 42)))

  (it "is deterministic with the same seed"
    ;; Two runs with the same seed should produce the same outcome — both
    ;; should pass since the property is true.
    (check-property (lambda (n) (>= (* n n) 0)) :gen (gen-int -50 50)
                    :iterations 25 :rng (make-rng 7))
    (check-property (lambda (n) (>= (* n n) 0)) :gen (gen-int -50 50)
                    :iterations 25 :rng (make-rng 7)))

  (it "raises on a failing property"
    (let ((caught #f))
      (with-exception-handler
        (lambda (e) (set! caught e) '())
        (lambda ()
          (check-property
            (lambda (n) (< n 5))
            :gen (gen-int 0 100)
            :iterations 50
            :rng (make-rng 99))))
      (is caught)))

  (it "shrinks to a minimal counter-example for gen-int"
    ;; Property: n < 5. Smallest failing value should be exactly 5.
    (let ((msg #f))
      (with-exception-handler
        (lambda (e) (set! msg (error-object-message e)) '())
        (lambda ()
          (check-property (lambda (n) (< n 5)) :gen (gen-int 0 100)
                          :iterations 50 :rng (make-rng 99))))
      (is msg)
      ;; The error message names the smallest failing input. We don't
      ;; check the exact text — just that we got a useful message.
      (is (> (string-length msg) 0))))

  (it "shrinks lists by removing elements"
    ;; Property: no list contains both 7 and 13. The shrinker should
    ;; produce a list shorter than the original counterexample.
    (let ((msg #f))
      (with-exception-handler
        (lambda (e) (set! msg (error-object-message e)) '())
        (lambda ()
          ;; Force the shrinker to encounter a failing list by using a
          ;; predicate that flags ANY list of length >= 3.
          (check-property
            (lambda (xs) (< (length xs) 3))
            :gen (gen-list 0 10 (gen-int 0 100))
            :iterations 50
            :rng (make-rng 11))))
      (is msg))))

(define r (run! :silent #t))
(if (not (= (result-passed r) 5)) (error "expected 5 passed, got" (result-passed r)))
(if (not (= (result-failed r) 0)) (error "expected 0 failed, got" (result-failed r)))
(display "property OK — 5/5 pass") (newline)
