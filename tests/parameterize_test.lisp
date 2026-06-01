;; zepo-6o3p: dynamic variables — make-parameter / parameterize.
(import test (deftest is =check throws run-tests))

; ── make-parameter: basic read ────────────────────────────────────────────────

(deftest make-parameter/reads-default
  (=check ((make-parameter 10)) 10))

(deftest make-parameter/is-procedure
  (is (procedure? (make-parameter 0))))

(deftest make-parameter/applies-converter-to-default
  ;; converter runs on the initial value
  (=check ((make-parameter 5 (lambda (x) (* x 2)))) 10))

; ── mutation form (p v) ───────────────────────────────────────────────────────

(deftest parameter/mutate-default
  (=check
    (let ((p (make-parameter 1)))
      (p 99)
      (p))
    99))

(deftest parameter/mutate-applies-converter
  (=check
    (let ((p (make-parameter 0 (lambda (x) (+ x 1)))))
      (p 10)
      (p))
    11))

; ── parameterize: binds for dynamic extent, restores after ────────────────────

(deftest parameterize/binds-inside
  (=check (let ((p (make-parameter 10))) (parameterize ((p 20)) (p))) 20))

(deftest parameterize/restores-after
  (=check
    (let ((p (make-parameter 10)))
      (parameterize ((p 20)) (p))
      (p))
    10))

(deftest parameterize/applies-converter
  (=check
    (let ((p (make-parameter 5 (lambda (x) (* x 2)))))
      (parameterize ((p 3)) (p)))
    6))

(deftest parameterize/multiple-bindings
  (=check
    (let ((a (make-parameter 1)) (b (make-parameter 2)))
      (parameterize ((a 10) (b 20)) (+ (a) (b))))
    30))

(deftest parameterize/nested
  (=check
    (let ((p (make-parameter 1)))
      (parameterize ((p 100)) (parameterize ((p 200)) (p))))
    200))

(deftest parameterize/nested-restores-outer
  (=check
    (let ((p (make-parameter 1)))
      (parameterize ((p 100))
        (parameterize ((p 200)) (p))
        (p)))
    100))

(deftest parameterize/multiple-body-forms
  (=check
    (let ((p (make-parameter 0)))
      (parameterize ((p 7))
        (define x (p))
        (+ x 1)))
    8))

(deftest parameterize/value-expr-sees-outer-binding
  ;; R7RS: value expressions are evaluated BEFORE the new bindings install,
  ;; so the inner init reads the outer (default) value, not 100.
  (=check
    (let ((p (make-parameter 1)))
      (parameterize ((p 100))
        (parameterize ((p (+ (p) 5))) (p))))
    105))

; ── non-local exit unwinds the binding ────────────────────────────────────────

(deftest parameterize/guard-escape-unwinds
  ;; raising out of the body must pop the dynamic binding — the handler
  ;; (running after the unwind) sees the default, not 999.
  (=check
    (let ((p (make-parameter 1)))
      (guard (e (#t (p)))
        (parameterize ((p 999)) (raise 'boom))))
    1))

; ── fiber-locality ────────────────────────────────────────────────────────────

(deftest parameterize/fiber-does-not-see-main-binding
  (=check
    (let ((p (make-parameter 'default))
          (ch (make-channel)))
      (parameterize ((p 'main-bound))
        (spawn (lambda () (channel-send! ch (p))))
        (channel-recv! ch)))
    'default))

(deftest parameterize/fiber-binding-does-not-leak-to-main
  (=check
    (let ((p (make-parameter 'default)))
      (fiber-join (spawn (lambda () (parameterize ((p 'fiber-bound)) (p)))))
      (p))
    'default))

(run-tests)
