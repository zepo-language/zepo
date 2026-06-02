;; zepo-pl5e: generic extension-point hooks (lib/hooks).
(import test (deftest is =check run-tests))
(import hooks (add-hook remove-hook run-hooks run-hooks/results clear-hooks))

(deftest hooks/runs-in-registration-order
  (clear-hooks 'k1)
  (let ((log '()))
    (add-hook 'k1 (lambda () (set! log (cons 'a log))))
    (add-hook 'k1 (lambda () (set! log (cons 'b log))))
    (run-hooks 'k1)
    (=check (reverse log) '(a b))))   ; a registered first → runs first

(deftest hooks/passes-args
  (clear-hooks 'k2)
  (let ((seen '()))
    (add-hook 'k2 (lambda (x y) (set! seen (cons (list x y) seen))))
    (run-hooks 'k2 1 2)
    (=check seen '((1 2)))))

(deftest hooks/results-in-order
  (clear-hooks 'k3)
  (add-hook 'k3 (lambda (x) (* x 2)))
  (add-hook 'k3 (lambda (x) (+ x 1)))
  (=check (run-hooks/results 'k3 10) '(20 11)))

(deftest hooks/remove
  (clear-hooks 'k4)
  (let ((log '()) (f (lambda () (set! log (cons 'f log)))))
    (add-hook 'k4 f)
    (add-hook 'k4 (lambda () (set! log (cons 'g log))))
    (remove-hook 'k4 f)
    (run-hooks 'k4)
    (=check log '(g))))

(deftest hooks/empty-is-noop
  (clear-hooks 'k5)
  (run-hooks 'k5 'whatever)            ; no handlers → no error
  (=check (run-hooks/results 'k5) '()))

(deftest hooks/clear
  (add-hook 'k6 (lambda () 1))
  (clear-hooks 'k6)
  (=check (run-hooks/results 'k6) '()))

(run-tests)
