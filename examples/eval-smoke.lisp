;; Compiles a data form into a callable and invokes it.
(define n 5)
(define f (eval (list 'lambda (list 'x) (list '+ 'x n))))   ; (lambda (x) (+ x 5))
(display (f 10))   ; expect 15
(newline)
(display (eval 42)) ; self-evaluating form
(newline)
