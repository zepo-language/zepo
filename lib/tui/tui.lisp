(module tui/tui
  (export
    ;; event accessors
    event-type event-key event-width event-height
    ;; layout
    vstack hstack pad center border
    ;; style
    style-bold style-dim style-fg style-bg style-reset
    ;; ansi sequences
    ansi-clear ansi-move ansi-hide-cursor ansi-show-cursor)

  ;; ── Event accessors ─────────────────────────────────────────────────────────
  ;; Events are lists: (:key "name") or (:resize w h)

  (define (event-type ev) (car ev))
  (define (event-key ev)  (cadr ev))
  (define (event-width ev)  (cadr ev))
  (define (event-height ev) (caddr ev))

  (define (key-event? ev)    (equal? (event-type ev) :key))
  (define (resize-event? ev) (equal? (event-type ev) :resize))

  ;; ── ANSI sequences ───────────────────────────────────────────────────────────

  (define ansi-clear       "\u001b[2J\u001b[H")
  (define ansi-hide-cursor "\u001b[?25l")
  (define ansi-show-cursor "\u001b[?25h")

  (define (ansi-move row col)
    (string-append "\u001b[" (number->string row) ";" (number->string col) "H"))

  ;; ── Style helpers ────────────────────────────────────────────────────────────

  (define (style-reset s) (string-append "\u001b[0m" s "\u001b[0m"))
  (define (style-bold s)  (string-append "\u001b[1m" s "\u001b[0m"))
  (define (style-dim s)   (string-append "\u001b[2m" s "\u001b[0m"))

  (define (ansi-fg-code color)
    (cond
      ((equal? color :black)   "30")
      ((equal? color :red)     "31")
      ((equal? color :green)   "32")
      ((equal? color :yellow)  "33")
      ((equal? color :blue)    "34")
      ((equal? color :magenta) "35")
      ((equal? color :cyan)    "36")
      ((equal? color :white)   "37")
      (else "37")))

  (define (ansi-bg-code color)
    (cond
      ((equal? color :black)   "40")
      ((equal? color :red)     "41")
      ((equal? color :green)   "42")
      ((equal? color :yellow)  "43")
      ((equal? color :blue)    "44")
      ((equal? color :magenta) "45")
      ((equal? color :cyan)    "46")
      ((equal? color :white)   "47")
      (else "47")))

  (define (style-fg color s)
    (string-append "\u001b[" (ansi-fg-code color) "m" s "\u001b[0m"))

  (define (style-bg color s)
    (string-append "\u001b[" (ansi-bg-code color) "m" s "\u001b[0m"))

  ;; ── Layout helpers ───────────────────────────────────────────────────────────

  (define (vstack . lines)
    (define (join-lines ls)
      (cond
        ((null? ls) "")
        ((null? (cdr ls)) (car ls))
        (else (string-append (car ls) "\n" (join-lines (cdr ls))))))
    (join-lines lines))

  (define (pad-left s n)
    (define spaces (make-string n #\space))
    (string-append spaces s))

  (define (pad s left right)
    (define lpad (make-string left #\space))
    (define rpad (make-string right #\space))
    (string-append lpad s rpad))

  (define (center s width)
    (define len (string-length s))
    (if (>= len width)
        s
        (let* ((total (- width len))
               (lpad  (quotient total 2))
               (rpad  (- total lpad)))
          (pad s lpad rpad))))

  (define (hstack . cols)
    (define (join-cols ls)
      (cond
        ((null? ls) "")
        ((null? (cdr ls)) (car ls))
        (else (string-append (car ls) (join-cols (cdr ls))))))
    (join-cols cols))

  (define (repeat-string s n)
    (define (loop acc i)
      (if (= i 0) acc (loop (string-append acc s) (- i 1))))
    (loop "" n))

  (define (border s)
    (define lines (string-split s "\n"))
    (define width (apply max (map string-length lines)))
    (define bar (string-append "+" (repeat-string "-" (+ width 2)) "+"))
    (define (pad-line l)
      (string-append "| " l (repeat-string " " (- width (string-length l))) " |"))
    (apply vstack (append (list bar) (append (map pad-line lines) (list bar)))))

  ;; ── make-string helper ───────────────────────────────────────────────────────
  ;; Build a string of n copies of char c.

  (define (make-string n c)
    (define (loop acc i)
      (if (= i 0) acc (loop (string-append acc (char->string c)) (- i 1))))
    (loop "" n))

  ) ; end module
