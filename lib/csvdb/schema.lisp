(module csvdb/schema
  (export make-column make-schema infer-schema coerce-field coerce-row
          schema-columns schema-name->index schema-header? schema-delimiter
          column-name column-index column-type column-nullable? column-default)

  ; ── Column record ─────────────────────────────────────────────────────────

  (define (make-column name index type nullable? default)
    (let ((h (make-hash-table)))
      (hash-set! h 'name      name)
      (hash-set! h 'index     index)
      (hash-set! h 'type      type)
      (hash-set! h 'nullable? nullable?)
      (hash-set! h 'default   default)
      h))

  (define (column-name    c) (hash-get c 'name     #f))
  (define (column-index   c) (hash-get c 'index    #f))
  (define (column-type    c) (hash-get c 'type     ':string))
  (define (column-nullable? c) (hash-get c 'nullable? #t))
  (define (column-default c) (hash-get c 'default  #f))

  ; ── Schema record ──────────────────────────────────────────────────────────

  (define (make-schema columns header? delimiter)
    (let ((h      (make-hash-table))
          (n->i   (make-hash-table)))
      (let mkschema-loop ((i 0))
        (when (< i (vector-length columns))
          (hash-set! n->i (column-name (vector-ref columns i)) i)
          (mkschema-loop (+ i 1))))
      (hash-set! h 'columns     columns)
      (hash-set! h 'name->index n->i)
      (hash-set! h 'header?     header?)
      (hash-set! h 'delimiter   delimiter)
      h))

  (define (schema-columns    s) (hash-get s 'columns     #f))
  (define (schema-name->index s) (hash-get s 'name->index #f))
  (define (schema-header?    s) (hash-get s 'header?     #t))
  (define (schema-delimiter  s) (hash-get s 'delimiter   (string-ref "," 0)))

  ; ── Schema inference ───────────────────────────────────────────────────────

  (define (infer-schema rows header? delimiter)
    (if (= (vector-length rows) 0)
        (make-schema (vector) header? delimiter)
        (let* ((first-row (vector-ref rows 0))
               (ncols     (vector-length first-row))
               (cols      (make-vector ncols #f)))
          (let infer-loop ((i 0))
            (when (< i ncols)
              (let ((name (if header?
                              (vector-ref first-row i)
                              (string-append "c" (number->string i)))))
                (vector-set! cols i (make-column name i ':string #t #f)))
              (infer-loop (+ i 1))))
          (make-schema cols header? delimiter))))

  ; ── Field coercion ─────────────────────────────────────────────────────────

  (define (coerce-field col raw)
    (let ((type (column-type col)))
      (cond
        ((equal? type ':string) raw)
        ((equal? type ':int)
         (let ((n (string->number raw)))
           (if n (inexact->exact (truncate n)) raw)))
        ((equal? type ':float)
         (let ((n (string->number raw)))
           (if n (exact->inexact n) raw)))
        ((equal? type ':bool)
         (cond
           ((or (equal? raw "true")  (equal? raw "1") (equal? raw "yes")) #t)
           ((or (equal? raw "false") (equal? raw "0") (equal? raw "no"))  #f)
           (else raw)))
        (else raw))))

  (define (coerce-row schema row)
    (let* ((cols (schema-columns schema))
           (out  (make-vector (vector-length row) "")))
      (let coerce-loop ((i 0))
        (when (< i (vector-length row))
          (let ((val (vector-ref row i)))
            (vector-set! out i
              (if (< i (vector-length cols))
                  (coerce-field (vector-ref cols i) val)
                  val)))
          (coerce-loop (+ i 1))))
      out)))
