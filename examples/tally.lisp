; tally.lisp — word/line/char counter, demonstrating clap 2.0.
;
; Run:
;   zepo examples/tally.lisp -- lines README.md
;   zepo examples/tally.lisp -- all README.md --format json
;   zepo examples/tally.lisp -- all README.md LICENSE --limit 1
;   TALLY_FORMAT=csv zepo examples/tally.lisp -- words README.md
;   zepo examples/tally.lisp -- docs

(import clap)
(import format)

;;; ── Counting primitives ────────────────────────────────────────────────────

(define (count-lines text)
  (length (string-split text "\n")))

(define (count-words text)
  ; split each line on spaces, flatten, drop empty tokens
  (fold-left (lambda (acc line)
               (+ acc (length (filter (lambda (w) (not (string=? w "")))
                                      (string-split line " ")))))
             0
             (string-split text "\n")))

(define (count-chars text)
  (string-length text))

(define (tally-file path)
  (let ((text (file-read-string path)))
    (list :path  path
          :lines (count-lines text)
          :words (count-words text)
          :chars (count-chars text))))

;;; ── Output formatters ──────────────────────────────────────────────────────

(define (fmt-text rows fields)
  ; column widths: max of header and each value
  (define (col-width field)
    (fold-left (lambda (mx row)
                 (let ((v (number->string (plist-get row field))))
                   (if (> (string-length v) mx) (string-length v) mx)))
               (string-length (symbol->string field))
               rows))
  (let* ((path-w  (fold-left (lambda (mx r)
                                (let ((l (string-length (plist-get r :path))))
                                  (if (> l mx) l mx)))
                              4 rows))
         (widths  (map col-width fields))
         (header  (string-append
                    (string-pad-right "file" path-w #\space) "  "
                    (string-join (map (lambda (fw)
                                        (string-pad-right (symbol->string (car fw)) (cadr fw) #\space))
                                      (zip fields widths))
                                 "  ")))
         (sep     (string-append (string-repeat "-" path-w) "  "
                                 (string-join (map (lambda (w) (string-repeat "-" w)) widths) "  ")))
         (lines   (map (lambda (row)
                         (string-append
                           (string-pad-right (plist-get row :path) path-w #\space) "  "
                           (string-join (map (lambda (fw)
                                               (string-pad-left (number->string (plist-get row (car fw)))
                                                                (cadr fw) #\space))
                                             (zip fields widths))
                                        "  ")))
                       rows)))
    (string-join (append (list header sep) lines) "\n")))

(define (fmt-json rows fields)
  (let ((objs (list->vector
                (map (lambda (row)
                       (let ((h (make-hash-table)))
                         (hash-set! h "file" (plist-get row :path))
                         (for-each (lambda (f)
                                     (hash-set! h (symbol->string f) (plist-get row f)))
                                   fields)
                         h))
                     rows))))
    (let ((r (json-stringify objs)))
      (if (ok? r) (result-value r) "[]"))))

(define (fmt-csv rows fields)
  (let* ((header (string-join (cons "file" (map symbol->string fields)) ","))
         (lines  (map (lambda (row)
                        (string-join (cons (plist-get row :path)
                                           (map (lambda (f) (number->string (plist-get row f)))
                                                fields))
                                     ","))
                      rows)))
    (string-join (cons header lines) "\n")))

(define (render-rows rows fields fmt)
  (cond ((string=? fmt "json") (fmt-json rows fields))
        ((string=? fmt "csv")  (fmt-csv  rows fields))
        (#t                    (fmt-text rows fields))))

;;; ── Shared option/positional specs ────────────────────────────────────────

(define format-opt
  (option 'format :long "format" :short "f" :kind 'value
          :env "TALLY_FORMAT"
          :validate (lambda (v) (member v (list "text" "json" "csv")))
          :help "Output format: text, json, csv"))

(define limit-opt
  (option 'limit :long "limit" :short "n" :kind 'value :type 'integer
          :validate (lambda (v) (> v 0))
          :help "Process at most N files"))

(define files-pos
  (positional 'files :required #t :help "Files to process"))

;;; ── Command handlers ───────────────────────────────────────────────────────

(define (run-count fields ctx)
  (let* ((path   (ctx-positional ctx 'files))
         (paths  (if (list? path) path (list path)))
         (limit  (ctx-option ctx 'limit))
         (paths  (if limit (take paths limit) paths))
         (fmt    (or (ctx-option ctx 'format) "text"))
         (rows   (map tally-file paths)))
    (display (render-rows rows fields fmt))
    (newline)))

;;; ── Program definition ─────────────────────────────────────────────────────

(defprogram tally
  :name "tally"
  :version "1.0"
  :summary "Count words, lines, and characters in text files"
  :description "Reads one or more files and reports counts.\nOutput format can be set via --format or $TALLY_FORMAT."

  (command "lines"
    :summary "Count lines"
    :positionals (list files-pos)
    :options (list format-opt limit-opt)
    :handler (lambda (ctx) (run-count (list :lines) ctx)))

  (command "words"
    :summary "Count words"
    :positionals (list files-pos)
    :options (list format-opt limit-opt)
    :handler (lambda (ctx) (run-count (list :words) ctx)))

  (command "chars"
    :summary "Count characters"
    :positionals (list files-pos)
    :options (list format-opt limit-opt)
    :handler (lambda (ctx) (run-count (list :chars) ctx)))

  (command "all"
    :summary "Count lines, words, and characters together"
    :positionals (list files-pos)
    :options (list format-opt limit-opt)
    :handler (lambda (ctx) (run-count (list :lines :words :chars) ctx)))

  (command "docs"
    :summary "Print this program's documentation as Markdown"
    :handler (lambda (ctx)
      (display (render-markdown (ctx-program ctx)))
      (newline))))

;;; ── Entry point ────────────────────────────────────────────────────────────

(run tally)
