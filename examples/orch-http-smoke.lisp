; orch-http-smoke.lisp — manual smoke test for lib/orch/http.lisp.
;
; Requires a local Ollama (or any HTTP server with the chat-completions
; endpoint) running on http://localhost:11434. Exits 0 if the request
; succeeds with status 200; exits 1 with a diagnostic otherwise.
;
; Run:
;   zepo examples/orch-http-smoke.lisp
;
; zepo-0p1

(import :libs (orch/http))

(define url "http://localhost:11434/v1/chat/completions")
(define body
  (string-append
    "{\"model\":\"llama3.1:8b\","
    "\"messages\":[{\"role\":\"user\",\"content\":\"reply with the single word: ok\"}],"
    "\"max_tokens\":5,\"temperature\":0}"))

(define result (http-post-json url body 30))

(cond
  ((err? result)
   (display "FAIL: ") (display (err-kind result))
   (display " — ") (display (err-message result)) (newline)
   (exit 1))
  (else
   (let ((status (car (result-value result)))
         (body   (cdr (result-value result))))
     (cond
       ((= status 200)
        (display "OK: status=200, body=") (display (string-length body))
        (display " bytes") (newline))
       (else
        (display "FAIL: status=") (display status) (newline)
        (exit 1))))))
