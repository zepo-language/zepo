; orch-corpus-smoke.lisp — offline smoke for lib/orch/corpus.lisp.
;
; Covers resolve-sources (file / directory / glob / :repo) and the per-file
; incremental embedding cache via an INJECTED stub embedder, so no Ollama is
; needed: first build embeds each file once; an unchanged rebuild embeds
; nothing; a changed file is re-embedded.
;
; Run:
;   zepo examples/orch-corpus-smoke.lisp
;
; zepo-1j2

(import :libs (orch/vector_store (store-size) ; zepo-y1a4
               orch/corpus       (resolve-sources build-index-with)))

(define tree  "/tmp/zepo-1j2-tree")
(define cache "/tmp/zepo-1j2-cache.json")
(shell (string-append
         "rm -rf " tree " " cache " && mkdir -p " tree "/sub && "
         "printf 'alpha one\\nalpha two\\n'   > " tree "/a.lisp && "
         "printf 'beta one\\nbeta two\\n'     > " tree "/sub/b.lisp && "
         "printf 'binary\\n'                  > " tree "/c.png"))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want)
          (display " got=") (display got) (newline)
          (exit 1))))

; --- resolve-sources: single file ---
(let ((r (resolve-sources (string-append tree "/a.lisp"))))
  (assert-eq "single file ok"    #t (ok? r))
  (assert-eq "single file count" 1  (length (result-value r))))

; --- resolve-sources: directory, recursive, extension-filtered ---
; finds a.lisp + sub/b.lisp; excludes c.png
(let ((r (resolve-sources tree)))
  (assert-eq "dir ok"          #t (ok? r))
  (assert-eq "dir lisp count"  2  (length (result-value r))))

; --- resolve-sources: glob (base dir + extension, recursive) ---
(let ((r (resolve-sources (string-append tree "/**/*.lisp"))))
  (assert-eq "glob ok"         #t (ok? r))
  (assert-eq "glob lisp count" 2  (length (result-value r))))

; --- build-index cache: first build embeds, rebuild reuses, change re-embeds ---
(define embed-calls (vector 0))
(define (stub-embed text)
  (vector-set! embed-calls 0 (+ (vector-ref embed-calls 0) 1))
  (ok (vector 1.0 0.0 0.0)))

(define sources (result-value (resolve-sources tree)))   ; a.lisp + sub/b.lisp

(vector-set! embed-calls 0 0)
(define build1 (build-index-with sources stub-embed cache))
(assert-eq "build1 ok"        #t (ok? build1))
(assert-eq "build1 embedded"  #t (> (vector-ref embed-calls 0) 0))
(define n1 (vector-ref embed-calls 0))

; same tree, unchanged -> cache hit, ZERO embed calls
(vector-set! embed-calls 0 0)
(build-index-with sources stub-embed cache)
(assert-eq "unchanged rebuild = 0 embeds" 0 (vector-ref embed-calls 0))

; change a.lisp -> only it is re-embedded
(shell (string-append "printf 'alpha CHANGED now longer line\\nmore\\n' > " tree "/a.lisp"))
(vector-set! embed-calls 0 0)
(define build3 (build-index-with sources stub-embed cache))
(assert-eq "changed file re-embedded"      #t (> (vector-ref embed-calls 0) 0))
(assert-eq "only changed file re-embedded" #t (< (vector-ref embed-calls 0) n1))

; --- the assembled store holds chunks from BOTH files ---
(assert-eq "store indexes multiple files" #t (>= (store-size (result-value build3)) 2))

(display "all checks passed.") (newline)
