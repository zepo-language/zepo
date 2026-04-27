;; macros.lisp — demonstrates defmacro and quasiquote.

;;; ── Basic quasiquote ────────────────────────────────────────────────────────

(define name "world")
(display `(hello ,name))       ; (hello world)
(newline)

(define nums (list 1 2 3))
(display `(start ,@nums end))  ; (start 1 2 3 end)
(newline)

;;; ── defmacro ────────────────────────────────────────────────────────────────

(defmacro my-when (test . body)
  `(if ,test (begin ,@body)))

(defmacro my-unless (test . body)
  `(if ,test #f (begin ,@body)))

(defmacro swap! (a b)
  `(let ((tmp ,a))
     (set! ,a ,b)
     (set! ,b tmp)))

(defmacro dotimes (binding . body)
  (let ((var (car binding))
        (n   (cadr binding)))
    `(let loop ((,var 0))
       (my-when (< ,var ,n)
         ,@body
         (loop (+ ,var 1))))))

;;; ── Exercising the macros ───────────────────────────────────────────────────

; my-when / my-unless
(my-when #t
  (display "my-when: condition true")
  (newline))

(my-unless #f
  (display "my-unless: condition false")
  (newline))

; swap!
(define a 1)
(define b 2)
(swap! a b)
(display (string-append "after swap: a=" (number->string a)
                        " b=" (number->string b)))
(newline)

; dotimes — print 0..4
(display "dotimes: ")
(dotimes (i 5)
  (display i)
  (display " "))
(newline)
