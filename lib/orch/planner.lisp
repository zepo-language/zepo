; lib/orch/planner.lisp — local LLM planner client.
;
; Wraps an Ollama-compatible /v1/chat/completions endpoint as a JSON plan
; generator. Uses the live tool registry to enumerate available tools in
; the prompt, validates the model's output via orch/plan, and retries on
; parse/validation failure with the prior bad output + diagnostic fed back
; into the next prompt.
;
; zepo-gp5

(module orch/planner
  (export plan plan-with
          default-planner-model default-planner-url default-retries
          build-system-prompt)

  (import orch/http)
  (import orch/plan)
  (import orch/registry)

  (define default-planner-model "llama3.1:8b")
  (define default-planner-url   "http://localhost:11434/v1/chat/completions")
  (define default-retries       3)

  ; Top-level: ask the planner to turn (goal, context) into a core plan.
  ; Returns (ok core-form) | (err 'plan-invalid msg) | (err 'http-failed msg).
  (define (plan goal context)
    (plan-with goal context default-planner-model default-planner-url default-retries))

  (define (plan-with goal context model url retries)
    (let ((system (build-system-prompt)))
      (try-plan goal context system model url retries
                #f       ; prior-bad-output
                #f)))    ; prior-error-msg

  ; Recursive retry loop. attempt 1..retries; on failure we include the
  ; previous response + reason in the next user message so the model has
  ; something concrete to correct against.
  (define (try-plan goal context system model url remaining prev-out prev-err)
    (cond
      ((<= remaining 0)
       (err 'plan-invalid
            (string-append "exhausted retries; last error: "
                           (if prev-err prev-err "<none>"))))
      (else
        (let ((user-msg (build-user-prompt goal context prev-out prev-err)))
          (let ((resp (call-model model url system user-msg)))
            (cond
              ((err? resp) resp)   ; transport error — don't retry
              (else
                (let* ((content (result-value resp))
                       (cleaned (strip-code-fences content))
                       (validated (plan-from-json cleaned)))
                  (cond
                    ((ok? validated) validated)
                    (else
                     ; Retry with diagnostic.
                     (try-plan goal context system model url
                               (- remaining 1)
                               content
                               (err-message validated))))))))))))

  ; ── Prompt construction ───────────────────────────────────────────────────

  ; Build the system message. Enumerates registered tools and shows the
  ; core plan grammar. Conservative — explicit "JSON only" instructions and
  ; an example.
  (define (build-system-prompt)
    (string-append
      "You are a plan generator for a tool-orchestration runtime.\n"
      "OUTPUT JSON ONLY. No prose, no commentary, no markdown fences.\n"
      "\n"
      "Available tools:\n"
      (format-tool-catalog (list-tools))
      "\n"
      "Plan grammar (one top-level object):\n"
      "  {\"type\":\"tool-call\",    \"id\":\"<id>\", \"tool\":\"<name>\", \"args\":{...}}\n"
      "  {\"type\":\"sequence\",     \"steps\":[<plan>, ...]}\n"
      "  {\"type\":\"parallel\",     \"steps\":[<plan>, ...]}\n"
      "  {\"type\":\"final-answer\", \"from\":\"<id>\"}\n"
      "\n"
      "Threading outputs between steps:\n"
      "  An arg value that is the JSON object {\"input_id\":\"<step-id>\"}\n"
      "  is replaced at execution time with the ok-value of that prior\n"
      "  step. Use this to pass a retrieval tool's result into a\n"
      "  synthesis tool's input. The object must be the whole arg value,\n"
      "  not embedded inside a larger string.\n"
      "\n"
      "Rules:\n"
      "- Never invent tools. Use only the tools listed above.\n"
      "- Prefer retrieval (tools whose name starts with \"retrieve_\") before synthesis.\n"
      "- Use parallel ONLY when steps are independent.\n"
      "- Keep step count minimal.\n"
      "- Every plan that produces a user-facing answer must end with a final-answer step.\n"))

  (define (format-tool-catalog names)
    (cond
      ((null? names) "  (registry is empty)\n")
      (else
        (let ((acc ""))
          (for-each
            (lambda (n)
              (set! acc
                (string-append acc "  - " (symbol->string n)
                               (format-tool-inputs (lookup-tool n))
                               "\n")))
            names)
          acc))))

  ; "(query: string, k: integer)" given a registry entry vector.
  (define (format-tool-inputs entry)
    (cond
      ((not entry) "")
      (else
        (let ((inputs (vector-ref entry 1)))
          (cond
            ((null? inputs) "()")
            (else
              (let ((parts '()))
                (for-each
                  (lambda (kv)
                    (set! parts
                      (cons (string-append (symbol->string (car kv))
                                           ": "
                                           (symbol->string (cdr kv)))
                            parts)))
                  inputs)
                (string-append "("
                               (string-join (reverse parts) ", ")
                               ")"))))))))

  (define (build-user-prompt goal context prev-out prev-err)
    (let ((base
           (string-append
             "Goal:\n" goal "\n"
             (if (and context (not (string=? context "")))
                 (string-append "\nContext:\n" context "\n")
                 "")
             "\nReturn a single JSON plan object.\n")))
      (cond
        ((not prev-out) base)
        (else
          (string-append
            base
            "\nThe previous plan you returned was INVALID:\n"
            "----- previous output -----\n"
            prev-out
            "\n----- error -----\n"
            prev-err
            "\nReturn a corrected JSON plan only.\n")))))

  ; ── HTTP + response parsing ──────────────────────────────────────────────

  ; POST to /v1/chat/completions, return (ok content-string) or (err ...).
  (define (call-model model url system-msg user-msg)
    (let ((body (build-request-body model system-msg user-msg)))
      (cond
        ((err? body) body)
        (else
          (let ((resp (http-post-json url (result-value body) 120)))
            (cond
              ((err? resp) resp)
              (else (extract-content (result-value resp)))))))))

  ; Build the OpenAI-compat chat completion request as a JSON string.
  (define (build-request-body model system-msg user-msg)
    (json-stringify
      (list (cons "model" model)
            (cons "temperature" 0)
            (cons "max_tokens" 2048)
            (cons "messages"
                  (vector
                    (list (cons "role" "system") (cons "content" system-msg))
                    (list (cons "role" "user")   (cons "content" user-msg)))))))

  ; (status . body-str) -> (ok content-string) or (err ...)
  ; Flatten the nested object walk into a chain of helpers; each step
  ; either short-circuits on an err or delegates to the next.
  (define (extract-content status-body)
    (let ((status (car status-body)) (body (cdr status-body)))
      (cond
        ((not (= status 200))
         (err 'http-status
              (string-append "chat completion returned status "
                             (number->string status))))
        (else (extract-from-body body)))))

  (define (extract-from-body body)
    (let ((parsed (json-parse body)))
      (cond
        ((err? parsed) (err 'response-parse (err-message parsed)))
        (else (extract-from-root (result-value parsed))))))

  (define (extract-from-root root)
    (cond
      ((not (hash-table? root))
       (err 'response-shape "response is not a JSON object"))
      (else
        (let ((choices (hash-get root "choices")))
          (cond
            ((or (not (vector? choices)) (= (vector-length choices) 0))
             (err 'response-shape "no choices in response"))
            (else (extract-from-choice (vector-ref choices 0))))))))

  (define (extract-from-choice choice)
    (cond
      ((not (hash-table? choice))
       (err 'response-shape "choice is not an object"))
      (else
        (let ((msg (hash-get choice "message")))
          (cond
            ((not (hash-table? msg))
             (err 'response-shape "choice missing 'message'"))
            (else
              (let ((content (hash-get msg "content")))
                (cond
                  ((not (string? content))
                   (err 'response-shape "'message.content' is not a string"))
                  (else (ok content))))))))))

  ; Strip ```json ... ``` fences models love to add despite instructions.
  ; Permissive — returns the substring between the first { and matching last }.
  (define (strip-code-fences s)
    (let ((first-brace (find-char s "{" 0))
          (last-brace  (find-char-right s "}" (- (string-length s) 1))))
      (cond
        ((and first-brace last-brace (<= first-brace last-brace))
         (substring s first-brace (+ last-brace 1)))
        (else s))))

  (define (find-char s ch start)
    (let loop ((i start) (len (string-length s)))
      (cond
        ((>= i len) #f)
        ((equal? (string-ref s i) (string-ref ch 0)) i)
        (else (loop (+ i 1) len)))))

  (define (find-char-right s ch start)
    (let loop ((i start))
      (cond
        ((< i 0) #f)
        ((equal? (string-ref s i) (string-ref ch 0)) i)
        (else (loop (- i 1)))))))
