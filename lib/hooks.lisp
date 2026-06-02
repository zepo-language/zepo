; lib/hooks.lisp — generic extension-point hooks.
;
; A hook is a NAMED LIST OF FUNCTIONS. A library exposes a hook name; users
; register functions on it; the library runs them at the relevant point. This
; is the canonical Lisp extension-point pattern.
;
;   ;; library side:
;   (run-hooks 'before-save doc)        ; call every registered handler with doc
;
;   ;; user side:
;   (add-hook 'before-save (lambda (doc) (validate doc)))
;
; Handlers run in REGISTRATION order and each receives the args passed to
; run-hooks. See also: the `advise`/`unadvise` convention in the prelude for
; wrapping an existing function (a different mechanism); and the testing
; framework's before-each/after-each/before-all/after-all, which are a
; DELIBERATELY SEPARATE, specialized abstraction (per-describe scope tree +
; lifecycle ordering) rather than generic named lists.
(module hooks
  (export add-hook remove-hook run-hooks run-hooks/results clear-hooks)

  (define *hooks* (make-hash-table))

  ; Register fn under `name`, appended so handlers run in registration order.
  (define (add-hook name fn)
    (hash-set! *hooks* name (append (hash-get *hooks* name '()) (list fn))))

  (define (remove-hook name fn)
    (hash-set! *hooks* name
               (filter (lambda (f) (not (eq? f fn)))
                       (hash-get *hooks* name '()))))

  ; Call every handler registered under `name`, each with `args`.
  (define (run-hooks name . args)
    (for-each (lambda (f) (apply f args))
              (hash-get *hooks* name '())))

  ; Like run-hooks but returns the list of handler results (in order).
  (define (run-hooks/results name . args)
    (map (lambda (f) (apply f args))
         (hash-get *hooks* name '())))

  (define (clear-hooks name)
    (hash-set! *hooks* name '())))
