; lib/orch/corpus.lisp — cross-file source resolution + cached embedding index.
;
; Turns the single-file explain pipeline into a multi-file one. Two jobs:
;
;   resolve-sources spec -> (ok (path ...)) | (err ...)
;     Auto-detects the spec: a file, a directory (recursive), a glob like
;     "dir/**/*.lisp", or ":repo" (recursive from CWD). follow-imports is
;     deferred to a later step.
;
;   build-index / build-index-with sources [embed-fn cache-path]
;     Chunk + embed every source into one vector store, backed by a PER-FILE
;     cache keyed on (mtime, size) — Zepo has no hash primitive. A cache hit
;     reuses a file's chunks + vectors with no embed call; a miss/stale file
;     is re-chunked and re-embedded. The cache is per-file so it is shared
;     across every query/spec over the tree. embed-fn is injected so the
;     cache logic is testable without Ollama.
;
; zepo-1j2

(module orch/corpus
  (export resolve-sources build-index build-index-with
          default-cache-path source-extensions)

  ;; zepo-y1a4: selective imports.
  (import orch/chunker      (chunk-file))
  (import orch/embed        (embed-text))
  (import orch/vector_store (make-store store-add!))

  (define default-cache-path ".zepo-index/cache.json")

  ; Extensions indexed in directory / :repo / bare-glob modes.
  (define source-extensions
    '(".lisp" ".zig" ".md" ".txt" ".py" ".js" ".ts" ".go" ".rs" ".c" ".h"))

  ; ── resolve-sources ───────────────────────────────────────────────────────

  (define (resolve-sources spec)
    (cond
      ((glob? spec)            (ok (resolve-glob spec)))
      ((string=? spec ":repo") (ok (walk (current-directory) keep-source?)))
      ((not (string? spec))    (err 'bad-spec "spec must be a string"))
      ((file-directory? spec)  (ok (walk spec keep-source?)))
      ((file-exists? spec)     (ok (list spec)))
      (else (err 'no-such-source (string-append "no file/dir: " spec)))))

  ; A glob is any spec containing "*". v1 is intentionally simple: take the
  ; longest leading path with no "*" as the base dir, the trailing "*.EXT" as
  ; an extension filter, and walk the base recursively. (Single-* vs ** is
  ; not distinguished; both recurse.)
  (define (glob? spec) (and (string? spec) (string-contains spec "*")))

  (define (resolve-glob spec)
    (let ((base (glob-base spec))
          (ext  (glob-ext spec)))
      (walk (if (string=? base "") "." base)
            (lambda (p) (if ext (has-extension? p ext) (keep-source? p))))))

  ; Longest leading path segment sequence with no "*".
  (define (glob-base spec)
    (let ((parts (string-split spec "/")))
      (let loop ((ps parts) (acc '()))
        (cond
          ((null? ps) (string-join (reverse acc) "/"))
          ((string-contains (car ps) "*") (string-join (reverse acc) "/"))
          (else (loop (cdr ps) (cons (car ps) acc)))))))

  ; Extension from a trailing "*.EXT" segment, or #f.
  (define (glob-ext spec)
    (let ((dot (last-index spec ".")))
      (and dot (substring spec dot (string-length spec)))))

  ; ── build-index ────────────────────────────────────────────────────────────

  (define (build-index sources)
    (build-index-with sources embed-one default-cache-path))

  ; The testable core. embed-fn : text -> (ok vec) | (err ...).
  ; Returns (ok store) | (err ...).
  (define (build-index-with sources embed-fn cache-path)
    (let ((cache (load-cache cache-path)))
      (let loop ((ss sources) (cache cache))
        (cond
          ((null? ss)
           (save-cache cache-path cache)
           (ok (assemble-store sources cache)))
          (else
            (let ((res (ensure-file (car ss) embed-fn cache)))
              (cond
                ((err? res) res)
                (else (loop (cdr ss) (result-value res))))))))))

  ; Ensure PATH's chunks+vectors are fresh in the cache; returns (ok cache').
  (define (ensure-file path embed-fn cache)
    (let ((stamp (file-stamp path))
          (entry (hash-get cache path)))
      (cond
        ((and entry (equal? (hash-get entry "stamp") stamp))
         (ok cache))                     ; cache hit — no embed
        (else
          (let ((built (chunk-and-embed path embed-fn)))
            (cond
              ((err? built) built)
              (else
                (let ((e (make-hash-table)))
                  (hash-set! e "stamp"  stamp)
                  (hash-set! e "chunks" (result-value built))
                  (hash-set! cache path e)
                  (ok cache)))))))))

  ; Chunk PATH and embed each chunk. Returns (ok (vector chunk-row ...))
  ; where chunk-row is a hash-table {id,text,path,line-start,line-end,kind,vec}.
  (define (chunk-and-embed path embed-fn)
    (let loop ((chunks (chunk-file path)) (rows '()))
      (cond
        ((null? chunks) (ok (list->vector (reverse rows))))
        (else
          (let* ((c   (car chunks))
                 (emb (embed-fn (kv c :text))))
            (cond
              ((err? emb) emb)
              (else
                (loop (cdr chunks)
                      (cons (chunk->row c (result-value emb)) rows)))))))))

  (define (chunk->row c vec)
    (let ((h (make-hash-table)))
      (hash-set! h "id"         (kv c :id))
      (hash-set! h "text"       (kv c :text))
      (hash-set! h "path"       (kv c :path))
      (hash-set! h "line-start" (kv c :line-start))
      (hash-set! h "line-end"   (kv c :line-end))
      (hash-set! h "vec"        vec)
      h))

  ; Build a fresh vector store from the cached chunk-rows of just `sources`.
  (define (assemble-store sources cache)
    (let ((s (make-store)))
      (for-each
        (lambda (path)
          (let ((entry (hash-get cache path)))
            (when entry
              (let ((rows (hash-get entry "chunks")))
                (let loop ((i 0))
                  (when (< i (vector-length rows))
                    (let ((row (vector-ref rows i)))
                      (store-add! s
                                  (hash-get row "id")
                                  (to-vec (hash-get row "vec"))
                                  row))
                    (loop (+ i 1))))))))
        sources)
      s))

  ; ── cache persistence ───────────────────────────────────────────────────────

  ; Cache = a JSON object: path -> {stamp, chunks:[row,...]}. Loaded as a
  ; hash-table tree by json-parse.
  (define (load-cache path)
    (cond
      ((not (file-exists? path)) (make-hash-table))
      (else
        (let ((parsed (json-parse (file-read-string path))))
          (if (and (ok? parsed) (hash-table? (result-value parsed)))
              (result-value parsed)
              (make-hash-table))))))

  (define (save-cache path cache)
    (let ((js (json-stringify cache)))
      (when (ok? js)
        (ensure-parent-dir path)
        (file-write-string path (result-value js)))))

  (define (ensure-parent-dir path)
    (let ((slash (last-index path "/")))
      (when slash
        (make-directory (substring path 0 slash)))))

  ; ── helpers ───────────────────────────────────────────────────────────────

  (define (embed-one text) (embed-text text))

  ; A cheap staleness key: "mtime-size". No hash primitive in Zepo.
  (define (file-stamp path)
    (string-append (number->string (or (file-mtime path) 0))
                   "-"
                   (number->string (or (file-size path) 0))))

  ; Recursively collect files under DIR for which (keep? path) is true.
  ; Skips dotfiles/dirs (.git, .zepo-index, ...).
  (define (walk dir keep?)
    (let loop ((entries (dir-entries dir)) (acc '()))
      (cond
        ((null? entries) acc)
        (else
          (let ((p (car entries)))
            (cond
              ((file-directory? p) (loop (cdr entries) (append (walk p keep?) acc)))
              ((keep? p)           (loop (cdr entries) (cons p acc)))
              (else                (loop (cdr entries) acc))))))))

  (define (dir-entries dir)
    (let ((acc '()))
      (for-each
        (lambda (name)
          (unless (string-prefix? "." name)
            (set! acc (cons (string-append dir "/" name) acc))))
        (directory-list dir))
      acc))

  (define (keep-source? path) (has-any-extension? path source-extensions))

  (define (has-any-extension? path exts)
    (cond
      ((null? exts) #f)
      ((has-extension? path (car exts)) #t)
      (else (has-any-extension? path (cdr exts)))))

  (define (has-extension? path ext) (string-suffix? ext path))

  ; alist (plist-style :key val) accessor used by chunk alists.
  (define (kv alist key)
    (let ((p (assoc key alist))) (and p (cdr p))))

  ; json-parse returns arrays as vectors already; guard hand-edited lists.
  (define (to-vec x) (if (vector? x) x (list->vector x)))

  ; Rightmost index of single-char string `ch` in s, or #f.
  (define (last-index s ch)
    (let loop ((i (- (string-length s) 1)))
      (cond
        ((< i 0) #f)
        ((char=? (string-ref s i) (string-ref ch 0)) i)
        (else (loop (- i 1)))))))
