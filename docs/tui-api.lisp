;; Zepo TUI API Design
;; BubbleTea-inspired terminal UI framework
;;
;; Core pattern: Model / Update / View
;;
;;   model  — any zepo value representing your app state
;;   update — (lambda (model event) ...) → new-model or :quit
;;   view   — (lambda (model) ...) → string
;;
;; Entry point:
;;   (tui-run initial-model update view)
;;
;; tui-run drives the event loop:
;;   1. call (view model) → render string to terminal
;;   2. wait for next event
;;   3. call (update model event) → new-model
;;   4. if new-model is :quit → restore terminal and exit
;;   5. loop

;; ── Events ────────────────────────────────────────────────────────────────────
;;
;; Events are lists with a keyword tag as the first element.
;;
;; Key events:
;;   (:key "a")          ; printable character
;;   (:key "enter")
;;   (:key "backspace")
;;   (:key "tab")
;;   (:key "escape")
;;   (:key "up")
;;   (:key "down")
;;   (:key "left")
;;   (:key "right")
;;   (:key "ctrl-c")
;;   (:key "ctrl-d")
;;   (:key "ctrl-a") ... (:key "ctrl-z")
;;   (:key "f1") ... (:key "f12")
;;
;; Resize events:
;;   (:resize width height)   ; terminal was resized
;;
;; Accessors:
;;   (event-type ev)   → :key | :resize
;;   (event-key ev)    → string  (only valid for :key events)
;;   (event-width ev)  → integer (only valid for :resize events)
;;   (event-height ev) → integer (only valid for :resize events)

;; ── Quitting ─────────────────────────────────────────────────────────────────
;;
;; Return :quit from update to exit the event loop cleanly.
;;   (define (update model event)
;;     (cond
;;       ((equal? (event-key event) "q") :quit)
;;       ...))

;; ── Screen helpers ────────────────────────────────────────────────────────────
;;
;;   (tui-screen-size)  → (list width height)
;;   (tui-clear)        → string  ; ANSI clear-screen sequence
;;   (tui-move r c)     → string  ; ANSI cursor-move sequence

;; ── Layout helpers (lib/tui/tui.lisp) ────────────────────────────────────────
;;
;;   (vstack . lines)          ; join strings with newlines
;;   (hstack . cols)           ; join strings side-by-side
;;   (pad s left right)        ; pad string with spaces
;;   (center s width)          ; center string in width
;;   (border s)                ; draw ASCII border around string
;;   (style-bold s)            ; wrap in ANSI bold
;;   (style-fg color s)        ; wrap in ANSI foreground color
;;                             ;   color: :red :green :yellow :blue :magenta :cyan :white

;; ── tui-app macro ─────────────────────────────────────────────────────────────
;;
;; Convenience macro. Instead of writing separate named functions:
;;
;;   (tui-app
;;     (model  initial-value)
;;     (update (model event)
;;       body...)
;;     (view   (model)
;;       body...))
;;
;; Expands to:
;;   (tui-run initial-value
;;     (lambda (model event) body...)
;;     (lambda (model) body...))

;; ── Full counter example ───────────────────────────────────────────────────────

(import tui/tui)

(tui-app
  (model 0)

  (update (model event)
    (cond
      ((equal? (event-key event) "up")    (+ model 1))
      ((equal? (event-key event) "down")  (- model 1))
      ((equal? (event-key event) "q")     :quit)
      ((equal? (event-key event) "ctrl-c") :quit)
      (else model)))

  (view (model)
    (vstack
      (style-bold "Counter")
      ""
      (string-append "  Count: " (number->string model))
      ""
      "  ↑/↓ to change, q to quit")))

;; ── Full text input example ───────────────────────────────────────────────────

(import tui/tui)

(define (make-input-model) (list :text "" :done #f))
(define (model-text m)  (cadr m))
(define (model-done? m) (cadddr m))

(tui-app
  (model (make-input-model))

  (update (model event)
    (cond
      ((equal? (event-key event) "enter")
       (list :text (model-text model) :done #t))
      ((equal? (event-key event) "backspace")
       (let ((t (model-text model)))
         (list :text (if (> (string-length t) 0)
                         (substring t 0 (- (string-length t) 1))
                         t)
               :done #f)))
      ((equal? (event-key event) "ctrl-c") :quit)
      ((equal? (event-type event) :key)
       (let ((k (event-key event)))
         (if (= (string-length k) 1)
             (list :text (string-append (model-text model) k) :done #f)
             model)))
      (else model)))

  (view (model)
    (if (model-done? model)
        :quit
        (vstack
          (style-bold "Type something:")
          ""
          (string-append "  > " (model-text model) "█")
          ""
          "  enter to confirm, ctrl-c to cancel"))))
