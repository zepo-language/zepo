# tui — BubbleTea-style TUI for Zepo

A terminal UI framework following the Model/Update/View pattern.

## Install

```sh
zepo install lib/tui
```

## Core pattern

Every TUI app has three parts:

- **model** — any Zepo value representing your app state
- **update** — `(lambda (model event) ...)` → new model, or `:quit` to exit
- **view** — `(lambda (model) ...)` → string to render

```lisp
(import tui/tui)

(tui-run initial-model update view)
```

`tui-run` drives the loop: render → wait for input → update → repeat.
It returns the final model when the app exits.

---

## Events

Events are lists with a keyword tag as the first element.

### Key events

```lisp
(:key "a")          ; printable character
(:key "enter")
(:key "backspace")
(:key "tab")
(:key "escape")
(:key "up")
(:key "down")
(:key "left")
(:key "right")
(:key "ctrl-c")
(:key "ctrl-a")  ...  (:key "ctrl-z")
(:key "f1")  ...  (:key "f4")
```

### Resize events

```lisp
(:resize 80 24)     ; terminal was resized
```

### Accessors

```lisp
(event-type ev)    ; → :key or :resize
(event-key ev)     ; → string  (key events only)
(event-width ev)   ; → integer (resize events only)
(event-height ev)  ; → integer (resize events only)
```

---

## Quitting

Return `:quit` from `update` (or `view`) to exit the loop cleanly.

```lisp
(define (update model event)
  (cond
    ((equal? (event-key event) "q") :quit)
    ...))
```

---

## Layout

### vstack

Join strings vertically (newline-separated):

```lisp
(vstack "line one" "line two" "line three")
; → "line one\nline two\nline three"
```

### hstack

Join strings horizontally (side by side):

```lisp
(hstack "left  " "right")
; → "left  right"
```

### pad

Add spaces around a string:

```lisp
(pad "text" 4 4)   ; → "    text    "
```

### center

Center a string within a given width:

```lisp
(center "hi" 10)   ; → "    hi    "
```

### border

Draw an ASCII border around a (possibly multi-line) string:

```lisp
(border "hello\nworld")
; → "+-------+\n| hello |\n| world |\n+-------+"
```

### repeat-string

```lisp
(repeat-string "-" 5)   ; → "-----"
```

---

## Style

All style functions wrap a string in ANSI escape codes and reset after.

```lisp
(style-bold "text")             ; bold
(style-dim  "text")             ; dimmed
(style-fg :red "text")          ; foreground color
(style-bg :blue "text")         ; background color
(style-reset "text")            ; explicit reset wrapper
```

Available colors: `:black` `:red` `:green` `:yellow` `:blue` `:magenta` `:cyan` `:white`

---

## ANSI helpers

```lisp
ansi-clear                      ; clear screen + move cursor home
ansi-hide-cursor                ; hide terminal cursor
ansi-show-cursor                ; show terminal cursor
(ansi-move row col)             ; move cursor to row, col (1-indexed)
```

---

## Terminal size

```lisp
(tui-screen-size)   ; → (:resize width height)
```

Use with `event-width` / `event-height` to get dimensions:

```lisp
(define sz (tui-screen-size))
(event-width sz)    ; → 80
(event-height sz)   ; → 24
```

---

## Examples

### Counter (`examples/tui-counter.lisp`)

Increment/decrement a number with arrow keys. Demonstrates the minimal
Model/Update/View pattern.

### Text input (`examples/tui-input.lisp`)

Editable text field — printable chars append, backspace removes, enter
confirms. Shows how to use the final model return value from `tui-run`.

---

## Full example

```lisp
(import tui/tui)

(define (update model event)
  (cond
    ((equal? (event-key event) "up")    (+ model 1))
    ((equal? (event-key event) "down")  (- model 1))
    ((equal? (event-key event) "q")     :quit)
    ((equal? (event-key event) "ctrl-c") :quit)
    (else model)))

(define (view model)
  (vstack
    ""
    (style-bold "  Counter")
    ""
    (string-append "    " (style-fg :cyan (number->string model)))
    ""
    (style-dim "  ↑ / ↓  to change  ·  q to quit")
    ""))

(tui-run 0 update view)
```
