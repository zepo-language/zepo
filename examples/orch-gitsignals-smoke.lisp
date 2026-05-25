; orch-gitsignals-smoke.lisp — offline tests for lib/orch/gitsignals.lisp (zepo-4cr).
;
; Structural signals from git history: co-change (files changed together) and
; hotspot (churn+size importance), mirroring code-spider. The PARSING
; (git-log-text -> commits -> pairs/churn) is pure, tested here with sample
; log text — no git needed.
;
; Run:
;   zepo examples/orch-gitsignals-smoke.lisp
;
; zepo-4cr

(import :libs (orch/gitsignals))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want) (display " got=") (display got) (newline)
          (exit 1))))

; `git log --name-only --format=@@@%H` shape: a @@@<hash> line per commit,
; then the changed files, then a blank line.
(define sample
  (string-append
    "@@@h1\na.lisp\nb.lisp\n\n"
    "@@@h2\nb.lisp\nc.lisp\n\n"
    "@@@h3\na.lisp\nb.lisp\n"))

(define commits (parse-commits sample))
(assert-eq "3 commits parsed" 3 (length commits))

(define churn (churn-counts commits))
(assert-eq "churn a.lisp" 2 (churn-of churn "a.lisp"))
(assert-eq "churn b.lisp" 3 (churn-of churn "b.lisp"))
(assert-eq "churn c.lisp" 1 (churn-of churn "c.lisp"))
(assert-eq "churn unknown" 0 (churn-of churn "z.lisp"))

(define cc (cochange-counts commits))
(assert-eq "co-change a/b"   2 (cochange-of cc "a.lisp" "b.lisp"))
(assert-eq "co-change b/a (symmetric)" 2 (cochange-of cc "b.lisp" "a.lisp"))
(assert-eq "co-change b/c"   1 (cochange-of cc "b.lisp" "c.lisp"))
(assert-eq "co-change a/c"   0 (cochange-of cc "a.lisp" "c.lisp"))

; hotspot = 0.6*(churn/maxChurn) + 0.4*(loc/maxLoc)
; churn 3 of max 3, loc 50 of max 100 -> 0.6*1 + 0.4*0.5 = 0.8
(assert-eq "hotspot formula" 0.8 (hotspot-score 3 50 3 100))
(assert-eq "hotspot max"     1.0 (hotspot-score 10 100 10 100))

(display "all checks passed.") (newline)
