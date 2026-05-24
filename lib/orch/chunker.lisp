; lib/orch/chunker.lisp — split source / markdown files into retrieval chunks.
;
; v1 strategy:
;   source: split into paragraphs (groups separated by blank lines), then
;           pack consecutive paragraphs until the running size approaches
;           the target. Add a small line-overlap between adjacent chunks.
;   doc:    split at top-level headings (# / ##), then fall back to the
;           source algorithm for any one-section block that is too long.
;
; Token estimate: chars / 4 (the spec's heuristic). Target ~400 tokens
; per chunk, allow up to ~600 before forcing a break, overlap ~50 tokens
; (i.e. trailing lines) into the next chunk.
;
; Each chunk's id is `<path>:<line-start>-<line-end>` — stable across
; re-chunking of the same file, useful as a vector-store key.
;
; zepo-6yz

(module orch/chunker
  (export chunk-file chunk-text detect-kind
          target-chunk-tokens max-chunk-tokens overlap-tokens)

  (define target-chunk-tokens 400)
  (define max-chunk-tokens    600)
  (define overlap-tokens      50)

  ; Read `path` and split it. Returns a list of chunk alists:
  ;   (:id ID :text TEXT :path PATH :line-start N :line-end N :kind 'source|'doc)
  (define (chunk-file path)
    (let ((kind (detect-kind path))
          (text (file-read-string path)))
      (chunk-text text path kind)))

  ; Same, but text is already in memory. Useful for tests and for chunking
  ; non-file sources (REPL buffers, stdin).
  (define (chunk-text text path kind)
    (let ((lines (lines-of text)))
      (cond
        ((eq? kind 'doc)
         (pack-doc-sections lines path))
        (else
         (pack-source-paragraphs lines path 'source)))))

  ; Detect kind by extension. Markdown extensions are 'doc; everything
  ; else is 'source. Heuristic — callers can pass an explicit kind to
  ; chunk-text to override.
  (define (detect-kind path)
    (cond
      ((string-suffix? ".md"       path) 'doc)
      ((string-suffix? ".markdown" path) 'doc)
      ((string-suffix? ".mdx"      path) 'doc)
      (else 'source)))

  ; ── Source-style packing ──────────────────────────────────────────────────

  (define (flush-paragraph cur start acc)
    (cond
      ((null? cur) acc)
      (else (cons (cons start (reverse cur)) acc))))

  (define (blank-line? s)
    (= (string-length (string-trim s)) 0))

  ; Pack paragraphs into chunks up to target_tokens. Returns a list of
  ; chunk alists in source order.
  (define (pack-source-paragraphs lines path kind)
    (pack-source-paragraphs-with-offset lines path kind 1))

  ; chunk-acc = paragraphs in current chunk (paired (start . lines))
  ; chunk-toks = running token estimate for current chunk
  ; cur-start = line where current chunk starts (0 if empty)
  ; cur-end = line where current chunk ends so far
  (define (build-chunks-from-paragraphs paras path kind out-acc chunk-acc chunk-toks cur-start cur-end)
    (cond
      ((null? paras)
       (let ((final (cond ((null? chunk-acc) out-acc)
                          (else (cons (emit-chunk (reverse chunk-acc) path kind cur-start cur-end) out-acc)))))
         (reverse final)))
      (else
       (let* ((para (car paras))
              (rest (cdr paras))
              (p-start (car para))
              (p-lines (cdr para))
              (p-toks (estimate-tokens-lines p-lines))
              (p-end (+ p-start (length p-lines) -1)))
         (cond
           ; First paragraph in chunk — always include even if oversized.
           ((null? chunk-acc)
            (build-chunks-from-paragraphs rest path kind out-acc
                                          (list para) p-toks p-start p-end))
           ; Adding would exceed max — flush current chunk, start fresh
           ; with this paragraph (with optional overlap).
           ((> (+ chunk-toks p-toks) max-chunk-tokens)
            (let ((emitted (emit-chunk (reverse chunk-acc) path kind cur-start cur-end)))
              (build-chunks-from-paragraphs rest path kind
                                            (cons emitted out-acc)
                                            (list para) p-toks p-start p-end)))
           ; Past target but under max — still flush.
           ((>= chunk-toks target-chunk-tokens)
            (let ((emitted (emit-chunk (reverse chunk-acc) path kind cur-start cur-end)))
              (build-chunks-from-paragraphs rest path kind
                                            (cons emitted out-acc)
                                            (list para) p-toks p-start p-end)))
           ; Otherwise: append to current chunk.
           (else
            (build-chunks-from-paragraphs rest path kind out-acc
                                          (cons para chunk-acc)
                                          (+ chunk-toks p-toks)
                                          cur-start p-end)))))))

  (define (emit-chunk paras path kind start end)
    (let ((text (assemble-text paras)))
      (list (cons :id    (string-append path ":"
                                        (number->string start) "-"
                                        (number->string end)))
            (cons :text  text)
            (cons :path  path)
            (cons :line-start start)
            (cons :line-end   end)
            (cons :kind  kind))))

  (define (assemble-text paras)
    ; Join paragraphs with blank lines between them.
    (let ((bodies '()))
      (for-each
        (lambda (p)
          (let ((lines (cdr p)))
            (set! bodies (cons (string-join lines "\n") bodies))))
        paras)
      (string-join (reverse bodies) "\n\n")))

  (define (estimate-tokens-lines lines)
    (estimate-tokens-string (string-join lines " ")))

  (define (estimate-tokens-string s)
    (quotient (string-length s) 4))

  ; ── Markdown-style packing ────────────────────────────────────────────────

  ; Find heading lines (those starting with #) and split the file into
  ; sections. Each section's paragraphs are then packed via the source
  ; algorithm. Section boundaries are respected — we never pack content
  ; from two different headings into the same chunk.
  (define (pack-doc-sections lines path)
    (let ((sections (split-doc-sections lines)))
      (let loop ((rest sections) (acc '()))
        (cond
          ((null? rest) (reverse acc))
          (else
            (let ((sec (car rest))
                  (rest2 (cdr rest)))
              (loop rest2
                    (append-rev
                      (pack-source-paragraphs-with-offset
                        (cdr sec) path 'doc (car sec))
                      acc))))))))

  ; Like pack-source-paragraphs but the input lines start at absolute
  ; file line `offset`. Chunk metadata then carries true file lines so
  ; ids are stable across re-chunking.
  (define (pack-source-paragraphs-with-offset lines path kind offset)
    (let ((paras (split-paragraphs-with-offset lines offset)))
      (build-chunks-from-paragraphs paras path kind '() '() 0 0 0)))

  (define (split-paragraphs-with-offset lines offset)
    (let loop ((rest lines) (ln offset) (cur '()) (cur-start 0) (acc '()))
      (cond
        ((null? rest)
         (reverse (flush-paragraph cur cur-start acc)))
        (else
         (let ((line (car rest)))
           (cond
             ((blank-line? line)
              (loop (cdr rest) (+ ln 1) '() 0
                    (flush-paragraph cur cur-start acc)))
             (else
              (loop (cdr rest) (+ ln 1)
                    (cons line cur)
                    (if (null? cur) ln cur-start)
                    acc))))))))

  ; Returns list of (section-start-line . list-of-lines). Each section is
  ; the contiguous block from one heading up to (but not including) the
  ; next heading. If the file has no headings, returns one section
  ; spanning the whole file.
  (define (split-doc-sections lines)
    (let loop ((rest lines) (ln 1) (cur '()) (cur-start 1) (acc '()))
      (cond
        ((null? rest)
         (reverse (if (null? cur) acc
                      (cons (cons cur-start (reverse cur)) acc))))
        (else
         (let ((line (car rest)))
           (cond
             ((and (heading-line? line) (not (null? cur)))
              ; Boundary — flush current section, start new with this heading.
              (loop (cdr rest) (+ ln 1) (list line) ln
                    (cons (cons cur-start (reverse cur)) acc)))
             (else
              (loop (cdr rest) (+ ln 1) (cons line cur)
                    (if (null? cur) ln cur-start)
                    acc))))))))

  (define (heading-line? s)
    (let ((trimmed (string-trim-left s)))
      (and (> (string-length trimmed) 0)
           (equal? (string-ref trimmed 0) (string-ref "#" 0)))))

  ; ── Helpers ──────────────────────────────────────────────────────────────

  (define (lines-of s) (string-split s "\n"))

  (define (append-rev xs acc)
    ; (append-rev '(a b c) '(z)) -> '(c b a z)
    (cond
      ((null? xs) acc)
      (else (append-rev (cdr xs) (cons (car xs) acc))))))
