;; tui-input.lisp — text input widget demo.
;; Type characters to build a string.
;; backspace removes last char, enter confirms, ctrl-c quits.

(import tui/tui)

(define (make-model) (list :text "" :submitted #f))
(define (model-text m) (cadr m))
(define (model-submitted? m) (cadddr m))

(define (update model event)
  (define k (event-key event))
  (define txt (model-text model))
  (cond
    ((equal? k "ctrl-c") :quit)
    ((equal? k "ctrl-d") :quit)
    ((equal? k "enter")
     (list :text txt :submitted #t))
    ((equal? k "backspace")
     (define len (string-length txt))
     (list :text (if (> len 0) (substring txt 0 (- len 1)) txt)
           :submitted #f))
    ((= (string-length k) 1)
     (list :text (string-append txt k) :submitted #f))
    (else model)))

(define (view model)
  (if (model-submitted? model)
      :quit
      (vstack
        ""
        (style-bold "  Enter your name:")
        ""
        (string-append "  > " (model-text model) (style-fg :cyan "█"))
        ""
        (style-dim "  enter to confirm  ctrl-c to cancel")
        "")))

(define result (tui-run (make-model) update view))
(if (model-submitted? result)
    (begin (display (string-append "You entered: " (model-text result))) (newline))
    (begin (display "Cancelled.") (newline)))
