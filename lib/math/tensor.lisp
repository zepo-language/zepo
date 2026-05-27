(module math/tensor
  (export tensor tensor? shape rank size zeros ones full arange from-nested tensor->nested)

  ;; ── internal helpers (zepo-py2) ──────────────────────────────────────────
  (define (->vec xs) (if (vector? xs) xs (list->vector xs)))

  (define (prod-vec v)
    (let ((n (vector-length v)))
      (let loop ((i 0) (acc 1))
        (if (= i n) acc (loop (+ i 1) (* acc (vector-ref v i)))))))

  ;; build a tensor hashtable from a shape vector + data vector (no validation)
  (define (make-tensor shape-vec data-vec)
    (let ((t (make-hash-table)))
      (hash-set! t 'shape shape-vec)
      (hash-set! t 'data data-vec)
      t))

  (define (tensor-shape-vec t) (hash-get t 'shape #f))
  (define (tensor-data t)      (hash-get t 'data #f))

  ;; row-major flat offset from a list of indices and a shape vector (Horner).
  (define (flat-offset shape-vec idxs)
    (let ((n (vector-length shape-vec)))
      (let loop ((i 0) (rest idxs) (off 0))
        (if (= i n) off
            (loop (+ i 1) (cdr rest)
                  (+ (* off (vector-ref shape-vec i)) (car rest)))))))

  ;; inverse of flat-offset: flat index -> list of per-axis indices.
  (define (unflatten shape-vec flat)
    (let loop ((i (- (vector-length shape-vec) 1)) (rem flat) (acc (quote ())))
      (if (< i 0) acc
          (let ((d (vector-ref shape-vec i)))
            (loop (- i 1) (quotient rem d) (cons (modulo rem d) acc))))))

  ;; ── construction + introspection (zepo-py2) ──────────────────────────────
  (define (tensor shape data)
    (let ((sv (->vec shape)) (dv (->vec data)))
      (let ((r (vector-length sv)))
        (if (= r 0) (error "tensor: shape must have at least one dimension"))
        (let dloop ((i 0))
          (if (< i r)
              (let ((d (vector-ref sv i)))
                (if (or (not (integer? d)) (< d 1))
                    (error "tensor: every dimension must be an integer >= 1"))
                (dloop (+ i 1)))))
        (if (not (= (vector-length dv) (prod-vec sv)))
            (error "tensor: data length does not match product of shape"))
        (let nloop ((i 0))
          (if (< i (vector-length dv))
              (begin
                (if (not (number? (vector-ref dv i)))
                    (error "tensor: data must be numeric"))
                (nloop (+ i 1)))))
        (make-tensor sv dv))))

  (define (tensor? x)
    (and (hash-table? x)
         (vector? (hash-get x 'shape #f))
         (vector? (hash-get x 'data #f))))

  (define (shape t) (vector->list (tensor-shape-vec t)))
  (define (rank t)  (vector-length (tensor-shape-vec t)))
  (define (size t)  (vector-length (tensor-data t)))

  ;; zepo-py2: factory constructors.
  (define (full shape v)
    (let ((sv (->vec shape)))
      (let dloop ((i 0))
        (if (< i (vector-length sv))
            (let ((d (vector-ref sv i)))
              (if (or (not (integer? d)) (< d 1))
                  (error "full: every dimension must be an integer >= 1"))
              (dloop (+ i 1)))))
      (make-tensor sv (make-vector (prod-vec sv) v))))

  (define (zeros shape) (full shape 0))
  (define (ones  shape) (full shape 1))

  (define (arange n)
    (if (or (not (integer? n)) (< n 1)) (error "arange: n must be an integer >= 1"))
    (let ((dv (make-vector n 0)))
      (let loop ((i 0))
        (if (= i n) (make-tensor (vector n) dv)
            (begin (vector-set! dv i i) (loop (+ i 1)))))))

  ;; zepo-py2: infer shape from the first element down; flatten row-major.
  (define (nested-shape n)
    (if (pair? n) (cons (length n) (nested-shape (car n))) (quote ())))

  (define (flatten-nested n)
    (if (pair? n)
        (apply append (map flatten-nested n))
        (list n)))

  (define (from-nested nested)
    (if (not (pair? nested)) (error "from-nested: need a non-empty nested list"))
    (let* ((shape-list (nested-shape nested))
           (sv (list->vector shape-list))
           (flat (flatten-nested nested)))
      ;; rectangularity: flattened length must equal product of inferred shape
      (if (not (= (length flat) (prod-vec sv)))
          (error "from-nested: ragged or inconsistent nested list"))
      (tensor sv flat)))

  ;; rebuild nested lists from shape + flat data using offset arithmetic.
  (define (tensor->nested t)
    (let ((sv (tensor-shape-vec t)) (dv (tensor-data t)))
      (let build ((axis 0) (off 0) (block (vector-length dv)))
        (if (= axis (vector-length sv))
            (vector-ref dv off)
            (let* ((dim (vector-ref sv axis)) (sub (quotient block dim)))
              (let loop ((k 0) (acc (quote ())))
                (if (= k dim) (reverse acc)
                    (loop (+ k 1)
                          (cons (build (+ axis 1) (+ off (* k sub)) sub) acc)))))))))
)

