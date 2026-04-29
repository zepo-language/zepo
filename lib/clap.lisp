; clap — command-line argument parser for Zepo.
; Data model: all objects are plists (flat key-value lists).

(module clap
  (export
    make-program make-command make-option make-positional
    opt-set cmd-add-option cmd-add-positional
    parse run
    render-help render-usage render-error
    parse-result? parse-error?
    result-option result-positional result-command result-remaining
    ctx-option ctx-positional ctx-command ctx-remaining ctx-program
    error-kind error-message error-token error-suggestions)

  ;;; ── Internal helpers ──────────────────────────────────────────────────────

  ; Normalize a :short value to a string for comparison.
  (define (short->string s)
    (cond ((not s) #f)
          ((char? s) (char->string s))
          ((symbol? s) (symbol->string s))
          ((string? s) s)
          (#t #f)))

  ;;; ── Constructors ──────────────────────────────────────────────────────────

  (define (make-program name summary description version root-cmd)
    (list :name name
          :summary summary
          :description description
          :version version
          :root-command root-cmd
          :help-enabled #t
          :version-enabled #f
          :parse-mode (quote permute)))

  (define (make-command name summary)
    (list :name name
          :summary summary
          :description ""
          :options (quote ())
          :positionals (quote ())
          :subcommands (quote ())
          :aliases (quote ())
          :handler #f))

  (define (make-option key help)
    ; kinds: flag counter value multi
    ; types: string integer number boolean
    (list :key key
          :long #f
          :short #f
          :kind (quote flag)
          :type (quote string)
          :required #f
          :default #f
          :multiple #f
          :value-name "VALUE"
          :help help))

  (define (make-positional key help)
    (list :key key
          :type (quote string)
          :required #f
          :repeats #f
          :default #f
          :help help))

  ; Set a field in any plist (used as builder for options, commands, etc.)
  (define (opt-set pl key val)
    (plist-set pl key val))

  ; Add an option spec to a command.
  (define (cmd-add-option cmd opt)
    (plist-set cmd :options (append (plist-get cmd :options) (list opt))))

  ; Add a positional spec to a command.
  (define (cmd-add-positional cmd pos)
    (plist-set cmd :positionals (append (plist-get cmd :positionals) (list pos))))

  ;;; ── Result/Error types ────────────────────────────────────────────────────

  (define (make-parse-result prog cmd cmd-path options positionals remaining)
    (list :tag (quote parse-result)
          :program prog
          :command cmd
          :command-path cmd-path
          :options options
          :positionals positionals
          :remaining remaining))

  (define (make-parse-error kind message token key suggestions)
    (list :tag (quote parse-error)
          :kind kind
          :message message
          :token token
          :key key
          :suggestions suggestions))

  (define (parse-result? v)
    (and (pair? v) (equal? (plist-get v :tag) (quote parse-result))))

  (define (parse-error? v)
    (and (pair? v) (equal? (plist-get v :tag) (quote parse-error))))

  ;;; ── Result accessors ──────────────────────────────────────────────────────

  (define (result-option r key)
    (plist-get (plist-get r :options) key))

  (define (result-positional r key)
    (plist-get (plist-get r :positionals) key))

  (define (result-command r)
    (plist-get r :command))

  (define (result-remaining r)
    (plist-get r :remaining))

  ;;; ── Handler context (2.0 API) ─────────────────────────────────────────────
  ; ctx is the parse-result plist. These accessors are the documented interface
  ; for handler functions; result-* remain for backward compatibility.

  (define ctx-option     result-option)
  (define ctx-positional result-positional)
  (define ctx-command    result-command)
  (define ctx-remaining  result-remaining)

  (define (ctx-program ctx)
    (plist-get ctx :program))

  (define (error-kind e)    (plist-get e :kind))
  (define (error-message e) (plist-get e :message))
  (define (error-token e)   (plist-get e :token))
  (define (error-suggestions e) (plist-get e :suggestions))

  ;;; ── Token classifier ──────────────────────────────────────────────────────

  (define (classify-token tok)
    (cond
      ((equal? tok "--")
       (list :type (quote opt-terminator) :value #f))
      ((string-prefix? "--" tok)
       (let ((rest (substring tok 2 (string-length tok))))
         (let ((eq-idx (string-index rest #\=)))
           (if eq-idx
               (list :type (quote long-assign)
                     :name (substring rest 0 eq-idx)
                     :value (substring rest (+ eq-idx 1) (string-length rest)))
               (list :type (quote long-opt) :value rest)))))
      ((and (string-prefix? "-" tok)
            (> (string-length tok) 1)
            (not (string-prefix? "--" tok)))
       (let ((c (string-ref tok 1)))
         (if (char-numeric? c)
             (list :type (quote word) :value tok)
             (list :type (quote short-opt) :value (substring tok 1 (string-length tok))))))
      (#t (list :type (quote word) :value tok))))

  ;;; ── Option lookup ─────────────────────────────────────────────────────────

  (define (find-long-opt opts name)
    (let loop ((lst opts))
      (cond ((null? lst) #f)
            ((equal? (plist-get (car lst) :long) name) (car lst))
            (#t (loop (cdr lst))))))

  (define (find-short-opt opts ch-str)
    (let loop ((lst opts))
      (cond ((null? lst) #f)
            ((let ((s (short->string (plist-get (car lst) :short))))
               (and s (equal? s ch-str)))
             (car lst))
            (#t (loop (cdr lst))))))

  ;;; ── Type coercion ─────────────────────────────────────────────────────────

  (define (coerce-value type-sym raw)
    (cond
      ((equal? type-sym (quote string)) raw)
      ((equal? type-sym (quote integer))
       (let ((n (string->number raw)))
         (if (and n (integer? n))
             n
             (cons (quote coerce-error) (string-append "Expected integer, got: " raw)))))
      ((equal? type-sym (quote number))
       (let ((n (string->number raw)))
         (if n n (cons (quote coerce-error) (string-append "Expected number, got: " raw)))))
      ((equal? type-sym (quote boolean))
       (cond ((or (equal? raw "true")  (equal? raw "1") (equal? raw "#t")) #t)
             ((or (equal? raw "false") (equal? raw "0") (equal? raw "#f")) #f)
             (#t (cons (quote coerce-error) (string-append "Expected boolean, got: " raw)))))
      (#t raw)))

  (define (coerce-error? v)
    (and (pair? v) (equal? (car v) (quote coerce-error))))

  ;;; ── Apply option value ────────────────────────────────────────────────────

  (define (apply-opt-value opt-spec coerced opt-acc)
    (let* ((key  (plist-get opt-spec :key))
           (kind (plist-get opt-spec :kind))
           (cur  (plist-get opt-acc key)))
      (cond
        ((equal? kind (quote flag))    (plist-set opt-acc key #t))
        ((equal? kind (quote counter)) (plist-set opt-acc key (+ (if cur cur 0) 1)))
        ((equal? kind (quote multi))
         (plist-set opt-acc key (append (if cur cur (quote ())) (list coerced))))
        (#t (plist-set opt-acc key coerced)))))

  ;;; ── Suggestions ───────────────────────────────────────────────────────────

  (define (edit-distance a b)
    (let ((la (string-length a)) (lb (string-length b)))
      (let loop ((i 0) (prev (iota (+ lb 1))))
        (if (= i la)
            (list-ref prev lb)
            (loop (+ i 1)
                  (let inner ((j 0) (row (list (+ i 1))) (p prev))
                    (if (= j lb)
                        (reverse row)
                        (let* ((cost (if (char=? (string-ref a i) (string-ref b j)) 0 1))
                               (val  (min (+ (list-ref prev (+ j 1)) 1)
                                          (min (+ (car row) 1)
                                               (+ (list-ref prev j) cost)))))
                          (inner (+ j 1) (cons val row) (cdr p))))))))))

  (define (suggestions-for name candidates)
    (filter (lambda (c) (<= (edit-distance name c) 3)) candidates))

  ;;; ── Parse token ───────────────────────────────────────────────────────────

  (define (parse-token prog cmd cmd-path argv raw all-opts positionals
                       opt-acc pos-acc after-terminator parse-mode subs)
    (let* ((tok      (car argv))
           (rest     (cdr argv))
           (cls      (classify-token tok))
           (cls-type (plist-get cls :type)))
      (cond
        ; ── long option --name ──
        ((equal? cls-type (quote long-opt))
         (let* ((name     (plist-get cls :value))
                (opt-spec (find-long-opt all-opts name)))
           (if (not opt-spec)
               (make-parse-error (quote unknown-option)
                                 (string-append "Unknown option: --" name)
                                 tok #f
                                 (suggestions-for name
                                   (filter identity
                                     (map (lambda (o) (plist-get o :long)) all-opts))))
               (let ((kind (plist-get opt-spec :kind)))
                 (if (or (equal? kind (quote flag)) (equal? kind (quote counter)))
                     (parse-tokens prog cmd cmd-path rest raw all-opts positionals
                                   (apply-opt-value opt-spec #t opt-acc)
                                   pos-acc after-terminator parse-mode subs)
                     (if (null? rest)
                         (make-parse-error (quote missing-value)
                                           (string-append "Option requires a value: --" name)
                                           tok (plist-get opt-spec :key) (quote ()))
                         (let ((coerced (coerce-value (plist-get opt-spec :type) (car rest))))
                           (if (coerce-error? coerced)
                               (make-parse-error (quote invalid-value) (cdr coerced)
                                                 (car rest) (plist-get opt-spec :key) (quote ()))
                               (parse-tokens prog cmd cmd-path (cdr rest) raw all-opts positionals
                                             (apply-opt-value opt-spec coerced opt-acc)
                                             pos-acc after-terminator parse-mode subs)))))))))

        ; ── long assign --name=value ──
        ((equal? cls-type (quote long-assign))
         (let* ((name     (plist-get cls :name))
                (raw-val  (plist-get cls :value))
                (opt-spec (find-long-opt all-opts name)))
           (if (not opt-spec)
               (make-parse-error (quote unknown-option)
                                 (string-append "Unknown option: --" name)
                                 tok #f
                                 (suggestions-for name
                                   (filter identity
                                     (map (lambda (o) (plist-get o :long)) all-opts))))
               (let ((coerced (coerce-value (plist-get opt-spec :type) raw-val)))
                 (if (coerce-error? coerced)
                     (make-parse-error (quote invalid-value) (cdr coerced)
                                       raw-val (plist-get opt-spec :key) (quote ()))
                     (parse-tokens prog cmd cmd-path rest raw all-opts positionals
                                   (apply-opt-value opt-spec coerced opt-acc)
                                   pos-acc after-terminator parse-mode subs))))))

        ; ── short options -abc ──
        ((equal? cls-type (quote short-opt))
         (parse-short-chars prog cmd cmd-path (plist-get cls :value) rest raw
                            all-opts positionals opt-acc pos-acc
                            after-terminator parse-mode subs))

        ; ── word or anything else ──
        (#t
         (parse-tokens prog cmd cmd-path rest raw all-opts positionals
                       opt-acc (append pos-acc (list tok))
                       after-terminator parse-mode subs)))))

  ;;; ── Short option bundle parser ────────────────────────────────────────────

  (define (parse-short-chars prog cmd cmd-path chars rest raw
                             all-opts positionals opt-acc pos-acc
                             after-terminator parse-mode subs)
    (if (= (string-length chars) 0)
        (parse-tokens prog cmd cmd-path rest raw all-opts positionals
                      opt-acc pos-acc after-terminator parse-mode subs)
        (let* ((ch-str   (substring chars 0 1))
               (tail     (substring chars 1 (string-length chars)))
               (opt-spec (find-short-opt all-opts ch-str)))
          (if (not opt-spec)
              (make-parse-error (quote unknown-option)
                                (string-append "Unknown option: -" ch-str)
                                (string-append "-" ch-str) #f (quote ()))
              (let ((kind (plist-get opt-spec :kind)))
                (if (or (equal? kind (quote flag)) (equal? kind (quote counter)))
                    (parse-short-chars prog cmd cmd-path tail rest raw
                                       all-opts positionals
                                       (apply-opt-value opt-spec #t opt-acc)
                                       pos-acc after-terminator parse-mode subs)
                    ; value kind: rest of chars is the value, or take next token
                    (if (> (string-length tail) 0)
                        (let ((coerced (coerce-value (plist-get opt-spec :type) tail)))
                          (if (coerce-error? coerced)
                              (make-parse-error (quote invalid-value) (cdr coerced)
                                                tail (plist-get opt-spec :key) (quote ()))
                              (parse-tokens prog cmd cmd-path rest raw all-opts positionals
                                            (apply-opt-value opt-spec coerced opt-acc)
                                            pos-acc after-terminator parse-mode subs)))
                        (if (null? rest)
                            (make-parse-error (quote missing-value)
                                              (string-append "Option requires a value: -" ch-str)
                                              (string-append "-" ch-str)
                                              (plist-get opt-spec :key) (quote ()))
                            (let ((coerced (coerce-value (plist-get opt-spec :type) (car rest))))
                              (if (coerce-error? coerced)
                                  (make-parse-error (quote invalid-value) (cdr coerced)
                                                    (car rest) (plist-get opt-spec :key) (quote ()))
                                  (parse-tokens prog cmd cmd-path (cdr rest) raw all-opts positionals
                                                (apply-opt-value opt-spec coerced opt-acc)
                                                pos-acc after-terminator parse-mode subs)))))))))))

  ;;; ── Main token loop ───────────────────────────────────────────────────────

  (define (parse-tokens prog cmd cmd-path argv raw all-opts positionals
                        opt-acc pos-acc after-terminator parse-mode subs)
    (cond
      ((null? argv)
       (finalize prog cmd cmd-path raw all-opts positionals opt-acc pos-acc))

      ((and (not after-terminator)
            (equal? (plist-get (classify-token (car argv)) :type) (quote opt-terminator)))
       ; Everything after -- is treated as positional words.
       (let loop ((rest (cdr argv)) (pa pos-acc))
         (if (null? rest)
             (finalize prog cmd cmd-path raw all-opts positionals opt-acc pa)
             (loop (cdr rest) (append pa (list (car rest)))))))

      (after-terminator
       (parse-tokens prog cmd cmd-path (cdr argv) raw all-opts positionals
                     opt-acc (append pos-acc (list (car argv))) #t parse-mode subs))

      ((not (null? subs))
       (let ((sub (find (lambda (s) (equal? (plist-get s :name) (car argv))) subs)))
         (if sub
             (parse-command prog sub
                            (append cmd-path (list (plist-get cmd :name)))
                            (cdr argv) raw parse-mode
                            (plist-get prog :help-enabled)
                            (plist-get prog :version-enabled))
             (parse-token prog cmd cmd-path argv raw all-opts positionals
                          opt-acc pos-acc after-terminator parse-mode subs))))

      (#t
       (parse-token prog cmd cmd-path argv raw all-opts positionals
                    opt-acc pos-acc after-terminator parse-mode subs))))

  ;;; ── Finalize ──────────────────────────────────────────────────────────────

  (define (finalize prog cmd cmd-path raw all-opts positionals opt-acc pos-acc)
    (define (apply-defaults opts acc)
      (if (null? opts)
          acc
          (let* ((opt (car opts))
                 (key (plist-get opt :key))
                 (def (plist-get opt :default)))
            (apply-defaults (cdr opts)
                            (if (plist-has? acc key)
                                acc
                                (plist-set acc key def))))))
    (define (bind-positionals specs tokens pa)
      (cond
        ((and (null? specs) (null? tokens)) pa)
        ((null? specs) pa)
        ((null? tokens)
         (let* ((spec (car specs))
                (key  (plist-get spec :key))
                (def  (plist-get spec :default))
                (req  (plist-get spec :required)))
           (if req
               (make-parse-error (quote missing-required)
                                 (string-append "Required positional missing: "
                                                (symbol->string key))
                                 #f key (quote ()))
               (bind-positionals (cdr specs) tokens (plist-set pa key def)))))
        (#t
         (let* ((spec     (car specs))
                (key      (plist-get spec :key))
                (repeats  (plist-get spec :repeats))
                (type-sym (plist-get spec :type)))
           (if repeats
               (let ((coerced-all (map (lambda (t) (coerce-value type-sym t)) tokens)))
                 (plist-set pa key coerced-all))
               (let ((coerced (coerce-value type-sym (car tokens))))
                 (if (coerce-error? coerced)
                     (make-parse-error (quote invalid-value) (cdr coerced)
                                       (car tokens) key (quote ()))
                     (bind-positionals (cdr specs) (cdr tokens)
                                       (plist-set pa key coerced)))))))))
    (define (check-required opts acc)
      (if (null? opts)
          #f
          (let* ((opt (car opts))
                 (req (plist-get opt :required))
                 (key (plist-get opt :key)))
            (if (and req (not (plist-get acc key)))
                (make-parse-error (quote missing-required)
                                  (string-append "Required option missing: "
                                                 (symbol->string key))
                                  #f key (quote ()))
                (check-required (cdr opts) acc)))))
    (let* ((opt-acc2 (apply-defaults all-opts opt-acc))
           (req-err  (check-required all-opts opt-acc2)))
      (if req-err
          req-err
          (let ((pos-result (bind-positionals positionals pos-acc (quote ()))))
            (if (parse-error? pos-result)
                pos-result
                (make-parse-result prog cmd cmd-path opt-acc2 pos-result (quote ())))))))

  ;;; ── Parse command ─────────────────────────────────────────────────────────

  (define (parse-command prog cmd cmd-path argv raw parse-mode help-on ver-on)
    (let* ((subs      (plist-get cmd :subcommands))
           (base-opts (plist-get cmd :options))
           (all-opts  base-opts)
           (positionals (plist-get cmd :positionals)))
      (parse-tokens prog cmd cmd-path argv raw all-opts positionals
                    (quote ()) (quote ()) #f parse-mode subs)))

  ;;; ── Parse entry point ─────────────────────────────────────────────────────

  (define (parse prog argv)
    (let ((root-cmd   (plist-get prog :root-command))
          (help-on    (plist-get prog :help-enabled))
          (ver-on     (plist-get prog :version-enabled))
          (parse-mode (plist-get prog :parse-mode)))
      (parse-command prog root-cmd (quote ()) argv argv parse-mode help-on ver-on)))

  ;;; ── Rendering ─────────────────────────────────────────────────────────────

  (define (render-usage prog cmd)
    (let ((name (plist-get prog :name))
          (opts (plist-get cmd :options))
          (pos  (plist-get cmd :positionals))
          (subs (plist-get cmd :subcommands)))
      (let* ((pos-strs (map (lambda (p)
                              (if (plist-get p :required)
                                  (symbol->string (plist-get p :key))
                                  (string-append "[" (symbol->string (plist-get p :key)) "]")))
                            pos))
             (parts (append
                      (append (list "Usage:" name)
                              (append (if (not (null? opts)) (list "[OPTIONS]") (quote ()))
                                      (if (not (null? subs)) (list "[COMMAND]") (quote ()))))
                      pos-strs)))
        (string-join parts " "))))

  (define (render-option-line opt)
    (let* ((short (plist-get opt :short))
           (long  (plist-get opt :long))
           (kind  (plist-get opt :kind))
           (vname (plist-get opt :value-name))
           (help  (plist-get opt :help))
           (short-part (if short
                           (string-append "-" (short->string short) ", ")
                           "    "))
           (long-part  (if long
                           (string-append "--" long
                                          (if (or (equal? kind :value)
                                                  (equal? kind (quote multi)))
                                              (string-append "=" vname)
                                              ""))
                           ""))
           (line (string-append "  " short-part long-part "  " help)))
      line))

  (define (render-help prog cmd)
    (let* ((name    (plist-get prog :name))
           (ver     (plist-get prog :version))
           (summary (plist-get prog :summary))
           (opts    (plist-get cmd :options))
           (subs    (plist-get cmd :subcommands))
           (parts   (quote ())))
      (let* ((parts (if (not (equal? summary ""))
                        (list summary "" (render-usage prog cmd))
                        (list (render-usage prog cmd))))
             (parts (if (not (null? opts))
                        (append parts (append (list "" "Options:")
                                              (map render-option-line opts)))
                        parts))
             (parts (if (not (null? subs))
                        (append parts (append (list "" "Commands:")
                                              (map (lambda (s)
                                                     (string-append "  " (plist-get s :name)
                                                                    "  " (plist-get s :summary)))
                                                   subs)))
                        parts))
             (parts (if (not (equal? ver ""))
                        (append parts (list "" (string-append "Version: " ver)))
                        parts)))
        (string-join parts "\n"))))

  (define (render-error err)
    (let* ((msg  (plist-get err :message))
           (tok  (plist-get err :token))
           (sugg (plist-get err :suggestions))
           (lines (list (string-append "error: " msg))))
      (let* ((lines (if tok
                        (append lines (list (string-append "  Token: " tok)))
                        lines))
             (lines (if (and sugg (not (null? sugg)))
                        (append lines (list (string-append "  Did you mean: "
                                                           (string-join sugg ", "))))
                        lines)))
        (string-join lines "\n"))))

  ;;; ── Run ───────────────────────────────────────────────────────────────────

  (define (run prog)
    (let* ((all-argv  (argv))
           (user-argv (if (null? all-argv) (quote ()) (cdr all-argv)))
           (result    (parse prog user-argv)))
      (if (parse-error? result)
          (begin (display (render-error result)) (newline) #f)
          (let ((handler (plist-get (result-command result) :handler)))
            (if handler
                (handler result)
                result))))))
