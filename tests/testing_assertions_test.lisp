;; zepo-ss3f: rich assertion suite. Self-hosting — uses the framework to
;; test its own assertions.
(import testing
  (describe it is is-not =check =check~
   throws throws-of does-not-throw
   set-equal? matches
   run! result-passed result-failed))

;; ── Pass paths ─────────────────────────────────────────────────────────
(describe "asserts: pass paths"
  (it "is on truthy"          (is 1))
  (it "is on #t"              (is #t))
  (it "is-not on #f"          (is-not #f))
  (it "=check on equal ints"  (=check (+ 1 2) 3))
  (it "=check on equal lists" (=check (list 1 2 3) '(1 2 3)))
  (it "=check~ approximate"   (=check~ (+ 0.1 0.2) 0.3 1e-9))
  (it "throws catches error"  (throws (error "boom")))
  (it "throws-of with pred"   (throws-of (error "boom") error-object?))
  (it "does-not-throw ok"     (does-not-throw (+ 1 2)))
  (it "set-equal? identical"  (is (set-equal? '(1 2 3) '(3 2 1))))
  (it "set-equal? subset OK"  (is (set-equal? '(1 1 2 3) '(3 2 1))))
  (it "matches literal"       (is (matches 5 5)))
  (it "matches wildcard"      (is (matches 5 '_)))
  (it "matches list pattern"  (is (matches '(1 2 3) '(1 _ 3)))))

;; ── Fail paths: each is wrapped in (throws ...) so we test that the
;;    assertion macro DOES raise on failure ───────────────────────────────
(describe "asserts: fail paths surface errors"
  (it "is fails on #f"             (throws (is #f)))
  (it "is-not fails on truthy"     (throws (is-not 1)))
  (it "=check on different ints"   (throws (=check 1 2)))
  (it "=check~ too far apart"      (throws (=check~ 1.0 2.0 0.01)))
  (it "throws fails if no error"   (throws (throws (+ 1 2))))
  (it "does-not-throw fails if err" (throws (does-not-throw (error "x")))))

;; ── Run and verify counts ──────────────────────────────────────────────
(define r (run! :silent #t))
(define p (result-passed r))
(define f (result-failed r))

(if (not (= p 20))
    (error "expected 20 passed, got" p))
(if (not (= f 0))
    (error "expected 0 failed, got" f))

(display "assertion smoke OK — ") (display p) (display "/20 pass") (newline)
