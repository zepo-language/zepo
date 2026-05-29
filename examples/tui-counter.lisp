;; tui-counter.lisp — minimal BubbleTea-style counter app.
;; Keys: ↑ increment, ↓ decrement, q / ctrl-c quit.

(import tui/tui (event-key vstack style-bold style-fg style-dim)) ; zepo-y1a4

(define (update model event)
  (define k (event-key event))
  (cond
    ((equal? k "up")     (+ model 1))
    ((equal? k "down")   (- model 1))
    ((equal? k "q")      :quit)
    ((equal? k "ctrl-c") :quit)
    ((equal? k "ctrl-d") :quit)
    (else model)))

(define (view model)
  (vstack
    ""
    (style-bold "  Counter")
    ""
    (string-append "    " (style-fg :cyan (number->string model)))
    ""
    (style-dim "  ↑ / ↓  to change")
    (style-dim "  q       to quit")
    ""))

(tui-run 0 update view)
