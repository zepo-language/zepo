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
  (export plan-from-json plan-from-data
          plan-step-from-json plan-step-from-data)

  (import orch/registry)   ; zepo-0rs: tool-effect, for the verify rule

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
  ; zepo-m4z: validate a SINGLE ReAct action (one tool-call or finish)
  ; structurally only. A one-action plan is inherently "bare", so the
  ; within-sequence verify rule cannot apply here — orch/agent enforces
  ; the verify invariant across turns instead. The full-DAG validators
  ; (plan-from-json / plan-from-data) are unchanged and still enforce it.
  (define (plan-step-from-json json-str)
    (let ((parsed (json-parse json-str)))
      (cond
        ((err? parsed) (err 'json-parse-failed (err-message parsed)))
        (else (plan-step-from-data (result-value parsed))))))

  (define (plan-step-from-data v)
    (validate v "/"))

  (define (plan-from-data v)
    (let ((r (validate v "/")))
      (cond
        ((err? r) r)
        ; zepo-0rs: structurally valid — now enforce that every mutating
        ; step is verified. Rejection reuses the (err 'invalid-plan
        ; "at PATH: msg") shape so the planner retry loop handles it the
        ; same as any other validation failure.
        (else
          (let ((chk (enforce-verify (result-value r) "/")))
            (cond
              ((err? chk) chk)
              (else r)))))))

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
            ((string=? t "finish")       (build-finish       v path))
            (else (bad path (string-append "unknown type: " t))))))))

  ; zepo-fao: {"type":"finish","text":string} — the ReAct loop's terminal
  ; form. Tells run-agent to stop and return `text` as the answer.
  (define (build-finish v path)
    (cond
      ((not (hash-contains? v "text"))
       (bad path "finish requires 'text'"))
      (else
        (let ((text (hash-get v "text")))
          (cond
            ((not (string? text))
             (bad (join path "text") "text must be a string"))
            (else (ok (list 'finish text))))))))

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

  ; ── Verify-after-mutation rule (zepo-0rs) ───────────────────────────────
  ;
  ; Walk a structurally-valid core form. A mutating tool-call must be
  ; followed by a verify tool-call in the same sequence; a bare mutating
  ; tool-call (no enclosing sequence to provide a verify) is rejected; a
  ; mutating tool-call directly inside a parallel is rejected in v1 (no
  ; well-defined "after" within a concurrent batch). Read/verify steps
  ; and final-answer impose no constraint. Returns (ok #t) | (err ...).
  (define (enforce-verify form path)
    (cond
      ((not (pair? form)) (ok #t))
      (else
        (let ((tag (car form)))
          (cond
            ((eq? tag 'tool-call)
             (if (mutating? (tool-name form))
                 (bad path "mutating tool-call must be followed by a verify step in the same sequence")
                 (ok #t)))
            ((eq? tag 'sequence)  (check-sequence (cdr form) path 0))
            ((eq? tag 'parallel)  (check-parallel (cdr form) path 0))
            (else (ok #t)))))))

  ; Each mutating tool-call needs a later verify tool-call at this level;
  ; nested sequence/parallel children are recursed into for their own
  ; mutations.
  (define (check-sequence steps path i)
    (cond
      ((null? steps) (ok #t))
      (else
        (let ((step (car steps))
              (rest (cdr steps))
              (child-path (join path (number->string i))))
          (cond
            ((and (tool-call? step) (mutating? (tool-name step)))
             (cond
               ((verify-follows? rest) (check-sequence rest path (+ i 1)))
               (else (bad child-path "mutating tool-call must be followed by a verify step in the same sequence"))))
            ((nested? step)
             (let ((r (enforce-verify step child-path)))
               (cond ((err? r) r)
                     (else (check-sequence rest path (+ i 1))))))
            (else (check-sequence rest path (+ i 1))))))))

  (define (check-parallel steps path i)
    (cond
      ((null? steps) (ok #t))
      (else
        (let ((step (car steps))
              (child-path (join path (number->string i))))
          (cond
            ((and (tool-call? step) (mutating? (tool-name step)))
             (bad child-path "mutating tool-call not allowed inside parallel (v1): wrap it in a sequence with a verify step"))
            ((nested? step)
             (let ((r (enforce-verify step child-path)))
               (cond ((err? r) r)
                     (else (check-parallel (cdr steps) path (+ i 1))))))
            (else (check-parallel (cdr steps) path (+ i 1))))))))

  ; Is there a verify tool-call anywhere later in this list of steps?
  (define (verify-follows? steps)
    (cond
      ((null? steps) #f)
      ((and (tool-call? (car steps)) (verify? (tool-name (car steps)))) #t)
      (else (verify-follows? (cdr steps)))))

  (define (tool-call? f) (and (pair? f) (eq? (car f) 'tool-call)))
  (define (nested? f)
    (and (pair? f) (or (eq? (car f) 'sequence) (eq? (car f) 'parallel))))
  ; core tool-call form is (tool-call ID NAME ARGS).
  (define (tool-name f) (car (cdr (cdr f))))
  (define (mutating? name) (eq? (tool-effect name) 'mutating))
  (define (verify? name)   (eq? (tool-effect name) 'verify))

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
