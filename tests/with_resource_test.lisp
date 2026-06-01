;; zepo-qqzm: unwind-protect + with-X resource macros.
(import test (deftest is =check throws run-tests))

; ── unwind-protect ──────────────────────────────────────────────────────────────

(deftest unwind-protect/returns-body-value
  (=check (unwind-protect 42 'cleanup) 42))

(deftest unwind-protect/cleanup-on-normal-exit
  (=check
    (let ((log '()))
      (unwind-protect (set! log (cons 'body log)) (set! log (cons 'cleanup log)))
      (reverse log))
    '(body cleanup)))

(deftest unwind-protect/cleanup-on-error
  (=check
    (let ((log '()))
      (guard (e (#t (set! log (cons 'caught log))))
        (unwind-protect (begin (set! log (cons 'body log)) (error "boom"))
          (set! log (cons 'cleanup log))))
      (reverse log))
    '(body cleanup caught)))

(deftest unwind-protect/reraises-after-cleanup
  (=check (guard (e (#t (list 'got e))) (unwind-protect (raise 'x) 'cleanup))
          '(got x)))

; ── with-output-string ─────────────────────────────────────────────────────────

(deftest with-output-string/collects
  (=check
    (with-output-string (p) (port-display p "x = ") (port-write p 42))
    "x = 42"))

(deftest with-output-string/empty
  (=check (with-output-string (p) #t) ""))

; ── with-temp-file ──────────────────────────────────────────────────────────────

(deftest with-temp-file/readable-in-body
  (=check
    (with-temp-file (p) (file-write-string p "hi") (file-read-string p))
    "hi"))

(deftest with-temp-file/deleted-after
  (is (let ((saved #f))
        (with-temp-file (p) (set! saved p) (file-write-string p "x"))
        (not (file-exists? saved)))))

(deftest with-temp-file/deleted-even-on-error
  (is (let ((saved #f))
        (guard (e (#t #t))
          (with-temp-file (p)
            (set! saved p)
            (file-write-string p "x")
            (error "boom")))
        (not (file-exists? saved)))))

(run-tests)
