(module hooks
  (export add-hook remove-hook run-hooks run-hooks/results
          defadvice remove-advice advised?)

  ; ── Hooks ────────────────────────────────────────────────────────────────────

  (define *hooks* (make-hash-table))

  (define (add-hook name fn)
    (hash-set! *hooks* name
               (cons fn (hash-get *hooks* name '()))))

  (define (remove-hook name fn)
    (hash-set! *hooks* name
               (filter (lambda (f) (not (eq? f fn)))
                       (hash-get *hooks* name '()))))

  (define (run-hooks name)
    (for-each (lambda (f) (f))
              (hash-get *hooks* name '())))

  (define (run-hooks/results name)
    (map (lambda (f) (f))
         (hash-get *hooks* name '())))

  ; ── Advice ───────────────────────────────────────────────────────────────────

  (define *advice-registry* (make-hash-table))

  (define (%make-wrapper orig type advice-fn)
    (cond
      ((equal? type ':before)
       (lambda args
         (apply advice-fn args)
         (apply orig args)))
      ((equal? type ':after)
       (lambda args
         (let ((result (apply orig args)))
           (apply advice-fn (cons result args))
           result)))
      ((equal? type ':around)
       (lambda args
         (apply advice-fn (cons orig args))))
      ((equal? type ':override)
       advice-fn)
      (else (error "unknown advice type" type))))

  ; defadvice wraps an existing global function.
  ; type: ':before ':after ':around ':override
  ; :before  — (advice-fn . original-args), return value ignored
  ; :after   — (advice-fn result . original-args), return value ignored
  ; :around  — (advice-fn original-fn . args), must call original-fn explicitly
  ; :override — advice-fn replaces the function entirely
  (defmacro defadvice (name type fn-expr)
    `(let ((%orig ,name))
       (define ,name (%make-wrapper %orig ,type ,fn-expr))
       (hash-set! *advice-registry* ',name %orig)))

  (defmacro remove-advice (name)
    `(when (hash-contains? *advice-registry* ',name)
       (define ,name (hash-get *advice-registry* ',name #f))
       (hash-delete! *advice-registry* ',name)))

  (define (advised? name)
    (hash-contains? *advice-registry* name)))
