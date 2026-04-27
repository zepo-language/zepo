(module csvdb/query
  (export eval-pred select-rows)

  (import csvdb/schema)
  (import csvdb/store)

  ; ── Predicate evaluator ───────────────────────────────────────────────────
  ;
  ; Predicates are plain Lisp data. Bare symbols resolve to column values.
  ; Literals self-evaluate.
  ;
  ; Ops: = != < <= > >=  and or not
  ;      starts-with  ends-with  contains  in  nil?  empty?

  (define (eval-atom expr table row)
    (cond
      ((symbol? expr)
       (let ((idx (hash-get (schema-name->index (table-schema table))
                            (symbol->string expr) #f)))
         (if idx (vector-ref row idx) expr)))
      ((or (string? expr) (number? expr) (boolean? expr)) expr)
      (else #f)))

  (define (eval-compare op a b table row)
    (let ((va (eval-pred a table row))
          (vb (eval-pred b table row)))
      (cond
        ((equal? op '=)  (equal? va vb))
        ((equal? op '!=) (not (equal? va vb)))
        ((equal? op '<)  (< va vb))
        ((equal? op '<=) (<= va vb))
        ((equal? op '>)  (> va vb))
        ((equal? op '>=) (>= va vb))
        (else #f))))

  (define (eval-string-op op args table row)
    (let ((s (eval-pred (car args) table row))
          (p (eval-pred (cadr args) table row)))
      (cond
        ((equal? op 'starts-with)
         (let ((sl (string-length s)) (pl (string-length p)))
           (and (>= sl pl) (equal? (substring s 0 pl) p))))
        ((equal? op 'ends-with)
         (let ((sl (string-length s)) (ul (string-length p)))
           (and (>= sl ul) (equal? (substring s (- sl ul) sl) p))))
        ((equal? op 'contains)
         (let ((sl (string-length s)) (ul (string-length p)))
           (let scan ((si 0))
             (cond ((> (+ si ul) sl) #f)
                   ((equal? (substring s si (+ si ul)) p) #t)
                   (else (scan (+ si 1)))))))
        (else #f))))

  (define (eval-in col-expr rest table row)
    (let ((val (eval-pred col-expr table row)))
      (let in-loop ((xs rest))
        (cond
          ((null? xs) #f)
          ((equal? val (eval-pred (car xs) table row)) #t)
          (else (in-loop (cdr xs)))))))

  (define (eval-and args table row)
    (let and-loop ((rest args))
      (if (null? rest) #t
          (if (eval-pred (car rest) table row) (and-loop (cdr rest)) #f))))

  (define (eval-or args table row)
    (let or-loop ((rest args))
      (if (null? rest) #f
          (if (eval-pred (car rest) table row) #t (or-loop (cdr rest))))))

  (define (eval-pred expr table row)
    (cond
      ((pair? expr)
       (let ((op   (car expr))
             (args (cdr expr)))
         (cond
           ((equal? op 'and)  (eval-and args table row))
           ((equal? op 'or)   (eval-or  args table row))
           ((equal? op 'not)  (not (eval-pred (car args) table row)))
           ((or (equal? op '=) (equal? op '!=)
                (equal? op '<) (equal? op '<=)
                (equal? op '>) (equal? op '>=))
            (eval-compare op (car args) (cadr args) table row))
           ((or (equal? op 'starts-with) (equal? op 'ends-with)
                (equal? op 'contains))
            (eval-string-op op args table row))
           ((equal? op 'in)
            (eval-in (car args) (cdr args) table row))
           ((equal? op 'nil?)
            (let ((v (eval-pred (car args) table row)))
              (or (equal? v "") (equal? v #f))))
           ((equal? op 'empty?)
            (let ((v (eval-pred (car args) table row)))
              (or (equal? v "") (null? v))))
           (else (error "unknown predicate op" op)))))
      (else
       (eval-atom expr table row))))

  ; ── Row selection ─────────────────────────────────────────────────────────
  ;
  ; opts keys: 'where 'limit 'offset 'as (':rows or ':maps)

  (define (select-rows table opts)
    (let* ((where  (hash-get opts 'where  #f))
           (limit  (hash-get opts 'limit  #f))
           (offset (hash-get opts 'offset 0))
           (as     (hash-get opts 'as     ':rows))
           (rows   (table-rows table))
           (n      (vector-length rows))
           (result '())
           (count  0)
           (skipped 0))

      (let select-loop ((i 0))
        (when (and (< i n) (or (not limit) (< count limit)))
          (let ((row (vector-ref rows i)))
            (when (or (not where) (eval-pred where table row))
              (if (< skipped offset)
                  (set! skipped (+ skipped 1))
                  (begin
                    (set! result
                          (cons (if (equal? as ':maps)
                                    (row->map table row)
                                    row)
                                result))
                    (set! count (+ count 1))))))
          (select-loop (+ i 1))))

      (list->vector (reverse result)))))
