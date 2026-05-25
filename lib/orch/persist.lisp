; lib/orch/persist.lisp — save / load a plan run's ctx for replay & resume.
;
; The executor's ctx is an alist of (id . result) where result is
; (ok . value) or (err kind msg). That alist IS the run's checkpoint:
; persist it and you can replay a finished run, or seed a partial ctx
; back into run-plan to resume from where an interrupted run left off.
;
; Persisted as JSON (Zepo has no read-from-string primitive, so an
; s-expr format can't round-trip; JSON has both halves — see
; vector_store.lisp for the same tradeoff). Shape is an array of rows:
;   {"id": "x", "ok": <json value>}            ; a successful step
;   {"id": "x", "err": "kind", "msg": "..."}   ; a failed step
; Order is preserved so a reloaded ctx is identical to the original.
;
; zepo-qjk

(module orch/persist
  (export save-ctx load-ctx)

  ; Serialize ctx to PATH as JSON. Returns (ok row-count) | (err ...).
  (define (save-ctx path ctx)
    (let* ((rows (map ctx-entry->row ctx))
           (js   (json-stringify (list->vector rows))))
      (cond
        ((err? js) js)
        (else
          (file-write-string path (result-value js))
          (ok (length rows))))))

  ; Reload a ctx from PATH. Returns (ok ctx) | (err ...).
  (define (load-ctx path)
    (let ((parsed (json-parse (file-read-string path))))
      (cond
        ((err? parsed) (err 'load-failed (err-message parsed)))
        (else (rebuild-ctx (result-value parsed))))))

  ; ── Helpers ────────────────────────────────────────────────────────────

  ; (id . result) -> a JSON-able hash-table row.
  (define (ctx-entry->row entry)
    (let ((id  (car entry))
          (res (cdr entry))
          (h   (make-hash-table)))
      (hash-set! h "id" id)
      (cond
        ((err? res)
         (hash-set! h "err" (symbol->string (err-kind res)))
         (hash-set! h "msg" (err-message res)))
        (else
         (hash-set! h "ok" (result-value res))))
      h))

  ; JSON array (parsed as a vector of hash-tables) -> ctx alist, in order.
  (define (rebuild-ctx rows)
    (cond
      ((not (vector? rows)) (err 'shape "top-level must be a JSON array"))
      (else
        (let loop ((i 0) (acc '()))
          (cond
            ((= i (vector-length rows)) (ok (reverse acc)))
            (else
              (loop (+ i 1)
                    (cons (row->ctx-entry (vector-ref rows i)) acc))))))))

  (define (row->ctx-entry row)
    (let ((id (hash-get row "id")))
      (cond
        ((hash-contains? row "err")
         (cons id (err (string->symbol (hash-get row "err"))
                       (hash-get row "msg"))))
        (else
         (cons id (ok (hash-get row "ok"))))))))
