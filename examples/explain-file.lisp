; examples/explain-file.lisp — Phase 1 end-to-end smoke workflow.
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
;   - llama3.1:8b            (planner + llm_chat)
;   - qwen2.5-coder:7b       (llm_code)
;
; zepo-dqo

(import :libs (orch/chunker))
(import :libs (orch/embed))
(import :libs (orch/vector_store))
(import :libs (orch/registry))
(import :libs (orch/planner))
(import :libs (orch/exec))
(import :libs (orch/http))

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

(define (banner s)
  (display "── ") (display s) (newline))

(define start-ms (current-time-ms))

; --- 1. chunk + embed + build store --------------------------------------

(banner "chunking")
(define chunks (chunk-file file-path))
(display "  ") (display (length chunks)) (display " chunks") (newline)

(banner "embedding")
(define store (make-store))
(let loop ((rest chunks) (i 0))
  (cond
    ((null? rest)
     (display "  store-size = ") (display (store-size store)) (newline))
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
           (store-add! store id (result-value r)
                       (list (cons "text"       text)
                             (cons "path"       (cdr (assoc :path c)))
                             (cons "line-start" (cdr (assoc :line-start c)))
                             (cons "line-end"   (cdr (assoc :line-end c)))))))
       (loop (cdr rest) (+ i 1))))))

; --- 2. tools ------------------------------------------------------------

; Format top hits as a single labelled string ready for LLM consumption.
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

; Generic chat-completion caller; used by llm_chat and llm_code with
; different model names.
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

(reset-registry!)
(register-tool! 'retrieve_code retrieve-tool
                :inputs '((query . string)))
; llm_chat and llm_code both take (question, context) so the planner
; can keep the user's literal question separate from a retrieval result
; threaded in via {"input_id": "<step-id>"}.
(define (build-llm-prompt args)
  (string-append "Question: " (cdr (assoc 'question args))
                 "\n\nContext (use this to ground your answer):\n"
                 (cdr (assoc 'context args))
                 "\n\nAnswer concisely and cite line ranges from the"
                 " context where useful."))

(register-tool! 'llm_chat
                (lambda (a) (call-chat-model "llama3.1:8b"
                                             (build-llm-prompt a)))
                :inputs '((question . string) (context . string)))
(register-tool! 'llm_code
                (lambda (a) (call-chat-model "qwen2.5-coder:7b"
                                             (build-llm-prompt a)))
                :inputs '((question . string) (context . string)))

; --- 3. plan + execute ---------------------------------------------------

(banner "planning")
(define ctx-text
  (string-append "File under inspection: " file-path "\n"
                 "Recommended workflow: one retrieve_code step with a"
                 " search query derived from the question, then one"
                 " llm_code step whose 'context' arg is"
                 " {\"input_id\":\"<retrieve-step-id>\"} and whose"
                 " 'question' arg is the user's literal question."
                 " End with final-answer pointing at the llm_code step."))
(define p (plan question ctx-text))

(cond
  ((err? p)
   (display "planner failed: ") (display (err-kind p)) (display " — ")
   (display (err-message p)) (newline) (exit 1)))

(define plan-form (result-value p))
(display "  plan: ") (display plan-form) (newline)

(banner "executing")
(define exec-r (run-plan plan-form))
(cond
  ((err? exec-r)
   (display "exec failed: ") (display (err-kind exec-r)) (display " — ")
   (display (err-message exec-r)) (newline) (exit 1)))

(define final (plan-result (result-value exec-r)))
(banner "answer")
(cond
  ((err? final)
   (display "no final answer: ") (display (err-message final)) (newline)
   (exit 1))
  (else
   (display (result-value final)) (newline)))

(define elapsed-ms (- (current-time-ms) start-ms))
(display "── elapsed: ") (display elapsed-ms) (display " ms") (newline)
