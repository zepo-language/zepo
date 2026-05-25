; lib/orch/gitsignals.lisp — structural signals from git history.
;
; code-spider-style signals for reranking retrieval:
;   co-change — files changed together (weight = #commits together)
;   hotspot   — churn+size importance: 0.6*(churn/maxChurn) + 0.4*(loc/maxLoc)
;
; The PARSING (git-log text -> commits -> pairs/churn) is pure and offline-
; testable; the live `git log` call is read-only. Built at index time and
; persisted to .zepo-index/gitsignals.json. zepo-4cr.

(module orch/gitsignals
  (export parse-commits churn-counts churn-of cochange-counts cochange-of
          hotspot-score build-git-signals save-git-signals load-git-signals
          signals-cochange signals-churn signals-hotspot hotspot-of)

  ; ── pure parsing ────────────────────────────────────────────────────────────

  ; Parse `git log --name-only --format=@@@%H` output into a list of commits,
  ; each a list of changed file paths.
  ; Note: Zepo treats '() as falsy, so we cannot use the in-progress file list
  ; as a truthiness flag — track "are we in a commit yet?" via (null? commits).
  ; commits is newest-first, each commit's files newest-first; reversed at end.
  (define (parse-commits text)
    (let loop ((lines (string-split text "\n")) (commits '()))
      (cond
        ((null? lines) (reverse (map reverse commits)))
        (else
          (let ((ln (car lines)))
            (cond
              ((string-prefix? "@@@" ln) (loop (cdr lines) (cons '() commits)))
              ((string=? ln "")          (loop (cdr lines) commits))
              ((null? commits)           (loop (cdr lines) commits))   ; file before any @@@
              (else (loop (cdr lines)
                          (cons (cons ln (car commits)) (cdr commits))))))))))

  ; file -> #commits it appears in.
  (define (churn-counts commits)
    (let ((h (make-hash-table)))
      (for-each
        (lambda (files)
          (for-each (lambda (f) (hash-set! h f (+ 1 (hash-or h f 0)))) files))
        commits)
      h))

  (define (churn-of h f) (hash-or h f 0))

  ; sorted file-pair -> #commits both appear in.
  (define (cochange-counts commits)
    (let ((h (make-hash-table)))
      (for-each
        (lambda (files)
          (let loop ((fs files))
            (cond
              ((or (null? fs) (null? (cdr fs))) #t)
              (else
                (for-each
                  (lambda (g)
                    (let ((k (pair-key (car fs) g)))
                      (hash-set! h k (+ 1 (hash-or h k 0)))))
                  (cdr fs))
                (loop (cdr fs))))))
        commits)
      h))

  (define (cochange-of h a b) (hash-or h (pair-key a b) 0))

  (define (hotspot-score churn loc maxchurn maxloc)
    (+ (* 0.6 (safe-div churn maxchurn))
       (* 0.4 (safe-div loc maxloc))))

  ; ── live build + persistence ──────────────────────────────────────────────────

  ; Run git log (read-only) under `root`, parse, and compute churn / co-change /
  ; hotspot over `sources`. Returns a signals record: #(cochange churn hotspot).
  (define (build-git-signals root sources)
    (let* ((commits (parse-commits (git-log-text root)))
           (churn   (churn-counts commits))
           (cc      (cochange-counts commits))
           (hot     (compute-hotspots churn sources)))
      (vector cc churn hot)))

  (define (signals-cochange s) (vector-ref s 0))
  (define (signals-churn    s) (vector-ref s 1))
  (define (signals-hotspot  s) (vector-ref s 2))
  (define (hotspot-of s file) (hash-or (signals-hotspot s) file 0.0))

  (define (git-log-text root)
    (shell (string-append "cd '" root "' && git log --name-only --format=@@@%H")))

  (define (compute-hotspots churn sources)
    (let ((maxchurn (max-hash-val churn 1))
          (locs     (make-hash-table)))
      (for-each (lambda (f) (hash-set! locs f (loc-of f))) sources)
      (let ((maxloc (max-hash-val locs 1))
            (hot    (make-hash-table)))
        (for-each
          (lambda (f)
            (hash-set! hot f
                       (hotspot-score (churn-of churn f) (hash-or locs f 0)
                                      maxchurn maxloc)))
          sources)
        hot)))

  (define (loc-of path)
    (let ((p (open-input-file path)))
      (let loop ((line (read-line p)) (n 0))
        (if (eof-object? line) (begin (close-input-port p) n)
            (loop (read-line p) (+ n 1))))))

  ; Persist/restore the three hashes as one JSON object.
  (define (save-git-signals s path)
    (let ((wrap (make-hash-table)))
      (hash-set! wrap "cochange" (signals-cochange s))
      (hash-set! wrap "churn"    (signals-churn s))
      (hash-set! wrap "hotspot"  (signals-hotspot s))
      (let ((js (json-stringify wrap)))
        (when (ok? js) (file-write-string path (result-value js))))))

  (define (load-git-signals path)
    (let ((p (json-parse (file-read-string path))))
      (if (and (ok? p) (hash-table? (result-value p)))
          (let ((w (result-value p)))
            (vector (hash-or w "cochange" (make-hash-table))
                    (hash-or w "churn"    (make-hash-table))
                    (hash-or w "hotspot"  (make-hash-table))))
          (vector (make-hash-table) (make-hash-table) (make-hash-table)))))

  ; ── helpers ───────────────────────────────────────────────────────────────────

  (define (pair-key a b)
    (if (string<? a b) (string-append a "\t" b) (string-append b "\t" a)))

  (define (hash-or h k d) (if (hash-contains? h k) (hash-get h k) d))

  (define (safe-div a b)
    (if (= b 0) 0.0 (/ (exact->inexact a) b)))

  (define (max-hash-val h floor)
    (let ((m floor))
      (hash-for-each (lambda (k v) (when (> v m) (set! m v))) h)
      m)))
