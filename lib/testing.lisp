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
    ;; Focus / skip (zepo-s3zf)
    fdescribe fit xdescribe xit
    ;; Tags (zepo-nqfu)
    tag
    ;; Reporters (zepo-nitj)
    make-reporter
    reporter-pretty reporter-tap reporter-junit reporter-json
    ;; Timeouts (zepo-sdxa)
    with-timeout-ms
    ;; Property-based testing (zepo-qv9y)
    check-property
    ;; Doctests (zepo-dheb)
    load-doctests
    ;; Lifecycle hooks (zepo-mqf4)
    before-each after-each before-all after-all
    ;; Assertions
    is is-not
    =check =check~
    =snapshot
    throws throws-of does-not-throw
    set-equal? matches
    ;; Runner — three variants
    run-tests   ; pretty-print, return (passed . failed), no exit
    run!        ; embeddable: returns a result record, no exit, no print
    run!/exit   ; pretty-print THEN exit 1 on any failure (for top-of-file)
    ;; Result accessors for the run! return value
    result-passed result-failed result-skipped result-total result-failures result-duration-ms
    clear-tests!)

  ;; zepo-qv9y: imported here so check-property can pull samples / shrinks.
  (import math/dist (make-rng))
  (import math/gen  (gen-sample gen-shrink))

  ;; ── State ─────────────────────────────────────────────────────────────────

  ;; Stack of describe-block labels currently in scope. The full path of a
  ;; test is (reverse *context-stack*) appended with the test's own name.
  (define *context-stack* '())

  ;; Every (it ...) and (deftest ...) appends to this list at registration
  ;; time. Each entry is (path . thunk) where path is a list of strings.
  (define *tests* '())

  ;; zepo-s3zf focus / skip support.
  (define *focus-active?* #f)
  (define *describe-mode* 'normal)

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
  (define (register-test! name thunk . maybe-mode)
    (let* ((path (append (reverse *context-stack*) (list name)))
           (mode (if (null? maybe-mode) *describe-mode* (car maybe-mode)))
           (tags (append *describe-tags* *pending-tags*)))
      (set! *pending-tags* '())  ; consumed
      (if (eq? mode 'focused) (set! *focus-active?* #t))
      (set! *tests* (append *tests* (list (list path thunk mode tags))))))

  ;; zepo-nqfu: tags carried by the current describe scope plus any
  ;; (tag :foo :bar) form that appeared since the last test was registered.
  (define *describe-tags* '())
  (define *pending-tags*  '())

  ;; Push-helper used by the (tag ...) macro. Lives as a function so the
  ;; macro expansion doesn't need to set! a qualified name (the we7e
  ;; rewriter would turn *pending-tags* into testing.*pending-tags* in
  ;; the expansion, and set! on qualified names isn't supported).
  (define (push-pending-tags! more)
    (set! *pending-tags* (append *pending-tags* more)))

  ;; ── Snapshots (zepo-e6o9) ────────────────────────────────────────────────
  ;;
  ;; *current-test-path* is set by the runner just before invoking a test's
  ;; thunk so that =snapshot can default its :name argument to a sanitized
  ;; version of the test path. *update-snapshots?* is a per-run flag flipped
  ;; on by (run! :update-snapshots #t) — when true, snapshot mismatches are
  ;; overwritten and reported as PASS UPDATED instead of FAIL.

  (define *current-test-path* '())
  (define *update-snapshots?* #f)

  (define (set-current-test-path! p) (set! *current-test-path* p))
  (define (current-test-path) *current-test-path*)
  (define (update-snapshots?) *update-snapshots?*)

  ;; Sanitize a character: alnum and a few safe punctuation stay, everything
  ;; else (slash, spaces, control chars, quotes, etc) becomes '-'.
  (define (snap-char-safe? c)
    (or (and (char>=? c #\a) (char<=? c #\z))
        (and (char>=? c #\A) (char<=? c #\Z))
        (and (char>=? c #\0) (char<=? c #\9))
        (char=? c #\_)
        (char=? c #\.)
        (char=? c #\-)))

  (define (slugify s)
    (let ((n (string-length s)))
      (let loop ((i 0) (acc ""))
        (if (>= i n) acc
            (let ((c (string-ref s i)))
              (loop (+ i 1)
                    (string-append acc
                      (if (snap-char-safe? c) (char->string c) "-"))))))))

  ;; Join path components with "--" and slugify each — produces a single
  ;; filesystem-safe identifier for the test.
  (define (path->snapshot-slug path)
    (let loop ((xs path) (acc ""))
      (cond
        ((null? xs) (if (= (string-length acc) 0) "snapshot" acc))
        ((= (string-length acc) 0)
         (loop (cdr xs) (slugify (car xs))))
        (#t (loop (cdr xs)
                  (string-append acc "--" (slugify (car xs))))))))

  ;; Default snapshot directory; resolved at call time so tests can override.
  (define *snapshot-dir* ".zepo-snapshots")

  ;; Ensure parent directory of `path` exists; uses make-directory which is
  ;; mkdir -p semantics in Zepo.
  (define (ensure-parent-dir! path)
    (let loop ((i (- (string-length path) 1)))
      (cond
        ((< i 0) #t)
        ((char=? (string-ref path i) #\/)
         (let ((dir (substring path 0 i)))
           (if (> (string-length dir) 0)
               (make-directory dir))))
        (#t (loop (- i 1))))))

  (define (default-snapshot-path)
    (string-append *snapshot-dir* "/"
                   (path->snapshot-slug (current-test-path))
                   ".snap"))

  ;; Build a short diff describing how `expected` (stored) differs from
  ;; `actual` (current run). Uses character-level diff via diff-line and
  ;; falls back to side-by-side rendering.
  (define (snapshot-diff expected actual)
    (let ((d (diff-line expected actual)))
      (if (> (string-length d) 0)
          d
          (string-append "  expected:\n    " expected
                         "\n  actual:\n    " actual))))

  (define (=snapshot-impl quoted-expr value path)
    (let* ((serialized (write-to-string value))
           (effective-path (if path path (default-snapshot-path))))
      (cond
        ;; First run — write and report a NEW SNAPSHOT pass.
        ((not (file-exists? effective-path))
         (ensure-parent-dir! effective-path)
         (file-write-string effective-path serialized)
         ;; A pass is signalled by returning normally. We still emit a
         ;; one-line note to stderr/stdout so the user knows a new
         ;; snapshot was created.
         (display "  [NEW SNAPSHOT ") (display effective-path) (display "]") (newline)
         #t)
        (#t
         (let ((stored (file-read-string effective-path)))
           (cond
             ((string=? stored serialized) #t)
             ((update-snapshots?)
              (file-write-string effective-path serialized)
              (display "  [UPDATED SNAPSHOT ") (display effective-path) (display "]") (newline)
              #t)
             (#t
              (error (string-append
                       "snapshot mismatch for " (display-to-string quoted-expr)
                       " at " effective-path "\n"
                       (snapshot-diff stored serialized))))))))))

  ;; (tag 'slow 'integration ...) — attaches the given quoted tags to the
  ;; very next test registration. Note: tags are passed AS QUOTED SYMBOLS
  ;; ('slow not :slow) because Zepo's keyword syntax (`:foo`) parses as a
  ;; standalone symbol with a `:` prefix; quoted symbols are simpler and
  ;; play nicely with equal? comparison in the filter.
  (defmacro tag tags
    `(push-pending-tags! (list ,@tags)))

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

  ;; zepo-s3zf focus / skip macros.
  (define (with-describe-mode! new-mode thunk)
    (let ((old *describe-mode*))
      (set! *describe-mode* new-mode)
      (thunk)
      (set! *describe-mode* old)))

  (defmacro fdescribe (name . body)
    `(begin
       (push-context! ,name)
       (with-describe-mode! 'focused (lambda () ,@body))
       (pop-context!)))

  (defmacro xdescribe (name . body)
    `(begin
       (push-context! ,name)
       (with-describe-mode! 'skipped (lambda () ,@body))
       (pop-context!)))

  (defmacro fit (name . body)
    `(register-test! ,name (lambda () ,@body) 'focused))

  (defmacro xit (name . body)
    `(register-test! ,name (lambda () ,@body) 'skipped))

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

  ;; (=snapshot value)            — snapshot path defaults from current test
  ;; (=snapshot value :name PATH) — explicit snapshot file
  ;;
  ;; First run writes the snapshot, subsequent runs compare. When the run is
  ;; invoked with :update-snapshots #t, mismatches overwrite the file and
  ;; pass with an UPDATED note.
  (defmacro =snapshot args
    (let ((value (car args))
          (rest (cdr args)))
      (let loop ((xs rest) (name #f))
        (cond
          ((null? xs)
           `(=snapshot-impl ',value ,value ,name))
          ((and (pair? xs) (symbol? (car xs)) (eq? (car xs) ':name))
           (loop (cddr xs) (cadr xs)))
          (#t (loop (cdr xs) name))))))

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

  (define (make-result passed failed skipped failures duration-ms)
    (let ((r (make-hash-table)))
      (hash-set! r 'passed passed)
      (hash-set! r 'failed failed)
      (hash-set! r 'skipped skipped)
      (hash-set! r 'total (+ passed failed))
      (hash-set! r 'duration-ms duration-ms)
      (hash-set! r 'failures failures)
      r))

  (define (result-passed r)      (hash-get r 'passed 0))
  (define (result-failed r)      (hash-get r 'failed 0))
  (define (result-skipped r)     (hash-get r 'skipped 0))
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

  ;; Returns a hash-table of options. Legacy positional-string form
  ;; (run! "foo") is still accepted and treated as :filter "foo".
  (define (parse-runner-args args)
    (let ((opts (make-hash-table)))
      (hash-set! opts 'silent #f)
      (hash-set! opts 'filter #f)
      (hash-set! opts 'tags '())
      (hash-set! opts 'exclude-tags '())
      (hash-set! opts 'reporter #f)
      (hash-set! opts 'update-snapshots #f)
      (let loop ((xs args))
        (cond
          ((null? xs) opts)
          ((and (symbol? (car xs)) (eq? (car xs) ':silent))
           (hash-set! opts 'silent (cadr xs))
           (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':filter))
           (hash-set! opts 'filter (cadr xs))
           (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':tags))
           (hash-set! opts 'tags (cadr xs))
           (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':exclude-tags))
           (hash-set! opts 'exclude-tags (cadr xs))
           (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':reporter))
           (hash-set! opts 'reporter (cadr xs))
           (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':update-snapshots))
           (hash-set! opts 'update-snapshots (cadr xs))
           (loop (cddr xs)))
          ((string? (car xs))
           (hash-set! opts 'filter (car xs))
           (loop (cdr xs)))
          (#t (loop (cdr xs)))))))

  ;; Returns #t if `lst` and `other` share at least one equal? element.
  (define (any-shared? lst other)
    (let loop ((xs lst))
      (cond ((null? xs) #f)
            ((member (car xs) other) #t)
            (#t (loop (cdr xs))))))

  ;; Simple substring filter for now. A future pass could add fnmatch-style
  ;; globbing.
  (define (path-matches-filter? path pattern)
    (or (not pattern)
        (let ((full-name (let loop ((xs path) (acc ""))
                           (cond
                             ((null? xs) acc)
                             ((= (string-length acc) 0) (loop (cdr xs) (car xs)))
                             (#t (loop (cdr xs)
                                       (string-append acc " / " (car xs))))))))
          (>= (string-length full-name) 0)  ; always non-negative
          (string-contains? full-name pattern))))

  ;; substring search: returns #t if `needle` appears in `haystack`.
  (define (string-contains? haystack needle)
    (let ((hl (string-length haystack))
          (nl (string-length needle)))
      (if (> nl hl) #f
          (let loop ((i 0))
            (cond
              ((> (+ i nl) hl) #f)
              ((string=? (substring haystack i (+ i nl)) needle) #t)
              (#t (loop (+ i 1))))))))

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

  ;; ── Reporters (zepo-nitj) ────────────────────────────────────────────────
  ;;
  ;; A reporter is a hash-table mapping event symbols to handler thunks:
  ;;
  ;;   'on-start         (lambda (total) ...)         — called once before any test
  ;;   'on-test-pass     (lambda (path duration) ...) — test passed
  ;;   'on-test-fail     (lambda (path msg) ...)      — test failed
  ;;   'on-test-skip     (lambda (path reason) ...)   — test skipped
  ;;   'on-end           (lambda (result) ...)        — called once with the result record
  ;;
  ;; (make-reporter alist) constructs a reporter from an a-list of
  ;; event/handler pairs. Missing events are no-ops.
  ;;
  ;; The four built-ins (pretty, tap, junit, json) are functions that
  ;; produce a reporter; (run! :reporter (reporter-tap)) plugs one in.
  ;; A symbol shorthand (run! :reporter 'tap) is also accepted.

  (define (make-reporter handlers-alist)
    (let ((r (make-hash-table)))
      (let loop ((xs handlers-alist))
        (if (not (null? xs))
            (begin (hash-set! r (car (car xs)) (cdr (car xs)))
                   (loop (cdr xs)))))
      r))

  (define (call-handler! reporter event . args)
    (let ((h (hash-get reporter event #f)))
      (if h (apply h args))))

  (define (path->joined path)
    (let loop ((xs path) (acc ""))
      (cond
        ((null? xs) acc)
        ((= (string-length acc) 0) (loop (cdr xs) (car xs)))
        (#t (loop (cdr xs) (string-append acc " / " (car xs)))))))

  ;; ── Pretty reporter ─────────────────────────────────────────────────────
  ;; The original tree output, refactored into a reporter. Hooks into the
  ;; runner's prev-groups state via a closure-local variable.

  (define (reporter-pretty)
    (let ((prev-groups '()))
      (make-reporter
        (list
          (cons 'on-test-pass
                (lambda (path duration)
                  (let ((cur-groups (print-context-transition prev-groups path)))
                    (set! prev-groups cur-groups)
                    (print-indent (length cur-groups))
                    (display "PASS ") (display (car (reverse path))) (newline))))
          (cons 'on-test-fail
                (lambda (path msg)
                  (let ((cur-groups (print-context-transition prev-groups path)))
                    (set! prev-groups cur-groups)
                    (print-indent (length cur-groups))
                    (display "FAIL ") (display (car (reverse path)))
                    (display ": ") (display msg) (newline))))
          (cons 'on-test-skip
                (lambda (path reason)
                  (let ((cur-groups (print-context-transition prev-groups path)))
                    (set! prev-groups cur-groups)
                    (print-indent (length cur-groups))
                    (display "SKIP ") (display (car (reverse path))) (newline))))
          (cons 'on-end
                (lambda (result)
                  (newline)
                  (display "Summary: ") (display (result-passed result))
                  (display " passed, ") (display (result-failed result)) (display " failed")
                  (if (> (result-skipped result) 0)
                      (begin (display ", ") (display (result-skipped result)) (display " skipped")))
                  (display " (") (display (result-duration-ms result)) (display " ms)") (newline)))))))

  ;; ── TAP version 14 reporter ─────────────────────────────────────────────

  (define (reporter-tap)
    (let ((n 0) (planned 0))
      (make-reporter
        (list
          (cons 'on-start
                (lambda (total)
                  (set! planned total)
                  (display "TAP version 14") (newline)
                  (display "1..") (display total) (newline)))
          (cons 'on-test-pass
                (lambda (path duration)
                  (set! n (+ n 1))
                  (display "ok ") (display n) (display " - ")
                  (display (path->joined path)) (newline)))
          (cons 'on-test-fail
                (lambda (path msg)
                  (set! n (+ n 1))
                  (display "not ok ") (display n) (display " - ")
                  (display (path->joined path)) (newline)
                  (display "  # ") (display msg) (newline)))
          (cons 'on-test-skip
                (lambda (path reason)
                  (set! n (+ n 1))
                  (display "ok ") (display n) (display " - ")
                  (display (path->joined path)) (display " # SKIP") (newline)))))))

  ;; ── JSON NDJSON reporter ────────────────────────────────────────────────
  ;; One JSON object per line, no enclosing array. Tools can stream-parse.

  (define (json-escape s)
    (let loop ((i 0) (acc ""))
      (if (>= i (string-length s)) acc
          (let ((c (string-ref s i)))
            (loop (+ i 1)
                  (string-append acc
                    (cond
                      ((char=? c #\") "\\\"")
                      ((char=? c #\\) "\\\\")
                      ((char=? c #\newline) "\\n")
                      ((char=? c #\tab) "\\t")
                      (#t (char->string c)))))))))

  (define (json-path-array path)
    (let loop ((xs path) (acc "["))
      (cond
        ((null? xs) (string-append acc "]"))
        ((string=? acc "[")
         (loop (cdr xs) (string-append acc "\"" (json-escape (car xs)) "\"")))
        (#t (loop (cdr xs) (string-append acc ",\"" (json-escape (car xs)) "\""))))))

  (define (reporter-json)
    (make-reporter
      (list
        (cons 'on-test-pass
              (lambda (path duration)
                (display "{\"event\":\"pass\",\"path\":")
                (display (json-path-array path))
                (display "}") (newline)))
        (cons 'on-test-fail
              (lambda (path msg)
                (display "{\"event\":\"fail\",\"path\":")
                (display (json-path-array path))
                (display ",\"message\":\"") (display (json-escape msg))
                (display "\"}") (newline)))
        (cons 'on-test-skip
              (lambda (path reason)
                (display "{\"event\":\"skip\",\"path\":")
                (display (json-path-array path))
                (display "}") (newline)))
        (cons 'on-end
              (lambda (r)
                (display "{\"event\":\"end\",\"passed\":") (display (result-passed r))
                (display ",\"failed\":") (display (result-failed r))
                (display ",\"skipped\":") (display (result-skipped r))
                (display ",\"duration_ms\":") (display (result-duration-ms r))
                (display "}") (newline))))))

  ;; ── JUnit XML reporter ──────────────────────────────────────────────────
  ;; Schema: <testsuites><testsuite name="..." tests="N" failures="F" skipped="S">
  ;;           <testcase name="path / name" classname="path"/>
  ;;           <testcase ...><failure message="..."/></testcase>
  ;;           <testcase ...><skipped/></testcase>
  ;;         </testsuite></testsuites>
  ;; Single suite covers everything — most CI parsers handle a single
  ;; <testsuites><testsuite> wrapper just fine.

  (define (xml-escape s)
    (let loop ((i 0) (acc ""))
      (if (>= i (string-length s)) acc
          (let ((c (string-ref s i)))
            (loop (+ i 1)
                  (string-append acc
                    (cond
                      ((char=? c #\&) "&amp;")
                      ((char=? c #\<) "&lt;")
                      ((char=? c #\>) "&gt;")
                      ((char=? c #\") "&quot;")
                      ((char=? c #\') "&apos;")
                      (#t (char->string c)))))))))

  (define (reporter-junit)
    (let ((cases '()))
      (define (record-case! kind path msg)
        (set! cases (append cases (list (list kind path msg)))))
      (make-reporter
        (list
          (cons 'on-test-pass (lambda (path duration) (record-case! 'pass path "")))
          (cons 'on-test-fail (lambda (path msg)      (record-case! 'fail path msg)))
          (cons 'on-test-skip (lambda (path reason)   (record-case! 'skip path "")))
          (cons 'on-end
                (lambda (r)
                  (display "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") (newline)
                  (display "<testsuites>") (newline)
                  (display "  <testsuite name=\"zepo\" tests=\"")
                  (display (+ (result-passed r) (result-failed r) (result-skipped r)))
                  (display "\" failures=\"") (display (result-failed r))
                  (display "\" skipped=\"") (display (result-skipped r))
                  (display "\">") (newline)
                  (for-each
                    (lambda (c)
                      (let* ((kind (car c))
                             (path (cadr c))
                             (msg  (caddr c))
                             (leaf (car (reverse path)))
                             (cls  (path->joined (reverse (cdr (reverse path))))))
                        (display "    <testcase classname=\"")
                        (display (xml-escape cls))
                        (display "\" name=\"")
                        (display (xml-escape leaf))
                        (display "\"")
                        (cond
                          ((eq? kind 'fail)
                           (display ">") (newline)
                           (display "      <failure message=\"")
                           (display (xml-escape msg))
                           (display "\"/>") (newline)
                           (display "    </testcase>") (newline))
                          ((eq? kind 'skip)
                           (display ">") (newline)
                           (display "      <skipped/>") (newline)
                           (display "    </testcase>") (newline))
                          (#t (display "/>") (newline)))))
                    cases)
                  (display "  </testsuite>") (newline)
                  (display "</testsuites>") (newline)))))))

  ;; Resolve a :reporter argument: a symbol picks one of the built-ins,
  ;; a hash-table is treated as a ready reporter.
  (define (resolve-reporter spec)
    (cond
      ((not spec) #f)
      ((eq? spec 'pretty) (reporter-pretty))
      ((eq? spec 'tap)    (reporter-tap))
      ((eq? spec 'junit)  (reporter-junit))
      ((eq? spec 'json)   (reporter-json))
      (#t spec)))  ; assume it's already a reporter hash-table

  ;; ── Timeouts (zepo-sdxa) ─────────────────────────────────────────────────
  ;;
  ;; (with-timeout-ms ms thunk) runs THUNK to completion and reports a
  ;; failure if the elapsed wall-clock time exceeded `ms` milliseconds.
  ;;
  ;; This is a POST-HOC check, same model as JUnit's @Timeout: a hung test
  ;; will not be killed, but a slow test is flagged when it finally returns.
  ;; That's the only honest semantics on cooperative fibers — Zepo has no
  ;; thread.interrupt() to bail out of a CPU-bound loop. A fiber-race
  ;; design was prototyped but leaked the losing test fiber, which
  ;; permanently stalled process shutdown waiting for the slow thunk to
  ;; finish anyway. The post-hoc form runs as fast as the test does and
  ;; reports a useful failure message naming both the deadline and the
  ;; actual duration.

  (define (with-timeout-ms ms thunk)
    (let* ((start (current-time-ms))
           (value (thunk))
           (elapsed (- (current-time-ms) start)))
      (if (> elapsed ms)
          (error (string-append
                   "test exceeded timeout of "
                   (number->string ms) " ms (took "
                   (number->string elapsed) " ms)"))
          value)))

  ;; ── Property-based testing (zepo-qv9y) ───────────────────────────────────
  ;;
  ;; (check-property prop-fn :gen GEN :iterations N :rng RNG)
  ;;
  ;; Repeatedly samples values from GEN and calls (prop-fn v). If prop-fn
  ;; returns truthy, the iteration passes. If it returns #f OR raises,
  ;; we've found a failing example — enter the shrink loop:
  ;;
  ;;   try each shrunk candidate; if any also fails, recurse from there
  ;;   and keep the smallest failing one as the reported counter-example.
  ;;
  ;; The final assertion error names the SMALLEST failing value plus the
  ;; iteration that surfaced the original failure.

  (define (call-property prop-fn v)
    (let ((ok? #f))
      (with-exception-handler
        (lambda (e) (set! ok? #f) '())
        (lambda () (set! ok? (and (prop-fn v) #t))))
      ok?))

  ;; Shrink loop: returns the smallest failing value found from `start`.
  ;; Limits shrink-step count to avoid pathological cases. The gen module
  ;; is supplied to provide the per-iteration shrink function.
  (define (shrink-failure gen prop-fn start max-steps)
    (let loop ((cur start) (steps 0))
      (if (>= steps max-steps)
          cur
          (let ((cands (gen-shrink gen cur)))
            (let next ((xs cands))
              (cond
                ((null? xs) cur)  ; no candidate failed — done shrinking
                ((not (call-property prop-fn (car xs)))
                 (loop (car xs) (+ steps 1)))
                (#t (next (cdr xs)))))))))

  (define (parse-property-args args)
    (let ((opts (make-hash-table)))
      (hash-set! opts 'gen #f)
      (hash-set! opts 'iterations 100)
      (hash-set! opts 'rng #f)
      (hash-set! opts 'max-shrink-steps 100)
      (let loop ((xs args))
        (cond
          ((null? xs) opts)
          ((and (symbol? (car xs)) (eq? (car xs) ':gen))
           (hash-set! opts 'gen (cadr xs)) (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':iterations))
           (hash-set! opts 'iterations (cadr xs)) (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':rng))
           (hash-set! opts 'rng (cadr xs)) (loop (cddr xs)))
          ((and (symbol? (car xs)) (eq? (car xs) ':max-shrink-steps))
           (hash-set! opts 'max-shrink-steps (cadr xs)) (loop (cddr xs)))
          (#t (loop (cdr xs)))))))

  ;; check-property is a function (not a macro). It raises on failure with
  ;; a message naming the shrunk counter-example, so it composes with
  ;; everything from with-exception-handler to the regular run! loop.
  (define (check-property prop-fn . opts)
    (let* ((p          (parse-property-args opts))
           (gen        (hash-get p 'gen #f))
           (iterations (hash-get p 'iterations 100))
           (rng        (or (hash-get p 'rng #f) (make-rng-from-time)))
           (max-shrink (hash-get p 'max-shrink-steps 100)))
      (if (not gen) (error "check-property: :gen is required"))
      (let loop ((i 0))
        (if (>= i iterations)
            #t  ; all good
            (let* ((v (gen-sample gen rng))
                   (ok? (call-property prop-fn v)))
              (if ok?
                  (loop (+ i 1))
                  (let ((smallest (shrink-failure gen prop-fn v max-shrink)))
                    (error (string-append
                             "property failed at iteration "
                             (number->string (+ i 1))
                             "; smallest failing input: "
                             (write-to-string smallest))))))))))

  (define (make-rng-from-time)
    (make-rng (current-time-ms)))

  ;; ── Doctest harvester (zepo-dheb) ────────────────────────────────────────
  ;;
  ;; (load-doctests path) scans the file at PATH for comments of the form:
  ;;
  ;;     ;; >>> EXPRESSION
  ;;     ;; => EXPECTED-RESULT
  ;;
  ;; Each pair becomes a registered test under
  ;;
  ;;     (describe "<path> / doctest"
  ;;       (it "EXPRESSION" (=check EXPRESSION EXPECTED-RESULT)))
  ;;
  ;; The file's normal code is NOT executed — only the comment lines are
  ;; harvested. Returns the number of doctests registered.
  ;;
  ;; Multi-line expressions aren't supported in this MVP — keep both the
  ;; EXPRESSION and EXPECTED-RESULT on single lines, each prefixed by
  ;; `;; >>> ` or `;; => ` respectively.

  (define (trim-line s)
    ;; trims leading/trailing whitespace using the stdlib's string-trim-*
    (string-trim-right (string-trim-left s)))

  (define (starts-with? s prefix)
    (let ((sl (string-length s)) (pl (string-length prefix)))
      (if (< sl pl) #f
          (string=? (substring s 0 pl) prefix))))

  ;; Walk the source, collect (input . expected) pairs. A >>> line followed
  ;; (possibly with whitespace-only lines between) by a => line forms a pair.
  (define (extract-doctest-pairs text)
    (let* ((lines (string-split text #\newline))
           (pairs '())
           (pending #f))
      (for-each
        (lambda (line)
          (let ((trimmed (trim-line line)))
            (cond
              ((starts-with? trimmed ";; >>>")
               (set! pending (trim-line (substring trimmed 6 (string-length trimmed)))))
              ((and pending (starts-with? trimmed ";; =>"))
               (let ((expected (trim-line (substring trimmed 5 (string-length trimmed)))))
                 (set! pairs (append pairs (list (cons pending expected))))
                 (set! pending #f)))
              ((and pending (= (string-length trimmed) 0))
               '())   ; blank line between >>> and => is fine — keep pending
              (#t
               ;; Anything else clears a stale >>> with no => follow-up.
               (if pending (set! pending #f))))))
        lines)
      pairs))

  ;; Register one harvested pair as a doctest. The expression and expected
  ;; result are stored as STRINGS — the test thunk evals both via the host
  ;; reader using (eval (read-from-string expr)) so the test runs against
  ;; the importer's environment.
  (define (register-doctest! file-label expr-str expected-str)
    (push-context! (string-append file-label " / doctest"))
    (register-test!
      expr-str
      (lambda ()
        ;; actual: parse + evaluate the expression
        ;; expected: parse-only — the result is a LITERAL VALUE, not code
        (let ((actual   (eval (read-from-string expr-str)))
              (expected (read-from-string expected-str)))
          (if (not (equal? actual expected))
              (error (string-append
                       "doctest: expected "
                       (write-to-string expected)
                       " got "
                       (write-to-string actual)
                       " in: "
                       expr-str))))))
    (pop-context!))

  (define (load-doctests path)
    (let* ((text  (file-read-string path))
           (pairs (extract-doctest-pairs text))
           (label path))
      (for-each
        (lambda (p) (register-doctest! label (car p) (cdr p)))
        pairs)
      (length pairs)))

  (define (run! . args)
    (let* ((opts          (parse-runner-args args))
           (silent        (hash-get opts 'silent #f))
           (filter        (hash-get opts 'filter #f))
           (include-tags  (hash-get opts 'tags '()))
           (exclude-tags  (hash-get opts 'exclude-tags '()))
           (reporter      (resolve-reporter (hash-get opts 'reporter #f)))
           (update-snaps  (hash-get opts 'update-snapshots #f))
           (start  (current-time-ms))
           (planned-count (length *tests*))
           (passed 0)
           (failed 0)
           (skipped 0)
           (failures '())
           (prev-groups '())
           (prev-ancestors '()))
      (set! *update-snapshots?* update-snaps)
      (if reporter (call-handler! reporter 'on-start planned-count))
      (for-each
        (lambda (entry)
          (let* ((path (car entry))
                 (thunk (cadr entry))
                 (mode (caddr entry))
                 (tags (if (>= (length entry) 4) (cadddr entry) '()))
                 (leaf (car (reverse path)))
                 (action (cond
                           ((eq? mode 'skipped) 'skip)
                           ((and *focus-active?* (not (eq? mode 'focused))) 'skip)
                           (#t 'run)))
                 (passes-filter? (path-matches-filter? path filter))
                 (passes-tags?   (or (null? include-tags)
                                     (any-shared? tags include-tags)))
                 (excluded?      (and (not (null? exclude-tags))
                                      (any-shared? tags exclude-tags))))
            (if (and passes-filter? passes-tags? (not excluded?))
                (let* ((cur-ancestors (ancestor-paths path))
                       (cur-groups
                         (if (or silent reporter) prev-groups
                             (print-context-transition prev-groups path))))
                  (fire-after-all-for-left prev-ancestors cur-ancestors)
                  (fire-before-all-for-entered prev-ancestors cur-ancestors)
                  (set! prev-groups cur-groups)
                  (set! prev-ancestors cur-ancestors)
                  (if (and (not silent) (not reporter))
                      (print-indent (length cur-groups)))
                  (cond
                    ((eq? action 'skip)
                     (set! skipped (+ skipped 1))
                     (cond
                       (reporter (call-handler! reporter 'on-test-skip path ""))
                       ((not silent)
                        (display "SKIP ") (display leaf) (newline))))
                    (#t
                     (for-each
                       (lambda (p) (run-hook-list (hooks-for p 'before-each)))
                       cur-ancestors)
                     (let ((tstart (current-time-ms)))
                       (with-exception-handler
                         (lambda (e)
                           (let ((msg (format-exception e)))
                             (set! failed (+ failed 1))
                             (set! failures (append failures (list (cons path msg))))
                             (cond
                               (reporter (call-handler! reporter 'on-test-fail path msg))
                               ((not silent)
                                (display "FAIL ") (display leaf)
                                (display ": ") (display msg) (newline)))))
                         (lambda ()
                           (set-current-test-path! path)
                           (thunk)
                           (set! passed (+ passed 1))
                           (let ((tdur (- (current-time-ms) tstart)))
                             (cond
                               (reporter (call-handler! reporter 'on-test-pass path tdur))
                               ((not silent)
                                (display "PASS ") (display leaf) (newline)))))))
                     (for-each
                       (lambda (p) (run-hook-list (hooks-for p 'after-each)))
                       (reverse cur-ancestors))))))))
        *tests*)
      ;; Final after-all sweep — fire for any still-active describes.
      (fire-after-all-for-left prev-ancestors '())
      (let* ((duration (- (current-time-ms) start))
             (result   (make-result passed failed skipped failures duration)))
        (cond
          (reporter (call-handler! reporter 'on-end result))
          ((not silent)
           (newline)
           (display "Summary: ") (display passed)
           (display " passed, ") (display failed) (display " failed")
           (if (> skipped 0)
               (begin (display ", ") (display skipped) (display " skipped")))
           (display " (") (display duration) (display " ms)")
           (newline)))
        result)))

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
