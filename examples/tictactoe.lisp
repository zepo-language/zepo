; Perfect Tic-Tac-Toe — minimax AI, never loses.
; Usage: zepo examples/tictactoe.lisp

; Board: vector of 9 cells, each 'E (empty), 'X, or 'O.
(define (make-board) (make-vector 9 'E))

(define (board-ref b i) (vector-ref b i))
(define (board-set! b i v) (vector-set! b i v))

(define (board-copy b)
  (let ((c (make-vector 9 'E)))
    (let loop ((i 0))
      (if (= i 9) c
          (begin
            (vector-set! c i (vector-ref b i))
            (loop (+ i 1)))))))

(define wins '((0 1 2)(3 4 5)(6 7 8)
               (0 3 6)(1 4 7)(2 5 8)
               (0 4 8)(2 4 6)))

(define (winner? b p)
  (let loop ((ws wins))
    (if (null? ws) #f
        (let ((w (car ws)))
          (if (and (eq? (board-ref b (car w)) p)
                   (eq? (board-ref b (cadr w)) p)
                   (eq? (board-ref b (caddr w)) p))
              #t
              (loop (cdr ws)))))))

(define (board-full? b)
  (let loop ((i 0))
    (if (= i 9) #t
        (if (eq? (board-ref b i) 'E) #f
            (loop (+ i 1))))))

(define (empty-cells b)
  (let loop ((i 0) (acc '()))
    (if (= i 9) (reverse acc)
        (loop (+ i 1)
              (if (eq? (board-ref b i) 'E)
                  (cons i acc)
                  acc)))))

; Minimax: returns (score . best-move)
(define (minimax b is-max? depth)
  (cond
    ((winner? b 'X) (cons (- 10 depth) -1))
    ((winner? b 'O) (cons (- depth 10) -1))
    ((board-full? b) (cons 0 -1))
    (else
     (let* ((cells (empty-cells b))
            (player (if is-max? 'X 'O))
            (best-score (if is-max? -100 100))
            (best-move -1))
       (let loop ((cs cells) (bs best-score) (bm best-move))
         (if (null? cs)
             (cons bs bm)
             (let* ((i (car cs))
                    (nb (board-copy b))
                    (_ (board-set! nb i player))
                    (result (minimax nb (not is-max?) (+ depth 1)))
                    (score (car result)))
               (if (if is-max? (> score bs) (< score bs))
                   (loop (cdr cs) score i)
                   (loop (cdr cs) bs bm)))))))))

(define (best-move b)
  (cdr (minimax b #t 0)))

; Display
(define (cell-str v)
  (cond ((eq? v 'X) "X")
        ((eq? v 'O) "O")
        (else ".")))

(define (print-board b)
  (println "")
  (let loop ((row 0))
    (if (= row 3) #f
        (begin
          (let ((i (* row 3)))
            (println (string-append " "
                                    (cell-str (board-ref b i)) " | "
                                    (cell-str (board-ref b (+ i 1))) " | "
                                    (cell-str (board-ref b (+ i 2))))))
          (if (< row 2) (println " ---------") #f)
          (loop (+ row 1))))))

(define (parse-move s)
  (let ((n (string->number s)))
    (if (and n (>= n 1) (<= n 9))
        (- n 1)
        -1)))

(define (human-turn b)
  (println "Your move (1-9, left-to-right, top-to-bottom):")
  (let loop ()
    (let* ((line (read-line))
           (idx  (if line (parse-move line) -1)))
      (cond
        ((= idx -1)
         (println "Invalid — enter 1 to 9.")
         (loop))
        ((not (eq? (board-ref b idx) 'E))
         (println "That cell is taken.")
         (loop))
        (else idx)))))

(define (play)
  (let ((b (make-board)))
    (println "Tic-Tac-Toe — you are O, computer is X.")
    (println "Computer goes first.")
    (let loop ()
      ; Computer move (X)
      (let ((mv (best-move b)))
        (board-set! b mv 'X)
        (print-board b)
        (cond
          ((winner? b 'X)
           (println "Computer wins!"))
          ((board-full? b)
           (println "Draw!"))
          (else
           ; Human move (O)
           (let ((hm (human-turn b)))
             (board-set! b hm 'O)
             (print-board b)
             (cond
               ((winner? b 'O)
                (println "You win!"))
               ((board-full? b)
                (println "Draw!"))
               (else
                (loop))))))))))

(play)
