; lib/orch/registry.lisp — symbolic tool registry for the orchestrator.
;
; Tools are functions exposed to the planner. The registry holds them
; behind a name -> entry mapping and enforces a small input-schema check
; before invocation. Tool output is treated as opaque by the registry —
; the executor is responsible for routing it.
;
; zepo-acn

(module orch/registry
  (export register-tool! lookup-tool unregister-tool! list-tools
          validate-args call-tool reset-registry! tool-effect)

  ;; The registry is process-global. Lives in a one-element vector so the
  ;; (mutable) hash-table behind it can be rebuilt by reset-registry!
  ;; without re-binding the top-level variable from outside the module.
  (define registry (vector (make-hash-table)))

  (define (registry-table) (vector-ref registry 0))

  (define (reset-registry!)
    (vector-set! registry 0 (make-hash-table)))

  ; Register a tool.
  ;
  ;   (register-tool! 'retrieve_docs fn
  ;     :inputs  '((query . string) (k . integer))
  ;     :outputs '((hits . list)))
  ;
  ; fn takes a single argument — an alist of (arg-name . value) — and
  ; returns a portable value. The arg-name keys in the input alist must
  ; be symbols. Existing entries with the same name are overwritten.
  ; zepo-0rs: :effect tags a tool's side-effect class — 'read (default),
  ; 'mutating, or 'verify. The plan validator reads it to require a
  ; verify step after every mutating step. Stored at entry index 3.
  (define (register-tool! name fn . kvs)
    (let ((inputs  (kv-get kvs ':inputs  '()))
          (outputs (kv-get kvs ':outputs '()))
          (effect  (kv-get kvs ':effect  'read)))
      (hash-set! (registry-table) name (vector fn inputs outputs effect))
      name))

  (define (unregister-tool! name)
    (hash-delete! (registry-table) name))

  ; Returns entry vector #(fn inputs outputs) or #f.
  (define (lookup-tool name)
    (hash-get (registry-table) name))

  ; zepo-0rs: a tool's effect class, or 'read for unknown tools (no
  ; constraint imposed on tools the validator doesn't recognise).
  (define (tool-effect name)
    (let ((entry (lookup-tool name)))
      (if entry (vector-ref entry 3) 'read)))

  (define (list-tools)
    (let ((names '()))
      (hash-for-each (lambda (k v) (set! names (cons k names)))
                     (registry-table))
      names))

  ; Validate args against an entry's input schema.
  ; Returns (ok args) if every required schema field is present with the
  ; declared type; (err 'invalid-args msg) otherwise.
  ; v1: every schema field is required. No optional fields or defaults.
  (define (validate-args entry args)
    (let ((inputs (vector-ref entry 1)))
      (check-schema inputs args)))

  (define (check-schema schema args)
    (cond
      ((null? schema) (ok args))
      ((not (pair? schema)) (err 'invalid-schema "schema must be an alist"))
      (else
        (let ((field (car schema)))
          (cond
            ((not (pair? field))
             (err 'invalid-schema "schema field must be (name . type)"))
            (else
              (let ((name (car field))
                    (type (cdr field)))
                (let ((val (assoc-cdr name args)))
                  (cond
                    ((not val)
                     (err 'invalid-args
                          (string-append "missing required arg: "
                                         (sym->str name))))
                    ((not (type-match? type val))
                     (err 'invalid-args
                          (string-append "arg "
                                         (sym->str name)
                                         " expected "
                                         (sym->str type)
                                         ", got "
                                         (describe-value val))))
                    (else (check-schema (cdr schema) args)))))))))))

  ; Type predicates. 'any matches everything.
  (define (type-match? t v)
    (cond
      ((eq? t 'any)        #t)
      ((eq? t 'string)     (string? v))
      ((eq? t 'integer)    (integer? v))
      ((eq? t 'number)     (number? v))
      ((eq? t 'boolean)    (boolean? v))
      ((eq? t 'symbol)     (symbol? v))
      ((eq? t 'list)       (or (null? v) (pair? v)))
      ((eq? t 'vector)     (vector? v))
      ((eq? t 'hash-table) (hash-table? v))
      (else #f)))

  ; Look up the cdr of a (name . val) pair in an alist. Returns #f if
  ; absent. Distinguishes 'absent' from a literal #f value: callers that
  ; care about #f-as-value should use (assoc name alist) directly. The
  ; registry treats #f as "missing" in v1.
  (define (assoc-cdr key alist)
    (let ((pair (assoc key alist)))
      (and pair (cdr pair))))

  ; Validate then invoke. Tool functions may either return a result tuple
  ; (ok v) / (err k m) directly, return a bare value (auto-wrapped in ok),
  ; or raise an exception (caught via guard and surfaced as
  ; (err 'tool-failure msg)).
  ;
  ; Note: this used to be ungarded because of zepo-9bi (guard ate fiber
  ; yields). That VM bug is fixed; guard now plays correctly with sleep,
  ; HTTP, channel-recv!, and other yielding ops, so we can restore
  ; exception isolation around tool calls.
  (define (call-tool entry args)
    (let ((checked (validate-args entry args)))
      (cond
        ((err? checked) checked)
        (else
          (let ((fn (vector-ref entry 0)))
            (guard (exn
                    ((error-object? exn)
                     (err 'tool-failure (error-object-message exn)))
                    ((string? exn) (err 'tool-failure exn))
                    (else (err 'tool-failure "tool raised a non-error value")))
              (let ((raw (fn args)))
                (cond
                  ((or (ok? raw) (err? raw)) raw)
                  (else (ok raw))))))))))

  ; ── Helpers ────────────────────────────────────────────────────────────

  (define (kv-get kvs key default)
    (cond
      ((null? kvs) default)
      ((null? (cdr kvs)) default)
      ((eq? (car kvs) key) (car (cdr kvs)))
      (else (kv-get (cdr (cdr kvs)) key default))))

  (define (sym->str x)
    (cond
      ((symbol? x) (symbol->string x))
      ((string? x) x)
      (else "?")))

  (define (describe-value v)
    (cond
      ((string? v)     "string")
      ((integer? v)    "integer")
      ((number? v)     "number")
      ((boolean? v)    "boolean")
      ((symbol? v)     "symbol")
      ((vector? v)     "vector")
      ((null? v)       "()")
      ((pair? v)       "list")
      ((hash-table? v) "hash-table")
      (else            "other"))))
