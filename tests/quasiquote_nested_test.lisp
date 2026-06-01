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

;; zepo-y2br: R7RS nesting-level tracking for literal double-backtick.
(deftest nested-qq/double-backtick-preserves-inner-unquote
  ;; inner unquote is at level 2 → NOT evaluated, kept as data
  (=check `(a `(b ,(+ 1 2)))
          '(a (quasiquote (b (unquote (+ 1 2)))))))

(deftest nested-qq/double-comma-evaluates-outer-only
  ;; ,, : the outer comma drops to level 1 and evaluates (+ 1 2)=3, wrapped in
  ;; an (unquote 3) data form for the inner quasiquote
  (=check `(a `(b ,,(+ 1 2)))
          '(a (quasiquote (b (unquote 3))))))

(deftest nested-qq/level1-unaffected
  (=check `(a ,(+ 1 2) ,@(list 4 5)) '(a 3 4 5)))

(run-tests)
