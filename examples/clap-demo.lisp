; clap-demo.lisp — showcase of the clap argument parser.
;
; Run with:
;   zepo examples/clap-demo.lisp -- [args...]
;
; Try:
;   zepo examples/clap-demo.lisp -- --help
;   zepo examples/clap-demo.lisp -- --name Alice --count 3 -v hello world
;   zepo examples/clap-demo.lisp -- serve --port 8080
;   zepo examples/clap-demo.lisp -- --unknwon          ; typo → suggestion

(import clap (make-program make-command make-option make-positional ; zepo-y1a4
              opt-set cmd-add-option cmd-add-positional
              parse parse-error? render-help render-error
              result-option result-positional result-command))

;;; ── Build the "serve" subcommand ──────────────────────────────────────────

(define serve-cmd
  (cmd-add-option
    (cmd-add-option
      (make-command "serve" "Start a local server")
      (opt-set (opt-set (make-option (quote port) "Port to listen on")
                        (quote long) "port")
               (quote kind) (quote value)))
    (opt-set (opt-set (make-option (quote bind) "Address to bind")
                      (quote long) "bind")
             (quote default) "127.0.0.1")))

;;; ── Build the root command ────────────────────────────────────────────────

(define root-cmd
  (cmd-add-positional
    (cmd-add-positional
      (cmd-add-option
        (cmd-add-option
          (cmd-add-option
            (plist-set (make-command "clap-demo" "")
                       (quote subcommands)
                       (list serve-cmd))
            ; --name NAME
            (opt-set (opt-set (opt-set (make-option (quote name) "Your name")
                                       (quote long) "name")
                              (quote short) "n")
                     (quote kind) (quote value)))
          ; --count N  (integer)
          (opt-set (opt-set (opt-set (make-option (quote count) "Repeat count")
                                     (quote long) "count")
                            (quote kind) (quote value))
                   (quote type) (quote integer)))
        ; -v / --verbose  (flag, can be stacked via counter)
        (opt-set (opt-set (opt-set (make-option (quote verbose) "Increase verbosity")
                                   (quote long) "verbose")
                          (quote short) "v")
                 (quote kind) (quote counter)))
      ; first positional: optional greeting word
      (opt-set (make-positional (quote greeting) "Word to greet with")
               (quote default) "Hello"))
    ; second positional: repeating list of names
    (opt-set (opt-set (make-positional (quote targets) "Names to greet")
                      (quote repeats) #t)
             (quote default) (quote ()))))

;;; ── Build the program ─────────────────────────────────────────────────────

(define prog
  (make-program "clap-demo"
                "Showcase of the clap Zepo argument parser"
                ""
                "0.1.0"
                root-cmd))

;;; ── Handlers ──────────────────────────────────────────────────────────────

(define (handle-serve result)
  (let ((port (result-option result (quote port)))
        (bind (result-option result (quote bind))))
    (display (string-append "Serving on " bind ":" (if port port "3000")))
    (newline)))

(define (handle-root result)
  (let* ((name     (result-option result (quote name)))
         (count    (result-option result (quote count)))
         (verbose  (result-option result (quote verbose)))
         (greeting (result-positional result (quote greeting)))
         (targets  (result-positional result (quote targets)))
         (n        (if count count 1))
         (who      (if (and targets (not (null? targets)))
                       targets
                       (if name (list name) (list "World")))))
    (if (and verbose (> verbose 0))
        (begin
          (display (string-append "[verbose=" (number->string verbose) "] "))
          (newline)))
    (let loop ((i 0))
      (if (= i n)
          (quote done)
          (begin
            (for-each (lambda (w)
                        (display (string-append greeting ", " w "!"))
                        (newline))
                      who)
            (loop (+ i 1)))))))

;;; ── Dispatch ──────────────────────────────────────────────────────────────

(define (dispatch result)
  (let ((cmd-name (plist-get (result-command result) (quote name))))
    (cond
      ((equal? cmd-name "serve") (handle-serve result))
      (#t                        (handle-root result)))))

(define (main)
  (let* ((all-args  (argv))
         ; argv = (binary script arg...) — skip both binary and script
         (user-args (if (or (null? all-args) (null? (cdr all-args)))
                        (quote ())
                        (cddr all-args))))
    (if (member "--help" user-args)
        (begin (display (render-help prog root-cmd)) (newline))
        (let ((result (parse prog user-args)))
          (if (parse-error? result)
              (begin
                (display (render-error result)) (newline)
                (display (render-help prog root-cmd)) (newline))
              (dispatch result))))))

(main)
