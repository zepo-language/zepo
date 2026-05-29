; examples/explain-file.lisp — Phase 1 end-to-end smoke / demo workflow.
;
; Chunks a source file, embeds the chunks into an in-memory vector
; store, registers three tools (retrieve_code, llm_chat, llm_code),
; asks the local planner LLM to produce a JSON plan, executes the plan
; via the orchestrator, and prints the synthesized answer.
;
; Usage:
;   zepo examples/explain-file.lisp -- <file-path> "<question>"
;
; Requires Ollama on localhost:11434 with these models pulled:
;   - nomic-embed-text       (embeddings)
;   - llama3.1:8b            (planner + llm_chat, override via ZEPO_PLANNER_MODEL / ZEPO_CHAT_MODEL)
;   - qwen2.5-coder:7b       (llm_code, override via ZEPO_CODE_MODEL)
;
; Embeddings are cached to /tmp keyed by file path + mtime so retakes
; during a recording skip the slow embed pass.
;
; zepo-dqo / zepo-zrc

(import :libs (orch/chunker      (chunk-file) ; zepo-y1a4
               orch/embed        (embed-text)
               orch/vector_store (make-store store-add! store-save store-load
                                  store-search store-size)
               orch/registry     (reset-registry! register-tool!)
               orch/planner      (plan-with default-planner-url default-retries)
               orch/exec         (run-plan plan-result)
               orch/http         (http-post-json)))

; --- argv ----------------------------------------------------------------
; argv = (binary script arg ...) once Zepo has stripped "--".
(define raw-argv (argv))
(define args (if (>= (length raw-argv) 4) (cddr raw-argv) '()))

(cond
  ((< (length args) 2)
   (display "usage: zepo examples/explain-file.lisp -- <file> \"<question>\"")
   (newline)
   (exit 2)))

(define file-path (car args))
(define question  (cadr args))

(define planner-model
  (or (getenv "ZEPO_PLANNER_MODEL") "llama3.1:8b"))
(define chat-model
  (or (getenv "ZEPO_CHAT_MODEL")    "llama3.1:8b"))
(define code-model
  (or (getenv "ZEPO_CODE_MODEL")    "qwen2.5-coder:7b"))

; --- timing scaffolding --------------------------------------------------
; (stage label thunk) prints a banner, runs thunk, records ms into stages.
(define stages '())

(define (stage label thunk)
  (display "── ") (display label) (newline)
  (let* ((t0 (current-time-ms))
         (r  (thunk))
         (dt (- (current-time-ms) t0)))
    (set! stages (cons (cons label dt) stages))
    r))

(define total-start (current-time-ms))

; --- 1. chunk ------------------------------------------------------------

(define chunks
  (stage "chunking"
    (lambda ()
      (let ((cs (chunk-file file-path)))
        (display "  ") (display (length cs)) (display " chunks") (newline)
        cs))))

; --- 2. embed (with cache) ----------------------------------------------

; Cache key: /tmp/zepo-explain-<sanitised-path>-<mtime>.json
(define (sanitise-path p)
  (let ((n (string-length p)) (out ""))
    (let loop ((i 0))
      (cond
        ((= i n) out)
        (else
         (let ((ch1 (substring p i (+ i 1))))
           (set! out
             (string-append out
               (cond
                 ((string=? ch1 "/") "_")
                 ((string=? ch1 " ") "_")
                 (else ch1))))
           (loop (+ i 1))))))))

(define cache-path
  (string-append "/tmp/zepo-explain-"
                 (sanitise-path file-path)
                 "-"
                 (number->string (file-mtime file-path))
                 ".json"))

(define (embed-fresh)
  (let ((s (make-store)))
    (let loop ((rest chunks))
      (cond
        ((null? rest)
         (let ((sv (store-save s cache-path)))
           (cond
             ((err? sv)
              (display "  cache save failed: ")
              (display (err-message sv)) (newline))
             (else
              (display "  cached ") (display (store-size s))
              (display " embeddings -> ") (display cache-path) (newline))))
         s)
        (else
         (let* ((c    (car rest))
                (id   (cdr (assoc :id c)))
                (text (cdr (assoc :text c)))
                (r    (embed-text text)))
           (cond
             ((err? r)
              (display "  embed failed for ") (display id) (display ": ")
              (display (err-message r)) (newline)
              (exit 1))
             (else
               (store-add! s id (result-value r)
                           (list (cons "text"       text)
                                 (cons "path"       (cdr (assoc :path c)))
                                 (cons "line-start" (cdr (assoc :line-start c)))
                                 (cons "line-end"   (cdr (assoc :line-end c)))))))
           (loop (cdr rest))))))))

(define store
  (stage "embedding"
    (lambda ()
      (cond
        ((file-exists? cache-path)
         (display "  cache hit: ") (display cache-path) (newline)
         (let ((r (store-load cache-path)))
           (cond
             ((err? r)
              (display "  cache load failed; re-embedding: ")
              (display (err-message r)) (newline)
              (embed-fresh))
             (else (result-value r)))))
        (else (embed-fresh))))))

; --- 3. tools ------------------------------------------------------------

(define (format-hits hits)
  (let ((acc ""))
    (for-each
      (lambda (h)
        (let ((id   (car (cdr h)))
              (meta (cdr (cdr h))))
          (set! acc
            (string-append acc
              "── " id " ──\n"
              (hash-get meta "text") "\n\n"))))
      hits)
    acc))

(define (retrieve-tool args)
  (let ((q (cdr (assoc 'query args))))
    (let ((qe (embed-text q)))
      (cond
        ((err? qe) qe)
        (else
          (ok (format-hits
                (store-search store (result-value qe) 4))))))))

(define (call-chat-model model prompt)
  (let ((body (json-stringify
                (list (cons "model" model)
                      (cons "temperature" 0)
                      (cons "max_tokens" 1024)
                      (cons "messages"
                            (vector
                              (list (cons "role" "user")
                                    (cons "content" prompt))))))))
    (cond
      ((err? body) (err 'json-encode (err-message body)))
      (else
        (let ((r (http-post-json
                   "http://localhost:11434/v1/chat/completions"
                   (result-value body) 180)))
          (cond
            ((err? r) r)
            (else (extract-chat-content (result-value r)))))))))

(define (extract-chat-content sb)
  (let ((status (car sb)) (body (cdr sb)))
    (cond
      ((not (= status 200))
       (err 'http-status
            (string-append "status " (number->string status))))
      (else
        (let ((p (json-parse body)))
          (cond
            ((err? p) p)
            (else (extract-from-chat-root (result-value p)))))))))

(define (extract-from-chat-root root)
  (let ((choices (hash-get root "choices")))
    (cond
      ((or (not (vector? choices)) (= (vector-length choices) 0))
       (err 'shape "no choices in response"))
      (else
       (let* ((c0  (vector-ref choices 0))
              (msg (hash-get c0 "message"))
              (content (and msg (hash-get msg "content"))))
         (cond
           ((not (string? content))
            (err 'shape "no message.content string"))
           (else (ok content))))))))

(define (build-llm-prompt args)
  (string-append "Question: " (cdr (assoc 'question args))
                 "\n\nContext (use this to ground your answer):\n"
                 (cdr (assoc 'context args))
                 "\n\nAnswer concisely and cite line ranges from the"
                 " context where useful."))

(reset-registry!)
(register-tool! 'retrieve_code retrieve-tool
                :inputs '((query . string)))
(register-tool! 'llm_chat
                (lambda (a) (call-chat-model chat-model (build-llm-prompt a)))
                :inputs '((question . string) (context . string)))
(register-tool! 'llm_code
                (lambda (a) (call-chat-model code-model (build-llm-prompt a)))
                :inputs '((question . string) (context . string)))

; --- 4. plan -------------------------------------------------------------

; Pretty-printer for the core plan form. Renders sequence/parallel as
; arrows, tool-call as (id tool arg: val, ...), and the unresolved
; {"input_id":"r1"} hash-tables that the LLM emits as <-r1 so viewers
; can see the dataflow at a glance.
(define (format-value v)
  (cond
    ((string? v) v)
    ((number? v) (number->string v))
    ((symbol? v) (symbol->string v))
    ((null? v)   "()")
    ((and (hash-table? v) (hash-contains? v "input_id"))
     (string-append "<-" (hash-get v "input_id")))
    (else "?")))

(define (format-args al)
  (let ((acc '()))
    (for-each
      (lambda (kv)
        (set! acc
          (cons (string-append (symbol->string (car kv))
                               ": " (format-value (cdr kv)))
                acc)))
      al)
    (string-join (reverse acc) ", ")))

(define (format-plan p)
  (cond
    ((not (pair? p)) (format-value p))
    (else
      (let ((tag (car p)))
        (cond
          ((eq? tag 'sequence)
           (string-append "sequence[ "
                          (string-join (map format-plan (cdr p)) " → ")
                          " ]"))
          ((eq? tag 'parallel)
           (string-append "parallel[ "
                          (string-join (map format-plan (cdr p)) " ‖ ")
                          " ]"))
          ((eq? tag 'tool-call)
           (let ((id   (car (cdr p)))
                 (tool (car (cdr (cdr p))))
                 (a    (car (cdr (cdr (cdr p))))))
             (string-append "(" id " " (symbol->string tool)
                            " " (format-args a) ")")))
          ((eq? tag 'final-answer)
           (string-append "final-answer<-" (car (cdr p))))
          (else "?"))))))

(define plan-form
  (stage "planning"
    (lambda ()
      (let ((ctx-text
             (string-append "File under inspection: " file-path "\n"
                            "Recommended workflow: one retrieve_code step with a"
                            " search query derived from the question, then one"
                            " llm_code step whose 'context' arg is"
                            " {\"input_id\":\"<retrieve-step-id>\"} and whose"
                            " 'question' arg is the user's literal question."
                            " End with final-answer pointing at the llm_code step.")))
        (let ((p (plan-with question ctx-text planner-model
                            default-planner-url default-retries)))
          (cond
            ((err? p)
             (display "  planner failed: ") (display (err-kind p))
             (display " — ") (display (err-message p)) (newline)
             (exit 1))
            (else
              (let ((pf (result-value p)))
                (display "  ") (display (format-plan pf)) (newline)
                pf))))))))

; --- 5. execute ----------------------------------------------------------

(define exec-r
  (stage "executing"
    (lambda ()
      (let ((r (run-plan plan-form)))
        (cond
          ((err? r)
           (display "  exec failed: ") (display (err-kind r))
           (display " — ") (display (err-message r)) (newline)
           (exit 1))
          (else r))))))

(define final (plan-result (result-value exec-r)))

(display "── answer") (newline)
(cond
  ((err? final)
   (display "  no final answer: ") (display (err-message final)) (newline)
   (exit 1))
  (else
   (display (result-value final)) (newline)))

; --- timing breakdown ----------------------------------------------------

(define total-ms (- (current-time-ms) total-start))

(define (pad-right s width)
  (let loop ((acc s))
    (if (>= (string-length acc) width) acc
        (loop (string-append acc " ")))))

(define (pad-left s width)
  (let loop ((acc s))
    (if (>= (string-length acc) width) acc
        (loop (string-append " " acc)))))

(display "── timing") (newline)
(for-each
  (lambda (kv)
    (display "  ")
    (display (pad-right (car kv) 12))
    (display (pad-left (number->string (cdr kv)) 6))
    (display " ms") (newline))
  (reverse stages))
(display "  ")
(display (pad-right "total" 12))
(display (pad-left (number->string total-ms) 6))
(display " ms") (newline)
