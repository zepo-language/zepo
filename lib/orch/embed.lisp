; lib/orch/embed.lisp — embeddings client backed by nomic-embed-text.
;
; Wraps the Ollama OpenAI-compat /v1/embeddings endpoint. Returns the
; embedding as a Zepo vector of numbers (768 floats for nomic-embed-text).
;
; zepo-d26

(module orch/embed
  (export embed-text embed-text-with default-embed-model default-embed-url)

  (import orch/http (http-post-json))   ; zepo-y1a4

  ; Defaults — override via (embed-text-with ...) when you need to.
  (define default-embed-url   "http://localhost:11434/v1/embeddings")
  (define default-embed-model "nomic-embed-text")

  ; Embed a single text string. Returns (ok #(f1 f2 ...)) or (err kind msg).
  (define (embed-text text)
    (embed-text-with text default-embed-model default-embed-url))

  ; Explicit variant — override model or endpoint per call.
  (define (embed-text-with text model url)
    (let ((body (json-stringify
                  (list (cons "model" model)
                        (cons "input" text)))))
      (cond
        ((err? body)
         (err 'json-encode-failed (err-message body)))
        (else
         (parse-embedding-response
           (http-post-json url (result-value body) 60))))))

  ; Internal — convert (ok (cons status body-str)) from orch/http into
  ; (ok #(f1 ...)) or a typed err.
  (define (parse-embedding-response http-result)
    (cond
      ((err? http-result) http-result)  ; propagate transport errors
      (else
        (let ((status (car (result-value http-result)))
              (body   (cdr (result-value http-result))))
          (cond
            ((not (= status 200))
             (err 'http-status
                  (string-append "embeddings endpoint returned status "
                                 (number->string status)
                                 ": "
                                 (truncate-body body 200))))
            (else (extract-embedding body)))))))

  (define (extract-embedding body-str)
    (let ((parsed (json-parse body-str)))
      (cond
        ((err? parsed)
         (err 'json-parse-failed (err-message parsed)))
        (else
         (let ((root (result-value parsed)))
           (let ((data (hash-get root "data")))
             (cond
               ((not data)
                (err 'shape "response missing 'data' field"))
               ((or (not (vector? data)) (= (vector-length data) 0))
                (err 'shape "response 'data' is empty or non-array"))
               (else
                (let ((first (vector-ref data 0)))
                  (let ((emb (hash-get first "embedding")))
                    (cond
                      ((not emb)
                       (err 'shape "data[0] missing 'embedding' field"))
                      ((not (vector? emb))
                       (err 'shape "embedding is not an array"))
                      (else (ok emb))))))))))))) ; vector of numbers

  ; Helper — keep error messages bounded.
  (define (truncate-body s n)
    (if (> (string-length s) n)
        (string-append (substring s 0 n) "...")
        s)))
