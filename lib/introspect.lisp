;; zepo-acu0: minimal introspection helpers built on top of the
;; (documentation X) primitive (registered in src/prims/register.zig).
;; (describe X) prints a formatted block for use at the REPL.

(module introspect
  :documentation "Lightweight runtime introspection helpers."
  (export describe)

  (define (describe sym)
    :documentation "Print a human-readable description of SYM to stdout."
    (display sym) (newline)
    (let ((doc (documentation sym)))
      (if doc
          (begin (display "  ") (display doc) (newline))
          (begin (display "  (no documentation)") (newline))))))
