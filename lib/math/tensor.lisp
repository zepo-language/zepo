(module math/tensor
  (export tensor tensor? shape rank size zeros ones full arange from-nested tensor->nested tref tset! reshape transpose slice)

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

  ;; zepo-py2: copy the sub-tensor along one axis over [start,end).
  (define (bump-axis idx axis start)
    (let loop ((i 0) (rest idx) (acc (quote ())))
      (if (null? rest) (reverse acc)
          (loop (+ i 1) (cdr rest)
                (cons (if (= i axis) (+ (car rest) start) (car rest)) acc)))))

  (define (slice t axis start end)
    (let* ((sv (tensor-shape-vec t)) (r (vector-length sv)))
      (if (or (not (integer? axis)) (< axis 0) (>= axis r))
          (error "slice: axis out of range"))
      (let ((dim (vector-ref sv axis)))
        (if (not (and (integer? start) (integer? end)
                      (<= 0 start) (< start end) (<= end dim)))
            (error "slice: bad range (need 0 <= start < end <= dim)"))
        (let ((out-sv (vector-copy sv)))
          (vector-set! out-sv axis (- end start))
          (let* ((n (prod-vec out-sv)) (dv (tensor-data t)) (out (make-vector n 0)))
            (let loop ((flat 0))
              (if (= flat n) (make-tensor out-sv out)
                  (let* ((oidx (unflatten out-sv flat))
                         (iidx (bump-axis oidx axis start))
                         (ioff (flat-offset sv iidx)))
                    (vector-set! out flat (vector-ref dv ioff))
                    (loop (+ flat 1))))))))))

  ;; zepo-py2: reverse all axes; copy with remapped indices.
  (define (reverse-vec v) (list->vector (reverse (vector->list v))))

  (define (transpose t)
    (let* ((sv (tensor-shape-vec t))
           (out-sv (reverse-vec sv))
           (dv (tensor-data t))
           (n (vector-length dv))
           (out (make-vector n 0)))
      (let loop ((flat 0))
        (if (= flat n) (make-tensor out-sv out)
            (let* ((idx (unflatten sv flat))
                   (oidx (reverse idx))
                   (ooff (flat-offset out-sv oidx)))
              (vector-set! out ooff (vector-ref dv flat))
              (loop (+ flat 1)))))))

  ;; zepo-py2: same total size; SHARES the data buffer (row-major unchanged).
  (define (reshape t shape)
    (let ((sv (->vec shape)))
      (let dloop ((i 0))
        (if (< i (vector-length sv))
            (let ((d (vector-ref sv i)))
              (if (or (not (integer? d)) (< d 1))
                  (error "reshape: every dimension must be an integer >= 1"))
              (dloop (+ i 1)))))
      (if (not (= (prod-vec sv) (size t)))
          (error "reshape: new shape size does not match element count"))
      (make-tensor sv (tensor-data t))))

  ;; zepo-py2: validate index list against the shape, return the flat offset.
  (define (check-index shape-vec idxs)
    (let ((r (vector-length shape-vec)))
      (if (not (= (length idxs) r))
          (error "tensor index: wrong number of indices for rank"))
      (let loop ((i 0) (rest idxs))
        (if (< i r)
            (let ((k (car rest)) (d (vector-ref shape-vec i)))
              (if (or (not (integer? k)) (< k 0) (>= k d))
                  (error "tensor index: out of bounds"))
              (loop (+ i 1) (cdr rest)))))
      (flat-offset shape-vec idxs)))

  (define (tref t . idxs)
    (vector-ref (tensor-data t) (check-index (tensor-shape-vec t) idxs)))

  (define (tset! t val . idxs)
    (vector-set! (tensor-data t) (check-index (tensor-shape-vec t) idxs) val))

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

