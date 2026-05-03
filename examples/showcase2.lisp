; showcase2.lisp — macros, exceptions, higher-order ops, plists, strings
; zepo-8p3

(import format)

; ── Macros ────────────────────────────────────────────────────────────────────

(defmacro while (test . body)
  `(let loop ()
     (when ,test
       ,@body
       (loop))))

(defmacro assert-equal (a b)
  `(unless (equal? ,a ,b)
     (error "assert-equal failed" ',a ',b)))

(defmacro swap! (a b)
  `(let ((tmp ,a))
     (set! ,a ,b)
     (set! ,b tmp)))

(define x 1)
(define y 2)
(swap! x y)
(display (format "after swap!: x=~a y=~a~%" x y))
; → after swap!: x=2 y=1

(define counter 0)
(while (< counter 5)
  (set! counter (+ counter 1)))
(display (format "while: counter=~a~%" counter))
; → while: counter=5

; ── Higher-order list ops ─────────────────────────────────────────────────────

(define words '("banana" "apple" "cherry" "avocado" "blueberry" "apricot"))

(define a-words
  (sort (filter (lambda (w) (string-contains w "a")) words) string<?))

(display (format "words containing 'a': ~a~%" a-words))
; → words containing 'a': (apple apricot avocado banana)

; frequency map: first letter → count (using assoc-based alist)
(define (inc-count counts key)
  (let ((entry (assoc key counts)))
    (if entry
        (map (lambda (p) (if (equal? (car p) key)
                             (cons key (+ (cdr p) 1))
                             p))
             counts)
        (cons (cons key 1) counts))))

(define first-letter-freq
  (fold-left (lambda (acc w) (inc-count acc (substring w 0 1)))
             (quote ())
             words))

(display (format "first-letter freq: ~a~%"
                 (sort first-letter-freq
                       (lambda (a b) (string<? (car a) (car b))))))
; → first-letter freq: ((a . 3) (b . 2) (c . 1))

; ── Named let ────────────────────────────────────────────────────────────────

(define (fibs-up-to limit)
  (let loop ((a 0) (b 1) (acc (quote ())))
    (if (> a limit)
        (reverse acc)
        (loop b (+ a b) (cons a acc)))))

(display (format "fibs up to 100: ~a~%" (fibs-up-to 100)))
; → fibs up to 100: (0 1 1 2 3 5 8 13 21 34 55 89)

; collatz sequence: named let with accumulator
(define (collatz n)
  (let loop ((x n) (steps 0))
    (cond
      ((= x 1) steps)
      ((even? x) (loop (/ x 2) (+ steps 1)))
      (else (loop (+ (* 3 x) 1) (+ steps 1))))))

(display (format "collatz(27) steps: ~a~%" (collatz 27)))
; → collatz(27) steps: 111

; ── Plists as lightweight records ────────────────────────────────────────────

(define (make-person name age score)
  (list 'name name 'age age 'score score))

(define people
  (list (make-person "Alice" 30 92)
        (make-person "Bob"   25 87)
        (make-person "Carol" 35 95)
        (make-person "Dan"   28 78)))

(define seniors
  (filter (lambda (p) (>= (plist-get p 'age) 30)) people))

(display (format "30+: ~a~%"
                 (map (lambda (p) (plist-get p 'name)) seniors)))
; → 30+: (Alice Carol)

(define by-score
  (sort people (lambda (a b) (> (plist-get a 'score) (plist-get b 'score)))))

(display "ranked by score:\n")
(for-each
  (lambda (p)
    (display (format "  ~a (~a)~%"
                     (plist-get p 'name)
                     (plist-get p 'score))))
  by-score)

; ── String ops ───────────────────────────────────────────────────────────────

(define csv "north,south,east,west")
(define directions (string-split csv ","))
(display (format "directions: ~a~%" directions))
; → directions: (north south east west)

(display (format "reversed: ~a~%"
                 (string-join (reverse directions) " | ")))
; → reversed: west | east | south | north

; ── Exceptions: guard with structured errors ──────────────────────────────────

(define (safe-divide a b)
  (guard (exn
    ((error-object? exn)
     (format "ERR: ~a (~a)" (error-object-message exn) (error-object-irritants exn))))
    (if (= b 0)
        (error "division by zero" a b)
        (/ a b))))

(display (format "10 / 2 = ~a~%" (safe-divide 10 2)))
; → 10 / 2 = 5
(display (format "10 / 0 = ~a~%" (safe-divide 10 0)))
; → 10 / 0 = ERR: division by zero (10 0)

; ── Smoke assertions ─────────────────────────────────────────────────────────

(assert-equal (fibs-up-to 10) '(0 1 1 2 3 5 8))
(assert-equal (collatz 1) 0)
(assert-equal (string-join '("a" "b" "c") "-") "a-b-c")
(assert-equal (safe-divide 6 3) 2)

(display "all assertions passed\n")
