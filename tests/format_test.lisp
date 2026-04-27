(import test)
(import format)

; ── Directive: ~a (display) ───────────────────────────────────────────────────

(deftest format/~a-string
  (=check (format "~a" "hello") "hello"))

(deftest format/~a-number
  (=check (format "~a" 42)   "42")
  (=check (format "~a" -7)   "-7")
  (=check (format "~a" 3.14) "3.14"))

(deftest format/~a-boolean
  (=check (format "~a" #t) "#t")
  (=check (format "~a" #f) "#f"))

(deftest format/~a-list
  (=check (format "~a" '(1 2 3)) "(1 2 3)"))

; ── Directive: ~s (write/quoted) ─────────────────────────────────────────────

(deftest format/~s-string-is-quoted
  (=check (format "~s" "hello") "\"hello\""))

(deftest format/~s-list-with-strings
  (=check (format "~s" '(a "b" 3)) "(a \"b\" 3)"))

(deftest format/~s-vs-~a
  ; ~a displays without quotes, ~s writes with quotes
  (is (not (equal? (format "~a" "x") (format "~s" "x")))))

; ── Directive: ~% (newline) ───────────────────────────────────────────────────

(deftest format/~%-single
  (=check (format "line1~%line2") "line1\nline2"))

(deftest format/~%-multiple
  (=check (format "a~%b~%c") "a\nb\nc"))

; ── Directive: ~~ (literal tilde) ────────────────────────────────────────────

(deftest format/~~-escape
  (=check (format "~~") "~"))

(deftest format/~~-in-context
  (=check (format "cost: ~~a") "cost: ~a")
  (=check (format "100~~") "100~"))

; ── Multiple arguments ────────────────────────────────────────────────────────

(deftest format/multiple-args
  (=check (format "~a + ~a = ~a" 1 2 3) "1 + 2 = 3"))

(deftest format/mixed-directives
  (=check (format "~a (~s)~%" "hello" "hello") "hello (\"hello\")\n"))

; ── Edge cases ────────────────────────────────────────────────────────────────

(deftest format/empty-string
  (=check (format "") ""))

(deftest format/no-directives
  (=check (format "just plain text") "just plain text"))

(deftest format/only-text-around-args
  (=check (format "[~a]" 99) "[99]"))

; ── Error cases ───────────────────────────────────────────────────────────────

(deftest format/too-few-args
  (throws (format "~a and ~a" "only-one")))

(deftest format/unknown-directive
  (throws (format "~z")))

(deftest format/incomplete-directive-at-end
  (throws (format "oops~")))

(run-tests)
