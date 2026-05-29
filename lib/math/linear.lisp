(module math/linear
  (export vec mat mat-rows mat-cols mat-ref mat-shape
          vec-add dot norm rows->mat transpose matvec solve det)

  (import math/core (almost-eq?))   ; zepo-y1a4: selective

  (define (vec . xs) (apply vector xs))

  (define (vadd-loop r u v i n)
    (if (< i n)
        (begin (vector-set! r i (+ (vector-ref u i) (vector-ref v i)))
               (vadd-loop r u v (+ i 1) n))))

  (define (vec-add u v)
    (let* ((n (vector-length u)) (r (make-vector n 0)))
      (vadd-loop r u v 0 n)
      r))

  (define (dot-loop u v i n acc)
    (if (= i n) acc
        (dot-loop u v (+ i 1) n (+ acc (* (vector-ref u i) (vector-ref v i))))))

  (define (dot u v) (dot-loop u v 0 (vector-length u) 0))

  (define (norm v) (sqrt (dot v v)))


  (define (mat rows cols . values)
    (let ((m (make-hash-table)))
      (hash-set! m 'rows rows)
      (hash-set! m 'cols cols)
      (hash-set! m 'data (apply vector values))
      m))

  (define (mat-rows m) (hash-get m 'rows 0))
  (define (mat-cols m) (hash-get m 'cols 0))
  (define (mat-shape m) (list (mat-rows m) (mat-cols m)))

  (define (mat-ref m i j)
    (vector-ref (hash-get m 'data #f) (+ (* i (hash-get m 'cols 0)) j)))

  (define (mat-copy m)
    (let ((c (make-hash-table)))
      (hash-set! c 'rows (mat-rows m))
      (hash-set! c 'cols (mat-cols m))
      (hash-set! c 'data (vector-copy (hash-get m 'data #f)))
      c))

  (define (zeros rows cols)
    (let ((m (make-hash-table)))
      (hash-set! m 'rows rows)
      (hash-set! m 'cols cols)
      (hash-set! m 'data (make-vector (* rows cols) 0))
      m))

  (define (r2m-row data cols i j cs)
    (if (not (null? cs))
        (begin (vector-set! data (+ (* i cols) j) (car cs))
               (r2m-row data cols i (+ j 1) (cdr cs)))))

  (define (r2m-rows data cols i rls)
    (if (not (null? rls))
        (begin (r2m-row data cols i 0 (car rls))
               (r2m-rows data cols (+ i 1) (cdr rls)))))

  (define (rows->mat list-of-rows)
    (let* ((rows (length list-of-rows))
           (cols (if (= rows 0) 0 (length (car list-of-rows))))
           (m (zeros rows cols)))
      (r2m-rows (hash-get m 'data #f) cols 0 list-of-rows)
      m))

  (define (tr-jl md rd rows cols i j)
    (if (< j cols)
        (begin (vector-set! rd (+ (* j rows) i) (vector-ref md (+ (* i cols) j)))
               (tr-jl md rd rows cols i (+ j 1)))))

  (define (tr-il md rd rows cols i)
    (if (< i rows)
        (begin (tr-jl md rd rows cols i 0)
               (tr-il md rd rows cols (+ i 1)))))

  (define (transpose m)
    (let* ((rows (mat-rows m)) (cols (mat-cols m)) (r (zeros cols rows)))
      (tr-il (hash-get m 'data #f) (hash-get r 'data #f) rows cols 0)
      r))

  (define (mv-jl md v cols i j acc)
    (if (= j cols) acc
        (mv-jl md v cols i (+ j 1)
               (+ acc (* (vector-ref md (+ (* i cols) j)) (vector-ref v j))))))

  (define (mv-il md v r rows cols i)
    (if (< i rows)
        (begin (vector-set! r i (mv-jl md v cols i 0 0))
               (mv-il md v r rows cols (+ i 1)))))

  (define (matvec m v)
    (let* ((rows (mat-rows m)) (cols (mat-cols m)) (r (make-vector rows 0)))
      (mv-il (hash-get m 'data #f) v r rows cols 0)
      r))

  ;; Gaussian elimination

  (define (sg-pivot d cols n c i mv mr)
    (if (= i n) mr
        (let ((v (abs (vector-ref d (+ (* i cols) c)))))
          (if (> v mv)
              (sg-pivot d cols n c (+ i 1) v i)
              (sg-pivot d cols n c (+ i 1) mv mr)))))

  (define (sg-swap d cols n c mr j)
    (if (<= j n)
        (let ((tmp (vector-ref d (+ (* c cols) j))))
          (vector-set! d (+ (* c cols) j) (vector-ref d (+ (* mr cols) j)))
          (vector-set! d (+ (* mr cols) j) tmp)
          (sg-swap d cols n c mr (+ j 1)))))

  (define (sg-elim-row d cols n c i factor j)
    (if (<= j n)
        (let ((ii (+ (* i cols) j))
              (cc (+ (* c cols) j)))
          (vector-set! d ii (- (vector-ref d ii) (* factor (vector-ref d cc))))
          (sg-elim-row d cols n c i factor (+ j 1)))))

  (define (sg-elim d cols n c i)
    (if (< i n)
        (let ((factor (/ (vector-ref d (+ (* i cols) c))
                         (vector-ref d (+ (* c cols) c)))))
          (sg-elim-row d cols n c i factor c)
          (sg-elim d cols n c (+ i 1)))))

  (define (sg-cols d cols n c)
    (if (< c n)
        (let* ((mv (abs (vector-ref d (+ (* c cols) c))))
               (mr (sg-pivot d cols n c (+ c 1) mv c)))
          (if (not (= mr c)) (sg-swap d cols n c mr 0))
          (if (almost-eq? (vector-ref d (+ (* c cols) c)) 0)
              (error "solve: singular matrix"))
          (sg-elim d cols n c (+ c 1))
          (sg-cols d cols n (+ c 1)))))

  (define (sg-back-sum d cols n x i j s)
    (if (= j n) s
        (sg-back-sum d cols n x i (+ j 1)
                     (+ s (* (vector-ref d (+ (* i cols) j)) (vector-ref x j))))))

  (define (sg-back d cols n x i)
    (if (>= i 0)
        (let ((s (sg-back-sum d cols n x i (+ i 1) 0)))
          (vector-set! x i (/ (- (vector-ref d (+ (* i cols) n)) s)
                              (vector-ref d (+ (* i cols) i))))
          (sg-back d cols n x (- i 1)))))

  (define (sg-fill-row ad ac agd ag-cols b i n j)
    (if (< j n)
        (begin (vector-set! agd (+ (* i ag-cols) j) (vector-ref ad (+ (* i ac) j)))
               (sg-fill-row ad ac agd ag-cols b i n (+ j 1)))
        (vector-set! agd (+ (* i ag-cols) n) (vector-ref b i))))

  (define (sg-fill ad ac agd ag-cols b n i)
    (if (< i n)
        (begin (sg-fill-row ad ac agd ag-cols b i n 0)
               (sg-fill ad ac agd ag-cols b n (+ i 1)))))

  (define (solve a b)
    (let* ((n (mat-rows a))
           (ag-cols (+ n 1))
           (aug (zeros n ag-cols))
           (ag-data (hash-get aug 'data #f))
           (a-data (hash-get a 'data #f))
           (a-cols (mat-cols a))
           (x (make-vector n 0)))
      (sg-fill a-data a-cols ag-data ag-cols b n 0)
      (sg-cols ag-data ag-cols n 0)
      (sg-back ag-data ag-cols n x (- n 1))
      x))

  (define (det-prod d n i p)
    (if (= i n) p
        (det-prod d n (+ i 1) (* p (vector-ref d (+ (* i n) i))))))

  ;; det's elim-row: iterates j < n (no aug column)
  (define (det-elim-row d n c i factor j)
    (if (< j n)
        (let ((ii (+ (* i n) j))
              (cc (+ (* c n) j)))
          (vector-set! d ii (- (vector-ref d ii) (* factor (vector-ref d cc))))
          (det-elim-row d n c i factor (+ j 1)))))

  (define (det-elim d n c i)
    (if (< i n)
        (let ((factor (/ (vector-ref d (+ (* i n) c))
                         (vector-ref d (+ (* c n) c)))))
          (det-elim-row d n c i factor c)
          (det-elim d n c (+ i 1)))))

  (define (det-swap d n c mr j)
    (if (< j n)
        (let ((tmp (vector-ref d (+ (* c n) j))))
          (vector-set! d (+ (* c n) j) (vector-ref d (+ (* mr n) j)))
          (vector-set! d (+ (* mr n) j) tmp)
          (det-swap d n c mr (+ j 1)))))

  (define (det-loop d n c sign)
    (if (= c n) sign
        (let* ((mv (abs (vector-ref d (+ (* c n) c))))
               (mr (sg-pivot d n n c (+ c 1) mv c))
               (ns (if (= mr c) sign (- sign))))
          (if (not (= mr c)) (det-swap d n c mr 0))
          (if (almost-eq? (vector-ref d (+ (* c n) c)) 0)
              0
              (begin (det-elim d n c (+ c 1))
                     (det-loop d n (+ c 1) ns))))))

  (define (det a)
    (let* ((n (mat-rows a))
           (m (mat-copy a))
           (d (hash-get m 'data #f))
           (sign (det-loop d n 0 1)))
      (if (= sign 0) 0 (* sign (det-prod d n 0 1))))))
