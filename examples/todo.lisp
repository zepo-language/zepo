; todo.lisp — simple in-memory TODO CLI using clap
;
; Commands:
;   todo add --title "Buy milk" [--priority 1]
;   todo list [--done #t]
;   todo done <id>
;
; NOTE: This stores todos only in memory for the current run, just to demo clap.

(import clap)

;;; ── In-memory store ─────────────────────────────────────────────────────────

(define *todos* '())
(define *next-id* 1)

(define (make-todo title priority)
  (let ((id *next-id*))
    (set! *next-id* (+ *next-id* 1))
    (list :id id :title title :priority priority :done #f)))

(define (todo-add! title priority)
  (let ((t (make-todo title priority)))
    (set! *todos* (append *todos* (list t)))
    t))

(define (todo-find-by-id id)
  (find (lambda (t) (= (plist-get t :id) id)) *todos*))

(define (todo-mark-done! id)
  (let loop ((xs *todos*) (acc '()))
    (cond
      ((null? xs) (set! *todos* (reverse acc)))
      (#t
       (let* ((t (car xs))
              (tid (plist-get t :id)))
         (if (= tid id)
             (loop (cdr xs)
                   (cons (plist-set t :done #t) acc))
             (loop (cdr xs)
                   (cons t acc))))))))

(define (todo-print t)
  (display (plist-get t :id))
  (display ". [")
  (display (if (plist-get t :done) "x" " "))
  (display "] ")
  (display (plist-get t :title))
  (display " (priority ")
  (display (plist-get t :priority))
  (display ")")
  (newline))

;;; ── Command handlers ───────────────────────────────────────────────────────

(define (handle-add result)
  (let* ((title (result-option result 'title))
         (prio  (or (result-option result 'priority) 1))
         (todo  (todo-add! title prio)))
    (display "Added: ")
    (todo-print todo)))

(define (handle-list result)
  (let* ((show-done (result-option result 'done))
         (show-done (if (equal? show-done #f) #t show-done)))
    (if (null? *todos*)
        (println "No todos yet.")
        (for-each
          (lambda (t)
            (if (or show-done (not (plist-get t :done)))
                (todo-print t)))
          *todos*))))

(define (handle-done result)
  (let* ((id (result-positional result 'id))
         (todo (todo-find-by-id id)))
    (if (not todo)
        (begin
          (display "No todo with id ")
          (display id)
          (newline))
        (begin
          (todo-mark-done! id)
          (display "Marked done: ")
          (todo-print (todo-find-by-id id))))))

;;; ── clap definitions ───────────────────────────────────────────────────────

; Options for all commands
(define verbose-opt
  (opt-set
    (opt-set
      (make-option 'verbose "Enable verbose output")
      :long "verbose")
    :short #\v))

; add command
(define add-cmd
  (let ((cmd (make-command "add" "Add a new todo")))
    (let ((cmd (cmd-add-option
                 cmd
                 (opt-set
                   (opt-set
                     (opt-set
                       (make-option 'title "Title of the todo")
                       :long "title")
                     :kind 'value)
                   :required #t))))
      (let ((cmd (cmd-add-option
                   cmd
                   (opt-set
                     (opt-set
                       (opt-set
                         (make-option 'priority "Priority (integer, default 1)")
                         :long "priority")
                       :kind 'value)
                     :type 'integer))))
        (opt-set cmd :handler handle-add)))))

; list command
(define list-cmd
  (let ((cmd (make-command "list" "List todos")))
    (let ((cmd (cmd-add-option
                 cmd
                 (opt-set
                   (opt-set
                     (make-option 'done "Show only done todos")
                     :long "done")
                   :kind 'flag))))
      (opt-set cmd :handler handle-list))))

; done command
(define done-cmd
  (let ((cmd (make-command "done" "Mark a todo as done")))
    (let ((cmd (cmd-add-positional
                 cmd
                 (opt-set
                   (make-positional 'id "ID of todo to mark done")
                   :type 'integer))))
      (opt-set cmd :handler handle-done))))

; Root command with subcommands
(define root
  (let ((cmd (make-command "todo" "Simple in-memory todo manager")))
    (let ((cmd (cmd-add-option cmd verbose-opt)))
      (opt-set cmd :subcommands (list add-cmd list-cmd done-cmd)))))

(define prog
  (make-program "todo" "Simple todo CLI" "" "0.1.0" root))

;;; ── Entry point ────────────────────────────────────────────────────────────

(define (main)
  (run prog))

(main)
