(module csvdb/parser
  (export parse-csv emit-csv)

  ; RFC 4180 state-machine CSV parser.
  ; Returns vector<vector<string>>.
  ; Rows are vectors of string fields; no type coercion here.

  (define CH-QUOTE (string-ref "\"" 0))
  (define CH-CR    (string-ref "\r" 0))
  (define CH-LF    (string-ref "\n" 0))

  ; parse-csv : string char -> vector<vector<string>>
  ; delimiter is a single char (usually (string-ref "," 0))
  (define (parse-csv text delimiter)
    (let ((len    (string-length text))
          (rows   '())
          (fields '())
          (port   (open-output-string)))

      (define (emit-field!)
        (set! fields (cons (get-output-string port) fields))
        (set! port (open-output-string)))

      (define (emit-row!)
        (emit-field!)
        (set! rows (cons (list->vector (reverse fields)) rows))
        (set! fields '()))

      (define (field-char! c)
        (port-display port (char->string c)))

      (let parse-loop ((i 0) (state 'start))
        (if (= i len)
            ; end of input — flush pending row if any content exists
            (begin
              (when (or (> (string-length (get-output-string port)) 0)
                        (pair? fields))
                (emit-row!))
              (list->vector (reverse rows)))

            (let ((c (string-ref text i)))
              (cond
                ; ── state: start (beginning of a field) ─────────────────────
                ((eq? state 'start)
                 (cond
                   ((eq? c CH-QUOTE)
                    (parse-loop (+ i 1) 'quoted))
                   ((eq? c delimiter)
                    (emit-field!)
                    (parse-loop (+ i 1) 'start))
                   ((eq? c CH-LF)
                    (emit-row!)
                    (parse-loop (+ i 1) 'start))
                   ((eq? c CH-CR)
                    (parse-loop (+ i 1) 'start))  ; skip CR, LF will finish row
                   (else
                    (field-char! c)
                    (parse-loop (+ i 1) 'unquoted))))

                ; ── state: unquoted field ────────────────────────────────────
                ((eq? state 'unquoted)
                 (cond
                   ((eq? c delimiter)
                    (emit-field!)
                    (parse-loop (+ i 1) 'start))
                   ((eq? c CH-LF)
                    (emit-row!)
                    (parse-loop (+ i 1) 'start))
                   ((eq? c CH-CR)
                    (parse-loop (+ i 1) 'unquoted))  ; skip CR
                   (else
                    (field-char! c)
                    (parse-loop (+ i 1) 'unquoted))))

                ; ── state: inside quoted field ───────────────────────────────
                ((eq? state 'quoted)
                 (cond
                   ((eq? c CH-QUOTE)
                    (parse-loop (+ i 1) 'after-quote))
                   (else
                    (field-char! c)
                    (parse-loop (+ i 1) 'quoted))))

                ; ── state: saw " while quoted (escaped quote or end) ────────
                ((eq? state 'after-quote)
                 (cond
                   ((eq? c CH-QUOTE)
                    ; "" inside quotes → literal "
                    (field-char! CH-QUOTE)
                    (parse-loop (+ i 1) 'quoted))
                   ((eq? c delimiter)
                    (emit-field!)
                    (parse-loop (+ i 1) 'start))
                   ((eq? c CH-LF)
                    (emit-row!)
                    (parse-loop (+ i 1) 'start))
                   ((eq? c CH-CR)
                    (parse-loop (+ i 1) 'after-quote))
                   (else
                    ; malformed: closing quote not followed by delimiter/newline
                    ; treat as end of quoted field, continue as unquoted
                    (field-char! c)
                    (parse-loop (+ i 1) 'unquoted))))

                (else
                 (parse-loop (+ i 1) state))))))))

  ; emit-csv : vector<vector<string>> char -> string
  ; Produces RFC 4180 output. Quotes fields that contain delimiter, quote, or newline.
  (define (emit-csv rows delimiter)
    (let ((port      (open-output-string))
          (delim-str (char->string delimiter))
          (quote-str "\""))

      (define (needs-quoting? s)
        (let ((dch delimiter))
          (let scan ((i 0))
            (if (= i (string-length s))
                #f
                (let ((c (string-ref s i)))
                  (if (or (eq? c dch) (eq? c CH-QUOTE) (eq? c CH-LF) (eq? c CH-CR))
                      #t
                      (scan (+ i 1))))))))

      (define (write-field! s)
        (if (needs-quoting? s)
            (begin
              (port-display port quote-str)
              (let escape ((i 0))
                (when (< i (string-length s))
                  (let ((c (string-ref s i)))
                    (when (eq? c CH-QUOTE)
                      (port-display port quote-str))
                    (port-display port (char->string c))
                    (escape (+ i 1)))))
              (port-display port quote-str))
            (port-display port s)))

      (let row-loop ((ri 0))
        (when (< ri (vector-length rows))
          (let ((row (vector-ref rows ri)))
            (let col-loop ((ci 0))
              (when (< ci (vector-length row))
                (when (> ci 0) (port-display port delim-str))
                (write-field! (vector-ref row ci))
                (col-loop (+ ci 1)))))
          (port-display port "\n")
          (row-loop (+ ri 1))))

      (get-output-string port))))
