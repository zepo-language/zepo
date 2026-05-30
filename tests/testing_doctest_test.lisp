;; zepo-dheb: doctest harvester.

(import testing (load-doctests run! result-passed result-failed clear-tests!))

;; ── Phase 1: a small fixture with three valid doctests ─────────────────
(define good-fixture "/tmp/zepo-dheb-good.lisp")
(file-write-string good-fixture (string-append
  ";; Fixture file with three harvestable doctests.\n"
  ";;\n"
  ";; >>> (+ 1 2)\n"
  ";; => 3\n"
  ";;\n"
  ";; >>> (* 7 6)\n"
  ";; => 42\n"
  ";;\n"
  ";; >>> (cons 1 (cons 2 '()))\n"
  ";; => (1 2)\n"
  ";;\n"
  "(define (greet n) n)\n"))

(define harvested (load-doctests good-fixture))
(if (not (= harvested 3))
    (error "phase 1: expected 3 doctests, got" harvested))

(define r1 (run! :silent #t))
(if (not (= (result-passed r1) 3))
    (error "phase 1: expected 3 passed, got" (result-passed r1)))
(if (not (= (result-failed r1) 0))
    (error "phase 1: expected 0 failed, got" (result-failed r1)))
(display "phase 1 (3 good doctests) OK") (newline)

;; ── Phase 2: a doctest with a wrong expected value ─────────────────────
(clear-tests!)
(define bad-fixture "/tmp/zepo-dheb-bad.lisp")
(file-write-string bad-fixture
  ";; >>> (+ 1 2)\n;; => 99\n")

(load-doctests bad-fixture)
(define r2 (run! :silent #t))
(if (not (= (result-failed r2) 1))
    (error "phase 2: expected 1 failed, got" (result-failed r2)))
(display "phase 2 (deliberate mismatch reports FAIL) OK") (newline)

;; ── Phase 3: file with no doctests yields 0 ───────────────────────────
(clear-tests!)
(define empty-fixture "/tmp/zepo-dheb-empty.lisp")
(file-write-string empty-fixture
  "(define (square x) (* x x))\n;; Just a normal comment.\n")
(if (not (= (load-doctests empty-fixture) 0))
    (error "phase 3: expected 0 doctests in plain file"))
(display "phase 3 (no doctests in plain file) OK") (newline)

(display "doctest harvester OK") (newline)
