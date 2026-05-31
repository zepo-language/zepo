;; zepo-acu0: (documentation X) primitive + (describe X) helper.
;;
;; Verifies the reader side of the :documentation pipeline lands the
;; same string the writer side stored on the binding's EntryMeta.

(import introspect (describe))

(define foo :documentation "adds one to x" (lambda (x) (+ x 1)))
(define (bar x) :documentation "doubles x" (* 2 x))
(define quux :documentation "the answer" 42)
(define undocumented 99)

;; ── (documentation X) round-trip ────────────────────────────────────
(if (not (equal? (documentation 'foo) "adds one to x"))
    (error "foo docstring round-trip failed:" (documentation 'foo)))

(if (not (equal? (documentation 'bar) "doubles x"))
    (error "bar docstring round-trip failed:" (documentation 'bar)))

(if (not (equal? (documentation 'quux) "the answer"))
    (error "quux docstring round-trip failed:" (documentation 'quux)))

;; ── Undocumented binding returns #f ─────────────────────────────────
(if (not (equal? (documentation 'undocumented) #f))
    (error "undocumented should return #f, got:" (documentation 'undocumented)))

;; ── Unbound symbol returns #f (no error) ────────────────────────────
(if (not (equal? (documentation 'never-defined) #f))
    (error "unbound symbol should return #f"))

;; ── define-syntax docstring round-trips ─────────────────────────────
(define-syntax my-when :documentation "evaluates body when cond is true"
  (syntax-rules ()
    ((_ c b ...) (if c (begin b ...) '()))))
(if (not (equal? (documentation 'my-when) "evaluates body when cond is true"))
    (error "macro docstring round-trip failed:" (documentation 'my-when)))

;; ── describe smoke ──────────────────────────────────────────────────
;; Just confirm it doesn't error; the formatted output isn't validated
;; structurally here, only that the helper runs end-to-end.
(describe 'foo)
(describe 'undocumented)

(display "documentation accessor OK") (newline)
