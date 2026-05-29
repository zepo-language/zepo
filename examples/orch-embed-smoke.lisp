; orch-embed-smoke.lisp — manual smoke test for lib/orch/embed.lisp.
;
; Requires a local Ollama with nomic-embed-text pulled. Exits 0 if the
; embedding is returned as a non-empty number vector; exits 1 otherwise.
;
; Run:
;   zepo examples/orch-embed-smoke.lisp
;
; zepo-d26

(import :libs (orch/embed (embed-text))) ; zepo-y1a4

(define r (embed-text "hello world"))

(cond
  ((err? r)
   (display "FAIL: ") (display (err-kind r))
   (display " — ") (display (err-message r)) (newline)
   (exit 1))
  (else
   (let ((v (result-value r)))
     (cond
       ((or (not (vector? v)) (= (vector-length v) 0))
        (display "FAIL: empty or non-vector embedding") (newline)
        (exit 1))
       (else
        (display "OK: dim=") (display (vector-length v))
        (display " first=") (display (vector-ref v 0)) (newline))))))
