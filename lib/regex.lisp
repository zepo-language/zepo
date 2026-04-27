; lib/regex.lisp — regex helpers built on regex-compile / regex-exec.
(module regex
  (export
    regex-match? regex-find regex-find-all
    regex-replace regex-replace-all regex-split)

  (define (match-str m) (cdr (assoc 'match m)))
  (define (match-start m) (cdr (assoc 'start m)))
  (define (match-end m) (cdr (assoc 'end m)))

  ; Does pattern match anywhere in str?
  (define (regex-match? pattern str)
    (let ((m (regex-exec (regex-compile pattern) str)))
      (if m #t #f)))

  ; Return first match alist or #f.
  (define (regex-find pattern str)
    (regex-exec (regex-compile pattern) str))

  ; Return list of all non-overlapping match alists.
  (define (regex-find-all pattern str)
    (let ((rx (regex-compile pattern)))
      (let loop ((s str) (offset 0) (acc '()))
        (let ((m (regex-exec rx s)))
          (if (not m)
              (reverse acc)
              (let* ((ms (match-start m))
                     (me (match-end m))
                     (abs-start (+ offset ms))
                     (abs-end   (+ offset me))
                     (adjusted (list (cons 'match  (match-str m))
                                     (cons 'start  abs-start)
                                     (cons 'end    abs-end)
                                     (cons 'groups (cdr (assoc 'groups m))))))
                ; Advance past the match; skip one char if zero-length to avoid loop
                (let ((step (if (= ms me) 1 me)))
                  (loop (substring s step (string-length s))
                        (+ offset step)
                        (cons adjusted acc)))))))))

  ; Replace first match of pattern in str with replacement string.
  (define (regex-replace pattern str replacement)
    (let ((rx (regex-compile pattern)))
      (let ((m (regex-exec rx str)))
        (if (not m) str
            (string-append (substring str 0 (match-start m))
                           replacement
                           (substring str (match-end m) (string-length str)))))))

  ; Replace all non-overlapping matches.
  (define (regex-replace-all pattern str replacement)
    (let ((rx (regex-compile pattern)))
      (let loop ((s str) (acc ""))
        (let ((m (regex-exec rx s)))
          (if (not m)
              (string-append acc s)
              (let ((ms (match-start m))
                    (me (match-end m)))
                (let ((step (if (= ms me) 1 me)))
                  (loop (substring s step (string-length s))
                        (string-append acc
                                       (substring s 0 ms)
                                       replacement)))))))))

  ; Split str on pattern, returning list of substrings.
  (define (regex-split pattern str)
    (let ((rx (regex-compile pattern)))
      (let loop ((s str) (acc '()))
        (let ((m (regex-exec rx s)))
          (if (not m)
              (reverse (cons s acc))
              (let ((ms (match-start m))
                    (me (match-end m)))
                (let ((step (if (= ms me) 1 me)))
                  (loop (substring s step (string-length s))
                        (cons (substring s 0 ms) acc))))))))))
