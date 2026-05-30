;; zepo-e6o9: snapshot assertion tests.
;;
;; Covers four scenarios for (=snapshot value :name PATH):
;;   1. First run creates the snapshot file.
;;   2. Re-run with matching content reports PASS.
;;   3. Hand-edited (wrong) snapshot reports FAIL with a diff.
;;   4. With (run! :update-snapshots #t) a mismatching snapshot is overwritten
;;      and the test passes.

(import testing
  (describe it deftest is =snapshot =check
   run! result-passed result-failed result-failures
   clear-tests!))

(define fixture-dir "/tmp/zepo-snap-fixture")
(define snap-a (string-append fixture-dir "/case-a.snap"))
(define snap-b (string-append fixture-dir "/case-b.snap"))
(define snap-c (string-append fixture-dir "/case-c.snap"))

;; ── Helpers ──────────────────────────────────────────────────────────────

(define (clean!)
  (if (file-exists? snap-a) (file-delete snap-a))
  (if (file-exists? snap-b) (file-delete snap-b))
  (if (file-exists? snap-c) (file-delete snap-c)))

(clean!)
;; Make sure the directory exists so file-write-string in the impl has a
;; chance — ensure-parent-dir! also handles this, but creating it up front
;; avoids relying on that detail.
(make-directory fixture-dir)

;; ── Scenario 1: first run creates the file ───────────────────────────────

(clear-tests!)
(describe "snapshot-create"
  (it "writes a fresh snapshot file"
    (=snapshot (list 1 2 3) :name snap-a)))

(define r1 (run! :silent #t))
(if (not (= (result-passed r1) 1))
    (error "scenario 1: expected 1 pass, got" (result-passed r1)))
(if (not (file-exists? snap-a))
    (error "scenario 1: snapshot file not created at" snap-a))
(if (not (string=? (file-read-string snap-a) "(1 2 3)"))
    (error "scenario 1: snapshot file content unexpected:" (file-read-string snap-a)))
(display "scenario 1 OK — first run created snapshot") (newline)

;; ── Scenario 2: second run reproduces and passes ─────────────────────────

(clear-tests!)
(describe "snapshot-match"
  (it "matches the existing snapshot"
    (=snapshot (list 1 2 3) :name snap-a)))

(define r2 (run! :silent #t))
(if (not (= (result-passed r2) 1))
    (error "scenario 2: expected 1 pass, got" (result-passed r2)
           "failures:" (result-failures r2)))
(if (not (= (result-failed r2) 0))
    (error "scenario 2: expected 0 fail, got" (result-failed r2)))
(display "scenario 2 OK — replay matched") (newline)

;; ── Scenario 3: hand-edit the file, expect FAIL ──────────────────────────

(file-write-string snap-a "(9 9 9)")
(clear-tests!)
(describe "snapshot-mismatch"
  (it "fails when the stored snapshot drifts"
    (=snapshot (list 1 2 3) :name snap-a)))

(define r3 (run! :silent #t))
(if (not (= (result-failed r3) 1))
    (error "scenario 3: expected 1 fail, got" (result-failed r3)))
;; Inspect the failure message to confirm it surfaces the path and the diff.
(define fail-msg (cdr (car (result-failures r3))))
(define (substring? haystack needle)
  (let ((hl (string-length haystack))
        (nl (string-length needle)))
    (if (> nl hl) #f
        (let loop ((i 0))
          (cond
            ((> (+ i nl) hl) #f)
            ((string=? (substring haystack i (+ i nl)) needle) #t)
            (#t (loop (+ i 1))))))))
(if (not (substring? fail-msg "snapshot mismatch"))
    (error "scenario 3: message missing 'snapshot mismatch':" fail-msg))
(if (not (substring? fail-msg snap-a))
    (error "scenario 3: message missing path:" fail-msg))
(display "scenario 3 OK — mismatch raised FAIL with diff") (newline)

;; ── Scenario 4: :update-snapshots #t rewrites a wrong file ───────────────

;; The file from scenario 3 still has "(9 9 9)" — perfect starting state.
(if (not (string=? (file-read-string snap-a) "(9 9 9)"))
    (error "scenario 4 precondition: file should still be drifted"))

(clear-tests!)
(describe "snapshot-update"
  (it "overwrites a drifted snapshot when :update-snapshots #t"
    (=snapshot (list 1 2 3) :name snap-a)))

(define r4 (run! :silent #t :update-snapshots #t))
(if (not (= (result-passed r4) 1))
    (error "scenario 4: expected 1 pass, got" (result-passed r4)
           "failures:" (result-failures r4)))
(if (not (string=? (file-read-string snap-a) "(1 2 3)"))
    (error "scenario 4: file not rewritten, got:" (file-read-string snap-a)))
(display "scenario 4 OK — :update-snapshots #t rewrote drifted file") (newline)

;; ── Scenario 5: default :name uses the current test path ─────────────────
;; Lightweight extra: smoke-test the default-path branch by passing no
;; :name, then asserting the slug file lives in .zepo-snapshots/.

(clear-tests!)
(describe "snapshot-default-name"
  (it "uses test path slug when :name is omitted"
    (=snapshot (list 'alpha 'beta))))
(define default-snap-path
  ".zepo-snapshots/snapshot-default-name--uses-test-path-slug-when--name-is-omitted.snap")
(if (file-exists? default-snap-path) (file-delete default-snap-path))
(define r5 (run! :silent #t))
(if (not (= (result-passed r5) 1))
    (error "scenario 5: expected 1 pass, got" (result-passed r5)
           "failures:" (result-failures r5)))
(if (not (file-exists? default-snap-path))
    (error "scenario 5: default snapshot path missing:" default-snap-path))
;; Clean up so the repo doesn't accumulate snapshot dust.
(file-delete default-snap-path)

(display "scenario 5 OK — default :name path resolved from test context") (newline)

(clean!)
(display "snapshot tests OK") (newline)
