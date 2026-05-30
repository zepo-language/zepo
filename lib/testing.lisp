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
    ;; Runner — three variants
    run-tests   ; pretty-print, return (passed . failed), no exit
    run!        ; embeddable: returns a result record, no exit, no print
    run!/exit   ; pretty-print THEN exit 1 on any failure (for top-of-file)
    ;; Result accessors for the run! return value
    result-passed result-failed result-total result-failures result-duration-ms
    clear-tests!)

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

  ;; ── Result record ────────────────────────────────────────────────────────
  ;;
  ;; (run!) returns a hash-table with:
  ;;   'passed       — count of tests that didn't throw
  ;;   'failed       — count of tests that threw
  ;;   'total        — passed + failed (= tests actually executed)
  ;;   'duration-ms  — wall-clock time the whole run took
  ;;   'failures     — list of (path . message) pairs for the failures
  ;;
  ;; The accessors below are just hash-get on that table — they exist so
  ;; callers don't have to know the internal key names. zepo-s3zf will add
  ;; a 'skipped count and zepo-nitj will add reporter integration.

  (define (make-result passed failed failures duration-ms)
    (let ((r (make-hash-table)))
      (hash-set! r 'passed passed)
      (hash-set! r 'failed failed)
      (hash-set! r 'total (+ passed failed))
      (hash-set! r 'duration-ms duration-ms)
      (hash-set! r 'failures failures)
      r))

  (define (result-passed r)      (hash-get r 'passed 0))
  (define (result-failed r)      (hash-get r 'failed 0))
  (define (result-total r)       (hash-get r 'total 0))
  (define (result-duration-ms r) (hash-get r 'duration-ms 0))
  (define (result-failures r)    (hash-get r 'failures '()))

  ;; ── Core runner ──────────────────────────────────────────────────────────
  ;;
  ;; (run! :silent #t/#f :filter NAME) is the embeddable variant. Returns
  ;; the result record. Never calls exit. When :silent is true (default for
  ;; programmatic callers), prints nothing — useful for tests-of-tests and
  ;; for any caller that wants to format the result themselves.
  ;;
  ;; The legacy (run-tests . args) and the new (run!/exit . args) sit on
  ;; top of run! with the appropriate side effects.

  (define (parse-runner-args args)
    ;; Accepts: (run! :silent #t :filter "foo") OR positional first-arg
    ;; legacy form (run! "foo") meaning :filter "foo".
    (let loop ((xs args) (silent #f) (filter #f))
      (cond
        ((null? xs) (cons silent filter))
        ((and (symbol? (car xs)) (eq? (car xs) ':silent))
         (loop (cddr xs) (cadr xs) filter))
        ((and (symbol? (car xs)) (eq? (car xs) ':filter))
         (loop (cddr xs) silent (cadr xs)))
        ((string? (car xs))
         (loop (cdr xs) silent (car xs)))
        (#t (loop (cdr xs) silent filter)))))

  (define (run! . args)
    (let* ((opts   (parse-runner-args args))
           (silent (car opts))
           (filter (cdr opts))
           (start  (current-time-ms))
           (passed 0)
           (failed 0)
           (failures '())
           (prev-groups '()))
      (for-each
        (lambda (entry)
          (let* ((path (car entry))
                 (thunk (cdr entry))
                 (leaf (car (reverse path))))
            (if (or (not filter) (equal? leaf filter))
                (let ((cur-groups
                        (if silent prev-groups
                            (print-context-transition prev-groups path))))
                  (set! prev-groups cur-groups)
                  (if (not silent) (print-indent (length cur-groups)))
                  (with-exception-handler
                    (lambda (e)
                      (let ((msg (format-exception e)))
                        (set! failed (+ failed 1))
                        (set! failures (append failures (list (cons path msg))))
                        (if (not silent)
                            (begin
                              (display "FAIL ") (display leaf)
                              (display ": ") (display msg) (newline)))))
                    (lambda ()
                      (thunk)
                      (set! passed (+ passed 1))
                      (if (not silent)
                          (begin (display "PASS ") (display leaf) (newline)))))))))
        *tests*)
      (let ((duration (- (current-time-ms) start)))
        (if (not silent)
            (begin
              (newline)
              (display "Summary: ") (display passed)
              (display " passed, ") (display failed) (display " failed")
              (display " (") (display duration) (display " ms)")
              (newline)))
        (make-result passed failed failures duration))))

  ;; Legacy printer that returns (passed . failed) — keeps the smoke tests
  ;; written against zepo-mx0p working without modification.
  (define (run-tests . args)
    (let ((r (apply run! args)))
      (cons (result-passed r) (result-failed r))))

  ;; (run!/exit) — top-of-file convenience. Pretty-prints then exits 1 on
  ;; any failure. This is what you want at the very bottom of a test file
  ;; that's meant to be run as a script.
  (define (run!/exit . args)
    (let ((r (apply run! args)))
      (if (> (result-failed r) 0) (exit 1))
      r))
)
