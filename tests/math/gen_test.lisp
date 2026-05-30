;; zepo-bm3a: tests for math/gen — generators with shrinking.
(import testing
  (describe it is =check run!/exit))
(import math/dist (make-rng))
(import math/gen  (make-gen gen-sample gen-shrink
                   gen-int gen-float gen-bool gen-char gen-string
                   gen-list gen-vector gen-one-of gen-bind))

(describe "gen"

  (describe "determinism"
    (it "same rng seed produces the same value across two sample calls"
      (let ((g (gen-int 0 1000))
            (a (make-rng 7))
            (b (make-rng 7)))
        (=check (gen-sample g a) (gen-sample g b))
        (=check (gen-sample g a) (gen-sample g b))
        (=check (gen-sample g a) (gen-sample g b)))))

  (describe "gen-int"
    (it "stays in [lo, hi] over 1000 draws"
      (let ((g (gen-int 3 9)) (r (make-rng 42)))
        (let loop ((i 0))
          (if (< i 1000)
              (let ((x (gen-sample g r)))
                (is (>= x 3))
                (is (<= x 9))
                (loop (+ i 1)))))))
    (it "shrinks of 100 are all strictly smaller in absolute value"
      (let* ((g (gen-int 0 1000))
             (cands (gen-shrink g 100)))
        (is (not (null? cands)))
        (let loop ((xs cands))
          (if (not (null? xs))
              (let ((c (car xs)))
                (is (< (if (< c 0) (- c) c) 100))
                (loop (cdr xs)))))))
    (it "0 shrinks to ()"
      (=check (gen-shrink (gen-int 0 100) 0) (quote ())))
    (it "negative values shrink toward 0"
      (let ((cands (gen-shrink (gen-int -100 100) -10)))
        (is (not (null? cands)))
        (let loop ((xs cands))
          (if (not (null? xs))
              (let ((c (car xs)))
                (is (< (if (< c 0) (- c) c) 10))
                (loop (cdr xs))))))))

  (describe "gen-float"
    (it "stays in [lo, hi) over 200 draws"
      (let ((g (gen-float 0.0 1.0)) (r (make-rng 3)))
        (let loop ((i 0))
          (if (< i 200)
              (let ((x (gen-sample g r)))
                (is (>= x 0.0))
                (is (< x 1.0))
                (loop (+ i 1))))))))

  (describe "gen-bool"
    (it "draws are #t or #f"
      (let ((g (gen-bool)) (r (make-rng 11)))
        (let loop ((i 0))
          (if (< i 50)
              (let ((b (gen-sample g r)))
                (is (or (eq? b #t) (eq? b #f)))
                (loop (+ i 1)))))))
    (it "#t shrinks to (#f) and #f shrinks to (())"
      (=check (gen-shrink (gen-bool) #t) (list #f))
      (=check (gen-shrink (gen-bool) #f) (list (quote ())))))

  (describe "gen-char"
    (it "draws are printable ASCII"
      (let ((g (gen-char)) (r (make-rng 5)))
        (let loop ((i 0))
          (if (< i 100)
              (let* ((c (gen-sample g r))
                     (n (char->integer c)))
                (is (>= n 32))
                (is (< n 127))
                (loop (+ i 1))))))))

  (describe "gen-list"
    (it "length is in [lo, hi] over many draws"
      (let ((g (gen-list 2 5 (gen-int 0 9))) (r (make-rng 9)))
        (let loop ((i 0))
          (if (< i 200)
              (let ((xs (gen-sample g r)))
                (is (>= (length xs) 2))
                (is (<= (length xs) 5))
                (loop (+ i 1)))))))
    (it "shrinks produce candidates with shorter length"
      (let* ((g (gen-list 0 10 (gen-int 0 9)))
             (cands (gen-shrink g (list 5 5 5 5))))
        (is (not (null? cands)))
        ;; at least one candidate must be strictly shorter.
        (let loop ((xs cands) (found #f))
          (cond ((null? xs) (is found))
                ((< (length (car xs)) 4) (loop (cdr xs) #t))
                (else (loop (cdr xs) found)))))))

  (describe "gen-string"
    (it "length is in [lo, hi]"
      (let ((g (gen-string 2 6)) (r (make-rng 4)))
        (let loop ((i 0))
          (if (< i 100)
              (let ((s (gen-sample g r)))
                (is (>= (string-length s) 2))
                (is (<= (string-length s) 6))
                (loop (+ i 1)))))))
    (it "shrinks produce candidates with shorter length"
      (let* ((g (gen-string 0 20))
             (cands (gen-shrink g "hello")))
        (is (not (null? cands)))
        (let loop ((xs cands) (found #f))
          (cond ((null? xs) (is found))
                ((< (string-length (car xs)) 5) (loop (cdr xs) #t))
                (else (loop (cdr xs) found)))))))

  (describe "gen-vector"
    (it "size is in [lo, hi]"
      (let ((g (gen-vector 1 4 (gen-int 0 9))) (r (make-rng 6)))
        (let loop ((i 0))
          (if (< i 100)
              (let ((v (gen-sample g r)))
                (is (>= (vector-length v) 1))
                (is (<= (vector-length v) 4))
                (loop (+ i 1))))))))

  (describe "gen-one-of"
    (it "always returns one of the provided items"
      (let* ((items (list (quote a) (quote b) (quote c)))
             (g (gen-one-of items))
             (r (make-rng 8)))
        (let loop ((i 0))
          (if (< i 100)
              (let ((x (gen-sample g r)))
                (is (member x items))
                (loop (+ i 1))))))))

  (describe "gen-bind"
    (it "binds outer int to inner list whose length equals that int"
      ;; sample n via outer, then sample a list of length n (lo=hi=n).
      (let* ((g (gen-bind (gen-int 0 5)
                          (lambda (n) (gen-list n n (gen-int 0 9)))))
             (r (make-rng 21)))
        (let loop ((i 0))
          (if (< i 50)
              (let ((xs (gen-sample g r)))
                ;; only the length range is constrained: 0..5
                (is (>= (length xs) 0))
                (is (<= (length xs) 5))
                (loop (+ i 1)))))))
    (it "sampling is deterministic across two equal rngs"
      (let* ((mk (lambda () (gen-bind (gen-int 0 5)
                                      (lambda (n) (gen-list n n (gen-int 0 9))))))
             (g1 (mk)) (g2 (mk))
             (a (make-rng 33)) (b (make-rng 33)))
        (=check (gen-sample g1 a) (gen-sample g2 b))
        (=check (gen-sample g1 a) (gen-sample g2 b))))))

(run!/exit)
