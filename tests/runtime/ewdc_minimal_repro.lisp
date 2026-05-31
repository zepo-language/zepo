;; zepo-b6hw / zepo-mi9x: locked-in minimal reproducer for the bug class
;; described in docs/adr/0002-fiber-yield-through-prims.md.
;;
;; While the bug exists, running this file errors with "unbound variable: x".
;; When the fix lands (zepo-mi9x), it should print:
;;     x=42
;;
;; The repro is deliberately minimal: a closure that yields the fiber via
;; (sleep ...), invoked through (apply ...), bound to a top-level (define).

(define x (apply (lambda () (sleep 0.01) 42) '()))
(display "x=") (display x) (newline)
