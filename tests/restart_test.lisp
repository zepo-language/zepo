;; zepo-g120: restarts + non-unwinding handlers (handler-bind).
(import test (deftest is =check throws run-tests))

; ── restart-case alone ─────────────────────────────────────────────────────────

(deftest restart-case/no-invoke-returns-body
  (=check (restart-case (+ 1 2) (r (v) v)) 3))

; ── handler-bind invokes a restart → restart-case returns the clause value ─────

(deftest restart/handler-bind-invokes
  (=check
    (handler-bind (lambda (e) (invoke-restart 'use-default 42))
      (restart-case (error "boom") (use-default (v) :report "use the default" v)))
    42))

(deftest restart/handler-bind-inside-body
  (=check
    (restart-case
      (handler-bind (lambda (e) (invoke-restart 'b 99)) (error "x"))
      (a (v) (list 'a v))
      (b (v) (list 'b v)))
    '(b 99)))

(deftest restart/clause-runs-not-handler-after-invoke
  ;; after invoke-restart, control goes to restart-case, NOT back to the handler
  (=check
    (handler-bind (lambda (e) (invoke-restart 'r 1) 'handler-kept-going)
      (restart-case (error "x") (r (v) v)))
    1))

; ── nested restart-cases ───────────────────────────────────────────────────────

(deftest restart/nested-inner
  (=check
    (restart-case
      (restart-case
        (handler-bind (lambda (e) (invoke-restart 'inner 1)) (error "x"))
        (inner (v) (list 'inner v)))
      (outer (v) (list 'outer v)))
    '(inner 1)))

(deftest restart/nested-outer-from-inner-body
  (=check
    (restart-case
      (restart-case
        (handler-bind (lambda (e) (invoke-restart 'outer 2)) (error "x"))
        (inner (v) (list 'inner v)))
      (outer (v) (list 'outer v)))
    '(outer 2)))

; ── multi-arg restart clause ───────────────────────────────────────────────────

(deftest restart/multi-arg-clause
  (=check
    (handler-bind (lambda (e) (invoke-restart 'r 3 4))
      (restart-case (error "x") (r (a b) (+ a b))))
    7))

; ── introspection ──────────────────────────────────────────────────────────────

(deftest restart/compute-restarts-most-recent-first
  ;; declining handler returns the restart names it saw; guard surfaces them.
  (=check
    (guard (names (#t names))
      (restart-case
        (handler-bind (lambda (e) (raise (compute-restarts))) (error "x"))
        (a (v) v)
        (b (v) v)))
    '(b a)))

(deftest restart/find-restart
  (=check
    (restart-case
      (handler-bind (lambda (e) (invoke-restart 'r (if (find-restart 'r) 'yes 'no)))
        (error "x"))
      (r (v) v))
    'yes))

(deftest restart/find-restart-absent
  (=check
    (restart-case
      (handler-bind (lambda (e) (invoke-restart 'r (find-restart 'nope))) (error "x"))
      (r (v) v))
    #f))

(deftest restart/restart-report
  (=check
    (restart-case
      (handler-bind (lambda (e) (invoke-restart 'r (restart-report 'r))) (error "x"))
      (r (v) :report "the R restart" v))
    "the R restart"))

; ── handler-bind decline → condition propagates ────────────────────────────────

(deftest handler-bind/decline-propagates
  (=check
    (guard (e (#t 'caught-outer))
      (handler-bind (lambda (e) 'declined)
        (error "x")))
    'caught-outer))

(deftest handler-bind/decline-then-restart-not-invoked
  ;; declining handler returns normally; restart-case clauses NOT run unless invoked
  (=check
    (guard (e (#t 'propagated))
      (restart-case
        (handler-bind (lambda (e) 'declined) (error "x"))
        (r (v) v)))
    'propagated))

; ── fiber-locality ──────────────────────────────────────────────────────────────

(deftest restart/fiber-does-not-see-main-restart
  (=check
    (let ((ch (make-channel)))
      (restart-case
        (begin
          (spawn (lambda () (channel-send! ch (if (find-restart 'r) 'yes 'no))))
          (channel-recv! ch))
        (r (v) v)))
    'no))

(deftest restart/survives-yield
  (=check
    (restart-case
      (handler-bind (lambda (e) (invoke-restart 'r 7))
        (begin (yield) (error "after yield")))
      (r (v) v))
    7))

(run-tests)
