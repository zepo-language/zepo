; lib/orch/research.lisp — multi-hop code research over a cross-file corpus.
;
; Reuses the ReAct loop (orch/agent) in READ-ONLY mode over an orch/corpus
; vector store. The loop's planner gets two tools:
;
;   retrieve_code {query}  — semantic store-search; appends top hits to a
;                            shared accumulator and returns a summary.
;   grep_code {pattern}    — exact, in-process substring scan over the
;                            source files (no shell); appends matches.
;
; The loop retrieves to locate an area, greps to chase the exact symbol a
; hit referenced, and finishes when it has gathered enough. Because the
; tools both append to the accumulator, a DEDICATED synthesis step can read
; all gathered context directly (no need to thread ctx out of run-agent)
; and a code model writes the final grounded answer.
;
; Read-only: no mutating tools, so the approval gate and verify rule never
; fire. next-step / embed-fn / synth-fn are injected so the whole flow is
; testable without Ollama.
;
; zepo-t40

(module orch/research
  (export research research-with grep-sources)

  (import orch/registry)
  (import orch/agent)
  (import orch/embed)
  (import orch/vector_store)
  (import orch/planner)
  (import orch/http)

  (define max-research-iters 6)      ; bound iterations (and transcript growth)
  (define retrieve-k         6)      ; hits per retrieve_code call
  (define max-hit-chars      500)    ; truncate each chunk in the transcript
  (define max-grep-matches   25)     ; cap grep output
  (define default-code-model "qwen2.5-coder:7b")
  (define default-chat-url   "http://localhost:11434/v1/chat/completions")

  ; research goal sources store -> (ok answer) | (err ...)
  ; sources: the corpus file paths (grep scans them). store: the vector index.
  (define (research goal sources store)
    (research-with goal sources store
                   (default-next-step)
                   embed-text
                   (default-synth)))

  ; The testable core. next-step : (goal history ctx) -> action | (err ...).
  ; embed-fn : text -> (ok vec). synth-fn : (goal context-string) -> (ok answer).
  (define (research-with goal sources store next-step embed-fn synth-fn)
    (let ((acc (vector '())))                       ; accumulator: reversed list
      (setup-tools! store sources acc embed-fn)
      ; zepo-546: seed the accumulator with a retrieve for the goal so the
      ; synthesis ALWAYS has grounded context — the loop's planner often
      ; finishes without retrieving (it sees a generic "prefer finish"
      ; prompt), which left synthesis with empty context and hallucinating.
      ; The loop below then refines with additional hops.
      (call-tool (lookup-tool 'retrieve_code) (list (cons 'query goal)))
      (run-agent goal max-research-iters next-step) ; read-only; gather into acc
      (synth-fn goal (accumulator->string acc))))

  (define (setup-tools! store sources acc embed-fn)
    (reset-registry!)
    (register-tool! 'retrieve_code (make-retrieve store acc embed-fn)
                    :inputs '((query . string)) :effect 'read)
    (register-tool! 'grep_code (make-grep sources acc)
                    :inputs '((pattern . string)) :effect 'read))

  (define (make-retrieve store acc embed-fn)
    (lambda (args)
      (let ((q (cdr (assoc 'query args))))
        (let ((qe (embed-fn q)))
          (cond
            ((err? qe) qe)
            (else
              (let ((text (format-hits (store-search store (result-value qe) retrieve-k))))
                (acc-append! acc (string-append "retrieve \"" q "\":\n" text))
                (ok text))))))))

  (define (make-grep sources acc)
    (lambda (args)
      (let* ((pat  (cdr (assoc 'pattern args)))
             (text (format-grep (grep-sources pat sources))))
        (acc-append! acc (string-append "grep \"" pat "\":\n" text))
        (ok text))))

  ; ── grep-sources (pure) ─────────────────────────────────────────────────────

  ; pattern sources -> list of (path line-no line-text), in file/line order.
  (define (grep-sources pattern sources)
    (let loop ((ss sources) (out '()))
      (cond
        ((null? ss) (reverse out))
        (else (loop (cdr ss) (grep-file pattern (car ss) out))))))

  ; Prepend matches in `path` onto out (so a final reverse yields order).
  ; zepo-t40: read line-by-line via an input port rather than
  ; file-read-string + string-split. Whole-file reads under heap pressure
  ; trip a GC-corruption bug (zepo-jus); streaming keeps peak allocation
  ; low, avoids it, and is cheaper anyway.
  (define (grep-file pattern path out)
    (let ((p (open-input-file path)))
      (let loop ((line (read-line p)) (n 1) (out out))
        (cond
          ((eof-object? line) (close-input-port p) out)
          (else
            (loop (read-line p) (+ n 1)
                  (if (string-contains line pattern)
                      (cons (list path n line) out)
                      out)))))))

  ; ── formatting + accumulator ────────────────────────────────────────────────

  (define (format-hits hits)
    (let loop ((hs hits) (acc ""))
      (cond
        ((null? hs) (if (string=? acc "") "(no hits)" acc))
        (else
          (let* ((meta (cdr (cdr (car hs))))
                 (path (hash-get meta "path"))
                 (ls   (hash-get meta "line-start"))
                 (le   (hash-get meta "line-end"))
                 (txt  (truncate-str (hash-get meta "text") max-hit-chars)))
            (loop (cdr hs)
                  (string-append acc
                                 path ":" (number->string ls) "-" (number->string le)
                                 "\n" txt "\n---\n")))))))

  (define (truncate-str s n)
    (if (> (string-length s) n)
        (string-append (substring s 0 n) " …[truncated]")
        s))

  (define (format-grep hits)
    (let loop ((hs hits) (k 0) (acc ""))
      (cond
        ((null? hs) (if (string=? acc "") "(no matches)" acc))
        ((>= k max-grep-matches)
         (string-append acc "…[more matches truncated]\n"))
        (else
          (let ((h (car hs)))                       ; (path line-no line-text)
            (loop (cdr hs) (+ k 1)
                  (string-append acc
                                 (car h) ":" (number->string (car (cdr h)))
                                 ": " (truncate-str (car (cdr (cdr h))) 200) "\n")))))))

  (define (acc-append! acc s)
    (vector-set! acc 0 (cons s (vector-ref acc 0))))

  (define (accumulator->string acc)
    (string-join (reverse (vector-ref acc 0)) "\n\n"))

  ; ── default planner + synthesis (Ollama) ────────────────────────────────────

  (define (default-next-step)
    (lambda (goal history ctx)
      (let ((r (plan-next-step-with goal history
                                    default-code-model default-chat-url default-retries)))
        (if (ok? r) (result-value r) r))))

  (define (default-synth)
    (lambda (goal context)
      ; zepo-546: strict-grounding prompt. The model was given correct code
      ; chunks yet hallucinated a Python answer for a Lisp codebase, so spell
      ; out: answer ONLY from the context, never invent files/functions/
      ; languages, refuse when the context lacks the answer.
      (chat default-code-model default-chat-url
            (string-append
              "You are a precise code assistant. Answer the QUESTION using the\n"
              "RETRIEVED CONTEXT below — real source code from THIS repository.\n"
              "- Explain the relevant code that is shown. Quote real identifiers\n"
              "  and cite their file:line ranges.\n"
              "- Do NOT invent files, functions, classes, languages, or APIs that\n"
              "  are not present in the context. Use only names that appear there.\n"
              "- Only if the context is clearly unrelated to the question, say it\n"
              "  does not contain the answer — otherwise explain the code.\n"
              "\n"
              "QUESTION:\n" goal "\n\n"
              "RETRIEVED CONTEXT (real code from this repo):\n"
              context "\n\n"
              "ANSWER:"))))

  ; Minimal /v1/chat/completions call -> (ok content) | (err ...).
  (define (chat model url prompt)
    (let ((body (json-stringify
                  (list (cons "model" model)
                        (cons "temperature" 0)
                        (cons "max_tokens" 1024)
                        (cons "messages"
                              (vector (list (cons "role" "user")
                                            (cons "content" prompt))))))))
      (cond
        ((err? body) (err 'json-encode (err-message body)))
        (else
          (let ((r (http-post-json url (result-value body) 180)))
            (cond
              ((err? r) r)
              (else (chat-content (result-value r)))))))))

  (define (chat-content sb)
    (let ((status (car sb)) (body (cdr sb)))
      (cond
        ((not (= status 200))
         (err 'http-status (string-append "status " (number->string status))))
        (else
          (let ((p (json-parse body)))
            (cond
              ((err? p) p)
              (else
                (let ((choices (hash-get (result-value p) "choices")))
                  (cond
                    ((or (not (vector? choices)) (= (vector-length choices) 0))
                     (err 'shape "no choices"))
                    (else
                      (let* ((msg (hash-get (vector-ref choices 0) "message"))
                             (content (and msg (hash-get msg "content"))))
                        (if (string? content) (ok content)
                            (err 'shape "no message.content"))))))))))))))
