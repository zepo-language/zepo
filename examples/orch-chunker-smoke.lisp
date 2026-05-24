; orch-chunker-smoke.lisp — manual smoke for lib/orch/chunker.lisp.
;
; Chunks the worker-pool example (small source file) and the README
; (longer markdown), prints chunk counts + sample metadata. Verifies
; the source/doc kind detection, absolute line numbering, and stable
; id format.
;
; Run:
;   zepo examples/orch-chunker-smoke.lisp
;
; zepo-6yz

(import :libs (orch/chunker))

(define (assert label cond-true)
  (cond
    (cond-true (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label) (newline) (exit 1))))

; --- detect-kind ---------------------------------------------------------------
(assert "md is doc"     (eq? 'doc    (detect-kind "README.md")))
(assert "markdown is doc"(eq? 'doc   (detect-kind "x.markdown")))
(assert "lisp is source"(eq? 'source (detect-kind "examples/worker-pool.lisp")))
(assert "zig is source" (eq? 'source (detect-kind "src/foo.zig")))

; --- source chunking on worker-pool.lisp --------------------------------------
(define src-chunks (chunk-file "examples/worker-pool.lisp"))
(assert "src non-empty" (> (length src-chunks) 0))
(let ((c (car src-chunks)))
  (assert "src kind"       (eq? 'source (cdr (assoc :kind c))))
  (assert "src has text"   (string? (cdr (assoc :text c))))
  (assert "src has id"     (string? (cdr (assoc :id c))))
  (assert "src id format"  (string-contains (cdr (assoc :id c)) ":"))
  (assert "src starts ≥1"  (>= (cdr (assoc :line-start c)) 1))
  (assert "src end ≥ start"
          (>= (cdr (assoc :line-end c)) (cdr (assoc :line-start c)))))

; --- markdown chunking on README.md -------------------------------------------
(define doc-chunks (chunk-file "README.md"))
(assert "doc multi-chunk" (> (length doc-chunks) 5))
(let ((c (car doc-chunks)))
  (assert "doc kind" (eq? 'doc (cdr (assoc :kind c)))))

; Absolute line numbers across sections monotonic
(define lines-monotonic? #t)
(let loop ((rest doc-chunks) (prev 0))
  (cond
    ((null? rest) #t)
    (else
      (let ((c (car rest)))
        (let ((s (cdr (assoc :line-start c))))
          (when (< s prev) (set! lines-monotonic? #f))
          (loop (cdr rest) s))))))
(assert "doc lines monotonic" lines-monotonic?)

; --- stability: re-chunking gives same ids ------------------------------------
(define rechunked (chunk-file "README.md"))
(define ids-match? #t)
(let loop ((a doc-chunks) (b rechunked))
  (cond
    ((and (null? a) (null? b)) #t)
    ((or (null? a) (null? b)) (set! ids-match? #f))
    (else
      (when (not (equal? (cdr (assoc :id (car a)))
                          (cdr (assoc :id (car b)))))
        (set! ids-match? #f))
      (loop (cdr a) (cdr b)))))
(assert "rechunking stable" ids-match?)

(display "all checks passed.") (newline)
(display "(source chunks: ") (display (length src-chunks))
(display ", doc chunks: ")    (display (length doc-chunks))
(display ")") (newline)
