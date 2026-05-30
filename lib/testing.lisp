; lib/testing.lisp — Zepo's testing framework, take two.
;
; Lives alongside lib/test.lisp (which stays exactly as it is). New code
; should reach for this module. Migration of existing tests/ files happens
; gradually in [[zepo-g77k]].
;
; The shape is BDD-inspired but unit-test compatible — every `it` block IS
; a unit test, `describe` just gives you nesting. `deftest` is a shortcut
; that registers a flat top-level test with no enclosing describe.
;
; This is the scaffold bead ([[zepo-mx0p]]): registration, dynamic context
; stacks, and a basic tree-printing runner. Assertions live in zepo-ss3f.
; Lifecycle hooks in zepo-mqf4. Focus/skip in zepo-s3zf. Reporters in
; zepo-nitj. Filtering in zepo-nqfu. Embeddable run! in zepo-fqws.

(module testing
  (export
    ;; Block forms
    describe it deftest
    ;; Placeholder assertion — full assertion suite lands in zepo-ss3f
    is
    ;; Runner
    run-tests clear-tests!)

  ;; ── State ─────────────────────────────────────────────────────────────────

  ;; Stack of describe-block labels currently in scope. The full path of a
  ;; test is (reverse *context-stack*) appended with the test's own name.
  (define *context-stack* '())

  ;; Every (it ...) and (deftest ...) appends to this list at registration
  ;; time. Each entry is (path . thunk) where path is a list of strings.
  (define *tests* '())

  (define (clear-tests!)
    (set! *tests* '())
    (set! *context-stack* '()))

  ;; Push/pop helpers — called by the describe macro's expansion.
  (define (push-context! label)
    (set! *context-stack* (cons label *context-stack*)))

  (define (pop-context!)
    (set! *context-stack* (cdr *context-stack*)))

  ;; Register a test against the current context. Used by the it/deftest
  ;; macros after they've collected the name and built the thunk.
  (define (register-test! name thunk)
    (let ((path (append (reverse *context-stack*) (list name))))
      (set! *tests* (append *tests* (list (cons path thunk))))))

  ;; ── Block forms ──────────────────────────────────────────────────────────

  ;; (describe NAME body...) — pushes NAME onto the context stack, evaluates
  ;; body forms (which typically contain nested describes and its), pops the
  ;; context. Uses a manual push/pop rather than dynamic-wind because we
  ;; want this to compose at load-time, not runtime.
  (defmacro describe (name . body)
    `(begin
       (push-context! ,name)
       ,@body
       (pop-context!)))

  ;; (it NAME body...) — registers a test at the current context with body
  ;; wrapped in a thunk. The thunk is evaluated later by run-tests.
  (defmacro it (name . body)
    `(register-test! ,name (lambda () ,@body)))

  ;; (deftest NAME body...) — shorthand for an it block at the top level
  ;; or wherever it appears. Same semantics as (it ...); the separate name
  ;; exists to match the test.lisp ergonomic for one-off tests where
  ;; describe nesting would be overkill.
  (defmacro deftest (name . body)
    `(register-test! ,name (lambda () ,@body)))

  ;; ── Placeholder assertion ────────────────────────────────────────────────
  ;;
  ;; Real assertion suite (=check, =check~, throws, throws-of, doesn't-throw,
  ;; set-equal?, matches, with structured diff output) lives in [[zepo-ss3f]].
  ;; For now `is` errors on falsy.

  (defmacro is (expr)
    `(if (not ,expr)
         (error "assertion failed" ',expr)
         #t))

  ;; ── Runner ───────────────────────────────────────────────────────────────
  ;;
  ;; Walks *tests* once, executes each thunk, and prints a tree grouping by
  ;; describe path. No exit on failure — that's [[zepo-fqws]]'s embeddable
  ;; run!. This run-tests is the convenience version that just prints.

  (define (format-exception e)
    (if (error-object? e)
        (let ((msg (error-object-message e))
              (irritants (error-object-irritants e)))
          (if (null? irritants)
              msg
              (string-append msg " " (display-to-string irritants))))
        (display-to-string e)))

  ;; Print indented label. depth=0 is no indent.
  (define (print-indent depth)
    (let loop ((i 0))
      (if (< i depth)
          (begin (display "  ") (loop (+ i 1))))))

  ;; Compute the common prefix length of two paths (lists of strings).
  (define (prefix-len a b)
    (let loop ((a a) (b b) (n 0))
      (cond ((or (null? a) (null? b)) n)
            ((equal? (car a) (car b)) (loop (cdr a) (cdr b) (+ n 1)))
            (#t n))))

  ;; Print describe-headers for the transition from prev-path to cur-path.
  ;; The leaf name (last element of cur-path) is NOT printed here — that's
  ;; the test name, printed by the run loop with PASS/FAIL.
  (define (print-context-transition prev-path cur-path)
    (let* ((cur-groups (let ((all cur-path))
                         (if (null? all) '()
                             (let loop ((xs all) (acc '()))
                               (if (null? (cdr xs)) (reverse acc)
                                   (loop (cdr xs) (cons (car xs) acc)))))))
           (overlap (prefix-len prev-path cur-groups))
           (groups-to-print (let loop ((xs cur-groups) (i 0) (acc '()))
                              (if (null? xs) (reverse acc)
                                  (loop (cdr xs) (+ i 1)
                                        (if (< i overlap) acc
                                            (cons (cons (car xs) i) acc)))))))
      (for-each
        (lambda (pair)
          (print-indent (cdr pair))
          (display (car pair))
          (newline))
        groups-to-print)
      cur-groups))

  (define (run-tests . args)
    (let ((filter (if (null? args) #f (car args)))
          (passed 0)
          (failed 0)
          (prev-groups '()))
      (for-each
        (lambda (entry)
          (let* ((path (car entry))
                 (thunk (cdr entry))
                 (leaf (car (reverse path))))
            (if (or (not filter) (equal? leaf filter))
                (let ((cur-groups (print-context-transition prev-groups path)))
                  (set! prev-groups cur-groups)
                  (print-indent (length cur-groups))
                  (with-exception-handler
                    (lambda (e)
                      (set! failed (+ failed 1))
                      (display "FAIL ") (display leaf)
                      (display ": ") (display (format-exception e))
                      (newline))
                    (lambda ()
                      (thunk)
                      (set! passed (+ passed 1))
                      (display "PASS ") (display leaf)
                      (newline)))))))
        *tests*)
      (newline)
      (display "Summary: ") (display passed)
      (display " passed, ") (display failed) (display " failed")
      (newline)
      (cons passed failed)))
)
