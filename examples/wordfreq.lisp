(import clap)

(define (strip-char str ch)
  (list->string
    (filter (lambda (c) (not (= (char->integer c) (char->integer ch))))
            (string->list str))))

(define (normalize-word s)
  (let* ((s (string-downcase s))
         (s (strip-char s #\,))
         (s (strip-char s #\.))
         (s (strip-char s #\!))
         (s (strip-char s #\?))
         (s (strip-char s #\:))
         (s (strip-char s #\;))
         (s (strip-char s #\"))
         (s (string-trim s)))
    s))

(define (words-from-text text)
  (filter (lambda (w) (not (equal? w "")))
          (map normalize-word (string-split text " "))))

(define (count-words words)
  (define ht (make-hash-table))
  (for-each
    (lambda (w)
      (hash-set! ht w (+ 1 (hash-get ht w 0))))
    words)
  ht)

(define (pairify keys ht)
  (vector->list
    (vector-map (lambda (k) (cons k (hash-get ht k 0))) keys)))

(define (take lst n)
  (if (or (<= n 0) (null? lst))
      '()
      (cons (car lst) (take (cdr lst) (- n 1)))))

(define (print-results pairs)
  (for-each
    (lambda (p)
      (display (car p))
      (display ": ")
      (display (cdr p))
      (newline))
    pairs))

(define root
  (cmd-add-option
    (cmd-add-option
      (make-command "wordfreq" "Count word frequency in a string")
      (opt-set
        (opt-set
          (opt-set
            (make-option 'text "Text to analyze")
            :long "text")
          :kind 'value)
        :required #t))
    (opt-set
      (opt-set
        (opt-set
          (make-option 'top "How many results to print")
          :long "top")
        :kind 'value)
      :type 'integer)))

(define prog
  (make-program "wordfreq" "Word frequency demo" "" "0.1.0" root))

(define (main)
  ; cddr skips both the binary and the script path in interpreter mode.
  (define result (parse prog (cddr (argv))))
  (if (parse-error? result)
      (begin
        (display (render-error result))
        (newline))
      (let* ((text (result-option result 'text))
             (top  (or (result-option result 'top) 10))
             (words (words-from-text text))
             (ht (count-words words))
             (pairs (pairify (hash-keys ht) ht))
             (sorted (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
             (best (take sorted top)))
        (print-results best))))

(main)
