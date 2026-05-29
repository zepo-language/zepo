(module csvdb/api
  (export csv-open csv-select csv-insert! csv-update! csv-delete! csv-save!
          csv-row-count csv-columns)

  ;; zepo-y1a4: selective imports.
  (import csvdb/parser (emit-csv))
  (import csvdb/schema (schema-columns schema-name->index schema-delimiter
                        column-name column-default))
  (import csvdb/store  (load-table table-path table-schema table-rows
                        table-readonly? table-set-rows! table-set-dirty!
                        table-dirty?))
  (import csvdb/query  (eval-pred select-rows))

  ; ── Open ──────────────────────────────────────────────────────────────────

  (define (csv-open path opts)
    (let ((header?   (hash-get opts 'header    #t))
          (delimiter (hash-get opts 'delimiter (string-ref "," 0)))
          (readonly? (hash-get opts 'readonly  #f)))
      (load-table path header? delimiter readonly?)))

  ; ── Select ────────────────────────────────────────────────────────────────

  (define (csv-select table opts)
    (select-rows table opts))

  ; ── Insert ────────────────────────────────────────────────────────────────

  (define (csv-insert! table row-input)
    (when (table-readonly? table) (error "table is read-only"))
    (let* ((schema  (table-schema table))
           (cols    (schema-columns schema))
           (ncols   (vector-length cols))
           (new-row (make-vector ncols "")))
      (cond
        ((hash-table? row-input)
         (let insert-hash-loop ((i 0))
           (when (< i ncols)
             (let* ((col  (vector-ref cols i))
                    (name (column-name col))
                    (val  (hash-get row-input name (column-default col))))
               (vector-set! new-row i (if val val "")))
             (insert-hash-loop (+ i 1)))))
        ((vector? row-input)
         (let insert-vec-loop ((i 0))
           (when (< i (min ncols (vector-length row-input)))
             (vector-set! new-row i (vector-ref row-input i))
             (insert-vec-loop (+ i 1)))))
        (else (error "csv-insert!: row must be a hash or vector")))
      (table-set-rows! table (vector-append (table-rows table) (vector new-row)))
      (table-set-dirty! table #t)
      table))

  ; ── Update ────────────────────────────────────────────────────────────────

  (define (csv-update! table opts patch)
    (when (table-readonly? table) (error "table is read-only"))
    (let* ((where  (hash-get opts 'where #f))
           (rows   (table-rows table))
           (n->i   (schema-name->index (table-schema table))))
      (let update-loop ((i 0))
        (when (< i (vector-length rows))
          (let ((row (vector-ref rows i)))
            (when (or (not where) (eval-pred where table row))
              (hash-for-each
                (lambda (col-name val)
                  (let ((idx (hash-get n->i col-name #f)))
                    (when idx (vector-set! row idx val))))
                patch)))
          (update-loop (+ i 1)))))
    (table-set-dirty! table #t)
    table)

  ; ── Delete ────────────────────────────────────────────────────────────────

  (define (csv-delete! table opts)
    (when (table-readonly? table) (error "table is read-only"))
    (let* ((where  (hash-get opts 'where #f))
           (rows   (table-rows table))
           (kept   '()))
      (let delete-loop ((i 0))
        (when (< i (vector-length rows))
          (let ((row (vector-ref rows i)))
            (unless (and where (eval-pred where table row))
              (set! kept (cons row kept))))
          (delete-loop (+ i 1))))
      (table-set-rows! table (list->vector (reverse kept)))
      (table-set-dirty! table #t)
      table))

  ; ── Save ──────────────────────────────────────────────────────────────────

  (define (csv-save! table)
    (when (table-dirty? table)
      (let* ((path      (table-path table))
             (schema    (table-schema table))
             (delimiter (schema-delimiter schema))
             (cols      (schema-columns schema))
             (ncols     (vector-length cols))
             (data-rows (table-rows table))
             (header    (make-vector ncols ""))
             (_ (let savehdr-loop ((i 0))
                  (when (< i ncols)
                    (vector-set! header i (column-name (vector-ref cols i)))
                    (savehdr-loop (+ i 1)))))
             (all-rows  (vector-append (vector header) data-rows))
             (text      (emit-csv all-rows delimiter))
             (tmp       (string-append path ".tmp")))
        (file-write-string tmp text)
        (shell (string-append "mv " tmp " " path))
        (table-set-dirty! table #f)))
    table)

  ; ── Utilities ─────────────────────────────────────────────────────────────

  (define (csv-row-count table)
    (vector-length (table-rows table)))

  (define (csv-columns table)
    (map column-name
         (let ((cols (schema-columns (table-schema table))))
           (let columns-loop ((i 0) (acc '()))
             (if (= i (vector-length cols))
                 (reverse acc)
                 (columns-loop (+ i 1) (cons (vector-ref cols i) acc))))))))
