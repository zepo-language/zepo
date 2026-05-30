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
    ;; Lifecycle hooks (zepo-mqf4)
    before-each after-each before-all after-all
    ;; Assertions
    is is-not
    =check =check~
    throws throws-of does-not-throw
    set-equal? matches
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

  ;; zepo-mqf4: Hook registry. *describes* is a hash-table keyed by describe
  ;; path (e.g. ("stats" "mean")). Each value is another hash-table with
  ;; 'before-each, 'after-each, 'before-all, 'after-all — lists of thunks
  ;; in registration order. before-all-ran? is a per-describe boolean
  ;; tracked separately during a run.
  (define *describes* (make-hash-table))

  (define (describe-record-for path)
    (let ((r (hash-get *describes* path #f)))
      (if r r
          (let ((new (make-hash-table)))
            (hash-set! new 'before-each '())
            (hash-set! new 'after-each '())
            (hash-set! new 'before-all '())
            (hash-set! new 'after-all '())
            (hash-set! *describes* path new)
            new))))

  (define (clear-tests!)
    (set! *tests* '())
    (set! *context-stack* '())
    (set! *describes* (make-hash-table)))

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

  ;; ── Lifecycle hooks (zepo-mqf4) ──────────────────────────────────────────
  ;;
  ;; Each hook registers a thunk against the CURRENT describe scope (i.e.
  ;; the reverse of *context-stack*). At runtime the runner walks each
  ;; test's ancestor describes and invokes the hooks in the right order:
  ;;
  ;;   before-each  outer-to-inner before every it
  ;;   after-each   inner-to-outer after every it (even on failure)
  ;;   before-all   outer-to-inner once before the first it in the describe
  ;;   after-all    inner-to-outer once after the last it in the describe

  (define (register-hook! kind thunk)
    (let* ((path (reverse *context-stack*))
           (rec (describe-record-for path))
           (existing (hash-get rec kind '())))
      (hash-set! rec kind (append existing (list thunk)))))

  (defmacro before-each (thunk)
    `(register-hook! 'before-each ,thunk))

  (defmacro after-each (thunk)
    `(register-hook! 'after-each ,thunk))

  (defmacro before-all (thunk)
    `(register-hook! 'before-all ,thunk))

  (defmacro after-all (thunk)
    `(register-hook! 'after-all ,thunk))

  ;; Walk from "" (the implicit root) down to the test's enclosing describe
  ;; and return a list of describe paths in outer-to-inner order. For a
  ;; test at path ("stats" "mean" "of empty") this returns:
  ;;   (() ("stats") ("stats" "mean"))
  ;; — including the empty path so root-level hooks (none today, but reserved)
  ;; could attach there.
  (define (ancestor-paths test-path)
    (let ((describe-path (let loop ((xs test-path) (acc '()))
                           (if (or (null? xs) (null? (cdr xs)))
                               (reverse acc)
                               (loop (cdr xs) (cons (car xs) acc))))))
      (let loop ((xs describe-path) (acc '()) (cur '()))
        (if (null? xs)
            (append (list '()) (reverse acc))
            (let ((next (append cur (list (car xs)))))
              (loop (cdr xs) (cons next acc) next))))))

  (define (hooks-for path kind)
    (let ((rec (hash-get *describes* path #f)))
      (if rec (hash-get rec kind '()) '())))

  (define (run-hook-list hooks)
    (for-each (lambda (h) (h)) hooks))

  ;; ── Assertions ───────────────────────────────────────────────────────────
  ;;
  ;; All assertion macros expand to a call into an -impl function that does
  ;; the comparison and raises a structured error on failure. The macro
  ;; captures the source expression (via quote) so the failure message can
  ;; show what was actually written, not the post-evaluation value.

  ;; Build a diff line for two values. Lists, hash-tables, and strings get
  ;; first-difference detail; everything else just renders both sides.
  (define (diff-line expected actual)
    (cond
      ((and (string? expected) (string? actual))
       (let ((n (min (string-length expected) (string-length actual))))
         (let loop ((i 0))
           (cond
             ((= i n)
              (if (= (string-length expected) (string-length actual))
                  ""
                  (string-append
                    "  length differs: expected " (number->string (string-length expected))
                    " got " (number->string (string-length actual)))))
             ((not (= (char->integer (string-ref expected i))
                      (char->integer (string-ref actual i))))
              (string-append
                "  first differing char at index " (number->string i)
                ": expected " (write-to-string (string-ref expected i))
                " got " (write-to-string (string-ref actual i))))
             (#t (loop (+ i 1)))))))
      ((and (pair? expected) (pair? actual))
       (let loop ((e expected) (a actual) (i 0))
         (cond
           ((and (null? e) (null? a)) "")
           ((null? e)
            (string-append "  expected ends at index " (number->string i)
              "; got has more elements"))
           ((null? a)
            (string-append "  got ends at index " (number->string i)
              "; expected has more elements"))
           ((not (equal? (car e) (car a)))
            (string-append "  first differing element at index " (number->string i)
              ": expected " (write-to-string (car e))
              " got " (write-to-string (car a))))
           (#t (loop (cdr e) (cdr a) (+ i 1))))))
      (#t "")))

  (define (is-impl quoted-expr value)
    (if value
        #t
        (error (string-append "expected truthy: " (display-to-string quoted-expr)))))

  (define (is-not-impl quoted-expr value)
    (if (not value)
        #t
        (error (string-append "expected falsy: " (display-to-string quoted-expr)))))

  (define (=check-impl quoted-expr expected actual)
    (if (equal? expected actual)
        #t
        (let ((diff (diff-line expected actual))
              (base (string-append
                      "expected " (write-to-string expected)
                      " got "      (write-to-string actual)
                      " in "       (display-to-string quoted-expr))))
          (error (if (= (string-length diff) 0)
                     base
                     (string-append base "\n" diff))))))

  (define (=check~-impl quoted-expr expected actual tol)
    (if (and (number? expected) (number? actual)
             (< (abs (- expected actual)) tol))
        #t
        (error (string-append
                 "expected " (write-to-string expected)
                 " ± "       (write-to-string tol)
                 ", got "    (write-to-string actual)
                 " in "      (display-to-string quoted-expr)))))

  (define (throws-impl quoted-expr thunk)
    (let ((raised? #f))
      (with-exception-handler
        (lambda (e) (set! raised? #t) '())
        (lambda () (thunk)))
      (if raised?
          #t
          (error (string-append
                   "expected an error from " (display-to-string quoted-expr)
                   " but none was raised")))))

  (define (throws-of-impl quoted-expr predicate-name predicate thunk)
    (let ((raised? #f)
          (matched? #f))
      (with-exception-handler
        (lambda (e)
          (set! raised? #t)
          (if (predicate e) (set! matched? #t))
          '())
        (lambda () (thunk)))
      (cond
        ((not raised?)
         (error (string-append
                  "expected an error matching " predicate-name
                  " from " (display-to-string quoted-expr)
                  " but none was raised")))
        ((not matched?)
         (error (string-append
                  "an error was raised but it did not match " predicate-name
                  " in " (display-to-string quoted-expr))))
        (#t #t))))

  (define (does-not-throw-impl quoted-expr thunk)
    (let ((caught #f))
      (with-exception-handler
        (lambda (e) (set! caught e) '())
        (lambda () (thunk)))
      (if caught
          (error (string-append
                   "expected no error from " (display-to-string quoted-expr)
                   " but got " (format-exception caught)))
          #t)))

  ;; Set-equality for lists: ignores order, ignores duplicates.
  (define (set-equal? a b)
    (define (subset? xs ys)
      (let loop ((xs xs))
        (cond ((null? xs) #t)
              ((member (car xs) ys) (loop (cdr xs)))
              (#t #f))))
    (and (subset? a b) (subset? b a)))

  ;; Pattern match. Supports: literals (compared by equal?), the wildcard
  ;; symbol _ (matches anything), and lists (recursive).
  (define (matches value pattern)
    (cond
      ((eq? pattern '_) #t)
      ((and (pair? pattern) (pair? value))
       (and (matches (car value) (car pattern))
            (matches (cdr value) (cdr pattern))))
      ((and (null? pattern) (null? value)) #t)
      (#t (equal? value pattern))))

  ;; ── Assertion macros ─────────────────────────────────────────────────────

  (defmacro is (expr)
    `(is-impl ',expr ,expr))

  (defmacro is-not (expr)
    `(is-not-impl ',expr ,expr))

  (defmacro =check (actual expected)
    `(=check-impl ',actual ,expected ,actual))

  (defmacro =check~ (actual expected tol)
    `(=check~-impl ',actual ,expected ,actual ,tol))

  (defmacro throws (expr)
    `(throws-impl ',expr (lambda () ,expr)))

  ;; (throws-of expr pred) — succeeds if expr raises and pred returns truthy
  ;; on the raised value. pred is typically error-object?, or a procedure
  ;; that inspects (error-object-message) etc.
  (defmacro throws-of (expr pred)
    `(throws-of-impl ',expr ',pred ,pred (lambda () ,expr)))

  (defmacro does-not-throw (expr)
    `(does-not-throw-impl ',expr (lambda () ,expr)))

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

  ;; zepo-mqf4: helper — fire after-all for any describe in prev-ancestors
  ;; that isn't in cur-ancestors (we've LEFT that describe). Walked in
  ;; inner-to-outer order.
  (define (fire-after-all-for-left prev-ancestors cur-ancestors)
    (let loop ((xs (reverse prev-ancestors)))
      (if (null? xs) '()
          (let ((path (car xs)))
            (if (member path cur-ancestors)
                '()  ; once we hit a still-active ancestor, stop
                (begin (run-hook-list (hooks-for path 'after-all))
                       (loop (cdr xs))))))))

  ;; Fire before-all for any describe in cur-ancestors that isn't in
  ;; prev-ancestors (we've ENTERED that describe). Outer-to-inner.
  (define (fire-before-all-for-entered prev-ancestors cur-ancestors)
    (for-each
      (lambda (path)
        (if (not (member path prev-ancestors))
            (run-hook-list (hooks-for path 'before-all))))
      cur-ancestors))

  (define (run! . args)
    (let* ((opts   (parse-runner-args args))
           (silent (car opts))
           (filter (cdr opts))
           (start  (current-time-ms))
           (passed 0)
           (failed 0)
           (failures '())
           (prev-groups '())
           (prev-ancestors '()))
      (for-each
        (lambda (entry)
          (let* ((path (car entry))
                 (thunk (cdr entry))
                 (leaf (car (reverse path))))
            (if (or (not filter) (equal? leaf filter))
                (let* ((cur-ancestors (ancestor-paths path))
                       (cur-groups
                         (if silent prev-groups
                             (print-context-transition prev-groups path))))
                  ;; Lifecycle: leaving describes -> after-all; entering -> before-all
                  (fire-after-all-for-left prev-ancestors cur-ancestors)
                  (fire-before-all-for-entered prev-ancestors cur-ancestors)
                  (set! prev-groups cur-groups)
                  (set! prev-ancestors cur-ancestors)
                  (if (not silent) (print-indent (length cur-groups)))
                  ;; before-each: outer-to-inner
                  (for-each
                    (lambda (p) (run-hook-list (hooks-for p 'before-each)))
                    cur-ancestors)
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
                          (begin (display "PASS ") (display leaf) (newline)))))
                  ;; after-each: inner-to-outer, runs even on failure
                  (for-each
                    (lambda (p) (run-hook-list (hooks-for p 'after-each)))
                    (reverse cur-ancestors))))))
        *tests*)
      ;; Final after-all sweep — fire for any still-active describes.
      (fire-after-all-for-left prev-ancestors '())
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
