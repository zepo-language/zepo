; lib/orch/symbols.lisp — symbol index (defs/refs) for Zepo source.
;
; Foundation of the structural-signals layer. Extracts definition sites from
; corpus source and answers find-def / find-refs precisely — deterministic and
; model-free, the basis for real cross-reference chasing in the research loop.
;
; Identifier-aware: Zepo identifiers include - _ ! ? * + < > = / . : etc., so
; matching is on WHOLE identifiers, never substrings ("run" must not match
; "run-parallel"). v1: lexical, no scope resolution. Lisp source only.
;
; zepo-6vo

(module orch/symbols
  (export build-symbol-index find-def find-refs)

  ; build-symbol-index sources -> hash-table name(string) -> list of (file . line)
  ; for each (define (NAME ...) / (define NAME ...) site, in file order.
  (define (build-symbol-index sources)
    (let ((idx (make-hash-table)))
      (for-each (lambda (path) (index-file path idx)) sources)
      idx))

  (define (index-file path idx)
    (let ((p (open-input-file path)))
      (let loop ((line (read-line p)) (n 1))
        (cond
          ((eof-object? line) (close-input-port p))
          (else
            (let ((name (extract-def-name line)))
              (when name
                (hash-set! idx name
                           (cons (cons path n)
                                 (if (hash-contains? idx name) (hash-get idx name) '())))))
            (loop (read-line p) (+ n 1)))))))

  ; find-def name idx -> list of (file . line) definition sites (file order).
  (define (find-def name idx)
    (if (hash-contains? idx name) (reverse (hash-get idx name)) '()))

  ; find-refs name sources -> list of (file . line) for lines containing a
  ; WHOLE-identifier occurrence of name (includes the def line itself).
  (define (find-refs name sources)
    (let loop ((ss sources) (out '()))
      (cond
        ((null? ss) (reverse out))
        (else (loop (cdr ss) (refs-in-file name (car ss) out))))))

  (define (refs-in-file name path out)
    (let ((p (open-input-file path)))
      (let loop ((line (read-line p)) (n 1) (out out))
        (cond
          ((eof-object? line) (close-input-port p) out)
          ((whole-occurrence? line name) (loop (read-line p) (+ n 1) (cons (cons path n) out)))
          (else (loop (read-line p) (+ n 1) out))))))

  ; ── parsing helpers ─────────────────────────────────────────────────────────

  ; A line "(define (NAME ...)" or "(define NAME ...)" -> NAME, else #f.
  (define (extract-def-name line)
    (let ((n (string-length line)))
      (let ((i (skip-ws line 0 n)))
        (cond
          ((not (starts-with? line i "(define")) #f)
          ((not (and (< (+ i 7) n) (ws? (string-ref line (+ i 7))))) #f)
          (else
            (let* ((j (skip-ws line (+ i 7) n))
                   (k (if (and (< j n) (char=? (string-ref line j) #\())
                          (skip-ws line (+ j 1) n)
                          j)))
              (read-id line k n)))))))

  ; Does `name` occur in `line` bounded by non-identifier chars (or edges)?
  (define (whole-occurrence? line name)
    (let ((nl (string-length name))
          (ll (string-length line)))
      (let loop ((start 0))
        (cond
          ((>= start ll) #f)
          (else
            (let ((rel (string-contains (substring line start) name)))
              (cond
                ((not rel) #f)
                (else
                  (let ((p (+ start rel)))
                    (if (and (boundary? line (- p 1)) (boundary? line (+ p nl)))
                        #t
                        (loop (+ p 1))))))))))))

  (define (boundary? line i)
    (or (< i 0) (>= i (string-length line)) (not (id-char? (string-ref line i)))))

  ; read a run of identifier chars from index i; returns the substring or #f.
  (define (read-id s i n)
    (let loop ((j i))
      (cond
        ((and (< j n) (id-char? (string-ref s j))) (loop (+ j 1)))
        ((> j i) (substring s i j))
        (else #f))))

  (define (skip-ws s i n)
    (cond
      ((>= i n) n)
      ((ws? (string-ref s i)) (skip-ws s (+ i 1) n))
      (else i)))

  (define (starts-with? s i prefix)
    (let ((pl (string-length prefix)) (sl (string-length s)))
      (and (<= (+ i pl) sl)
           (string=? (substring s i (+ i pl)) prefix))))

  (define (ws? c)
    (or (char=? c #\space) (char=? c #\tab) (char=? c #\newline) (char=? c #\return)))

  (define id-extra (list #\- #\_ #\! #\? #\* #\+ #\< #\> #\= #\/ #\. #\: #\% #\& #\^ #\~))

  (define (id-char? c)
    (or (and (char>=? c #\a) (char<=? c #\z))
        (and (char>=? c #\A) (char<=? c #\Z))
        (and (char>=? c #\0) (char<=? c #\9))
        (and (member c id-extra) #t))))
