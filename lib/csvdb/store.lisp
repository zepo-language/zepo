(module csvdb/store
  (export make-table load-table
          table-path table-schema table-rows table-dirty? table-readonly?
          table-set-rows! table-set-dirty!
          row-ref row-set! row->map)

  (import csvdb/parser)
  (import csvdb/schema)

  ; ── Table record ──────────────────────────────────────────────────────────

  (define (make-table path schema rows readonly?)
    (let ((h (make-hash-table)))
      (hash-set! h 'path     path)
      (hash-set! h 'schema   schema)
      (hash-set! h 'rows     rows)
      (hash-set! h 'dirty?   #f)
      (hash-set! h 'readonly? readonly?)
      h))

  (define (table-path     t) (hash-get t 'path     #f))
  (define (table-schema   t) (hash-get t 'schema   #f))
  (define (table-rows     t) (hash-get t 'rows     #f))
  (define (table-dirty?   t) (hash-get t 'dirty?   #f))
  (define (table-readonly? t) (hash-get t 'readonly? #f))

  (define (table-set-rows! t rows)
    (hash-set! t 'rows rows))

  (define (table-set-dirty! t val)
    (hash-set! t 'dirty? val))

  ; ── Loading ───────────────────────────────────────────────────────────────

  (define (load-table path header? delimiter readonly?)
    (let* ((text      (file-read-string path))
           (all-rows  (parse-csv text delimiter))
           (schema    (infer-schema all-rows header? delimiter))
           (data-rows (if (and header? (> (vector-length all-rows) 0))
                          (vector-copy all-rows 1)
                          all-rows))
           (coerced   (make-vector (vector-length data-rows) #f)))
      (let load-loop ((i 0))
        (when (< i (vector-length data-rows))
          (vector-set! coerced i (coerce-row schema (vector-ref data-rows i)))
          (load-loop (+ i 1))))
      (make-table path schema coerced readonly?)))

  ; ── Row accessors ─────────────────────────────────────────────────────────

  (define (row-ref table row col-name)
    (let ((idx (hash-get (schema-name->index (table-schema table)) col-name #f)))
      (if idx
          (vector-ref row idx)
          (error "unknown column" col-name))))

  (define (row-set! table row col-name val)
    (let ((idx (hash-get (schema-name->index (table-schema table)) col-name #f)))
      (if idx
          (vector-set! row idx val)
          (error "unknown column" col-name))
      (table-set-dirty! table #t)))

  (define (row->map table row)
    (let ((h    (make-hash-table))
          (cols (schema-columns (table-schema table))))
      (let rowmap-loop ((i 0))
        (when (< i (vector-length cols))
          (hash-set! h (column-name (vector-ref cols i)) (vector-ref row i))
          (rowmap-loop (+ i 1))))
      h)))
