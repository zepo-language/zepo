(import clap)
; Adjust these to your actual JSON API if the names differ:
; Assume:
;   (json-parse-string s) -> alist representation of JSON
;   (json-stringify data) -> string
;   JSON objects <-> alists, arrays <-> lists

;;; ── File I/O helpers (very minimal) ─────────────────────────────────────────

(define (slurp path) (file-read-string path))
(define (spit path content) (file-write-string path content))

;;; ── Config helpers ─────────────────────────────────────────────────────────

; Convert a "a.b.c" path into list of strings: ("a" "b" "c")
(define (split-path s)
  (string-split s "."))

; For JSON objects modeled as alists of (key . value) with string keys.
; Insert or overwrite key in alist.
(define (alist-set-string-key key val al)
  (let loop ((xs al) (acc '()) (found #f))
    (cond
      ((null? xs)
       (if found
           (reverse acc)
           (cons (cons key val) (reverse acc))))
      (#t
       (let* ((p (car xs))
              (k (car p))
              (v (cdr p)))
         (if (equal? k key)
             (loop (cdr xs)
                   (cons (cons key val) acc)
                   #t)
             (loop (cdr xs)
                   (cons p acc)
                   found)))))))

; Set a nested path on an alist-based JSON object.
; path-parts: list of strings ("server" "port")
(define (config-set-path obj path-parts val)
  (if (null? path-parts)
      val
      (let* ((key (car path-parts))
             (rest (cdr path-parts))
             (existing (let ((found (assoc key obj)))
                         (if found (cdr found) '())))
             (child (if (and existing (pair? existing))
                        existing
                        '()))
             (new-child (config-set-path child rest val)))
        (alist-set-string-key key new-child obj))))

; Parse "k=v" pair into (key-path-string . value-string)
(define (parse-kv s)
  (let ((idx (string-contains s "=")))
    (if (not idx)
        (error (string-append "Invalid --set value (expected key=value): " s))
        (cons (substring s 0 idx)
              (substring s (+ idx 1) (string-length s))))))

; Simple type inference for values from CLI: try number/bool, else string.
(define (infer-json-value s)
  (let ((n (string->number s)))
    (cond
      (n n)
      ((equal? s "true")  #t)
      ((equal? s "false") #f)
      (#t s))))

;;; ── clap setup ─────────────────────────────────────────────────────────────

(define cfg-cmd
  (let ((cmd (make-command "config" "JSON config merger")))
    (let ((cmd (cmd-add-positional
                 cmd
                 (opt-set
                   (opt-set
                     (make-positional 'file "Path to JSON config file")
                     :type 'string)
                   :required #t))))
      (let ((cmd (cmd-add-option
                   cmd
                   (opt-set
                     (opt-set
                       (make-option 'set "Override key=value (repeatable)")
                       :long "set")
                     :kind 'multi)))) ; multi -> list of strings
        (opt-set cmd :handler
                 (lambda (result)
                   (let* ((file    (result-positional result 'file))
                          (sets    (or (result-option result 'set) '()))
                          (raw     (slurp file))
                          (cfg     (result-value (json-parse raw))) ; alist
                          (final   (fold-left
                                     (lambda (conf pair-str)
                                       (let* ((kv (parse-kv pair-str))
                                              (path-str (car kv))
                                              (val-str  (cdr kv))
                                              (path-parts (split-path path-str))
                                              (val (infer-json-value val-str)))
                                         (config-set-path conf path-parts val)))
                                     cfg
                                     sets)))
                     ; Print to stdout; user can redirect to file if desired.
                     (println (result-value (json-stringify final))))))))))

(define prog
  (make-program "jsoncfg" "JSON config tool" "" "0.1.0" cfg-cmd))

(define (main)
  (define result (parse prog (cddr (argv))))
  (if (parse-error? result)
      (begin (display (render-error result)) (newline))
      (let ((handler (plist-get (result-command result) :handler)))
        (when handler (handler result)))))

(main)
