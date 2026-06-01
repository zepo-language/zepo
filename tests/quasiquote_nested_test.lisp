;; zepo-vmol: nested quasiquote — a quasiquote inside an unquote / splicing
;; operand is now desugared (previously left a literal (quasiquote ...) → eval
;; error "unbound variable: quasiquote"). Macros are defined at top level (a
;; macro must exist before the form that uses it is compiled).
(import test (deftest is =check run-tests))

;; the original bead repro: generate N defines from a list via splicing
(defmacro %qq-genfn (name)
  `(begin ,@(map (lambda (n) `(define ,n 1)) (list name))))
(%qq-genfn %qq-foo)

(defmacro %qq-defconsts (names)
  `(begin ,@(map (lambda (n) `(define ,n (quote ,n))) names)))
(%qq-defconsts (%qq-a %qq-b %qq-c))

;; quasiquote inside a (non-splicing) unquote operand
(defmacro %qq-pair (k)
  `(list ,(let ((kk k)) `(quote ,kk)) 'done))

;; expansion-time computation using quasiquote, result used as data
(defmacro %qq-table (pairs)
  `(list ,@(map (lambda (p) `(cons (quote ,(car p)) ,(car (cdr p)))) pairs)))

(deftest nested-qq/splice-generates-forms (=check %qq-foo 1))
(deftest nested-qq/splice-multiple
  (=check (list %qq-a %qq-b %qq-c) '(%qq-a %qq-b %qq-c)))
(deftest nested-qq/inside-plain-unquote
  (=check (%qq-pair hello) '(hello done)))
(deftest nested-qq/builds-data-list
  (=check (%qq-table ((a 1) (b 2))) '((a . 1) (b . 2))))

(run-tests)
