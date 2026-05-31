;; zepo-uney: smoke test for the :documentation keyword.
;;
;; The reader-side accessor lands in zepo-acu0; here we only confirm
;; that:
;;   (a) the keyword parses without breaking the binding's value
;;   (b) the same syntactic positions work across define / define
;;       (shorthand) / lambda / define-syntax / (module ... :documentation ...)
;;
;; If the keyword leaks through as code (or shifts the body offsets),
;; the (= ...) checks below will fail.

(define foo :documentation "adds one to x" (lambda (x) (+ x 1)))
(if (not (= (foo 10) 11)) (error "foo broke"))

(define (bar x)
  :documentation "doubles x"
  (* 2 x))
(if (not (= (bar 21) 42)) (error "bar broke"))

(define quux :documentation "the answer" 42)
(if (not (= quux 42)) (error "quux broke"))

(define anon
  (lambda (x)
    :documentation "anonymous lambda with a docstring"
    (- x 1)))
(if (not (= (anon 5) 4)) (error "anon broke"))

(define-syntax my-when :documentation "evaluates body when cond is true"
  (syntax-rules ()
    ((_ c b ...) (if c (begin b ...) '()))))

(define result-list '())
(my-when #t
  (set! result-list (cons 'yes result-list)))
(if (not (equal? result-list '(yes)))
    (error "define-syntax with docstring broke"))

(display "documentation OK") (newline)
