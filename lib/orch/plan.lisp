; lib/orch/plan.lisp — JSON plan schema + validator for the orchestrator.
;
; Converts a planner LLM's JSON output into the core plan forms that
; orch/exec evaluates. The validator is strict by intent: any shape
; deviation is a typed error with a JSON-pointer-style path to the bad
; node, so the planner-retry loop has something it can include in the
; next prompt.
;
; JSON shape:
;   {"type": "tool-call",    "id": "r1", "tool": "name", "args": {...}}
;   {"type": "sequence",     "steps": [...]}
;   {"type": "parallel",     "steps": [...]}
;   {"type": "final-answer", "from": "r1"}
;
; Core form (consumed by orch/exec):
;   (tool-call "r1" 'name ((key . val) ...))
;   (sequence STEP ...)
;   (parallel STEP ...)
;   (final-answer "r1")
;
; zepo-bh2

(module orch/plan
  (export plan-from-json plan-from-data)

  ; Parse JSON text and convert it to a core plan form.
  ; Returns (ok core-form) | (err 'json-parse-failed msg) | (err 'invalid-plan reason).
  (define (plan-from-json json-str)
    (let ((parsed (json-parse json-str)))
      (cond
        ((err? parsed) (err 'json-parse-failed (err-message parsed)))
        (else (plan-from-data (result-value parsed))))))

  ; Convert an already-parsed JSON value (hash-table tree as produced by
  ; json-parse) into a core form. Useful for tests that build plans
  ; programmatically without round-tripping through a string.
  (define (plan-from-data v)
    (validate v "/"))

  ; Internal: validate v at logical json-pointer `path`. Returns
  ; (ok core-form) | (err 'invalid-plan reason-string-with-path).
  (define (validate v path)
    (cond
      ((not (hash-table? v))
       (bad path "expected JSON object"))
      ((not (hash-contains? v "type"))
       (bad path "missing 'type' field"))
      (else
        (let ((t (hash-get v "type")))
          (cond
            ((not (string? t))
             (bad path "'type' must be a string"))
            ((string=? t "tool-call")    (build-tool-call    v path))
            ((string=? t "sequence")     (build-children     v path 'sequence))
            ((string=? t "parallel")     (build-children     v path 'parallel))
            ((string=? t "final-answer") (build-final-answer v path))
            (else (bad path (string-append "unknown type: " t))))))))

  ; {"type":"tool-call","id":string,"tool":string,"args":object}
  (define (build-tool-call v path)
    (cond
      ((not (and (hash-contains? v "id")
                 (hash-contains? v "tool")
                 (hash-contains? v "args")))
       (bad path "tool-call requires id, tool, args"))
      (else
        (let ((id   (hash-get v "id"))
              (tool (hash-get v "tool"))
              (args (hash-get v "args")))
          (cond
            ((not (string? id))   (bad (join path "id")   "id must be a string"))
            ((not (string? tool)) (bad (join path "tool") "tool must be a string"))
            ((not (hash-table? args))
             (bad (join path "args") "args must be an object"))
            (else
              (ok (list 'tool-call
                        id
                        (string->symbol tool)
                        (hash->alist-sym-keys args))))))))) ; convert {k:v} to ((k . v) ...)

  ; {"type":"sequence"|"parallel","steps":array}
  (define (build-children v path tag)
    (cond
      ((not (hash-contains? v "steps"))
       (bad path (string-append (symbol->string tag) " requires steps")))
      (else
        (let ((steps (hash-get v "steps")))
          (cond
            ((not (vector? steps))
             (bad (join path "steps") "steps must be an array"))
            (else
              (let ((children (validate-each steps (join path "steps") 0 '())))
                (cond
                  ((err? children) children)
                  (else
                    (ok (cons tag (reverse (result-value children))))))))))))) ; (sequence STEP STEP ...)

  ; {"type":"final-answer","from":string}
  (define (build-final-answer v path)
    (cond
      ((not (hash-contains? v "from"))
       (bad path "final-answer requires 'from'"))
      (else
        (let ((from (hash-get v "from")))
          (cond
            ((not (string? from))
             (bad (join path "from") "from must be a string"))
            (else (ok (list 'final-answer from))))))))

  ; Validate each element of a JSON array, accumulating into `acc` (reversed).
  ; Stops at the first err.
  (define (validate-each vec path i acc)
    (cond
      ((= i (vector-length vec)) (ok acc))
      (else
        (let ((child-path (join path (number->string i))))
          (let ((r (validate (vector-ref vec i) child-path)))
            (cond
              ((err? r) r)
              (else (validate-each vec path (+ i 1)
                                   (cons (result-value r) acc)))))))))

  ; ── Helpers ────────────────────────────────────────────────────────────

  (define (bad path msg)
    (err 'invalid-plan (string-append "at " path ": " msg)))

  ; Append a segment to a json-pointer-style path. "/" + "id" = "/id";
  ; "/steps" + "0" = "/steps/0".
  (define (join base seg)
    (cond
      ((string=? base "/") (string-append "/" seg))
      (else (string-append base "/" seg))))

  ; JSON objects parse as hash-tables with STRING keys; the executor's
  ; tool-call args are an alist with SYMBOL keys. Convert.
  (define (hash->alist-sym-keys ht)
    (let ((al (hash->alist ht))
          (result '()))
      (for-each
        (lambda (kv)
          (let ((k (car kv)) (v (cdr kv)))
            (set! result (cons (cons (string->symbol k) v) result))))
        al)
      (reverse result))))
