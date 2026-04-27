; lib/net.lisp — high-level TCP helpers built on tcp-* primitives.
(module net
  (export tcp-recv-all tcp-recv-line with-tcp-connection tcp-serve)

  ; Read from socket until EOF, return accumulated string.
  (define (tcp-recv-all sock)
    (let loop ((acc ""))
      (let ((chunk (tcp-recv sock 4096)))
        (if (= (string-length chunk) 0)
            acc
            (loop (string-append acc chunk))))))

  ; Read one line from socket (up to and including \n). Returns "" on EOF.
  (define (tcp-recv-line sock)
    (let loop ((acc ""))
      (let ((b (tcp-recv sock 1)))
        (cond ((= (string-length b) 0) acc)
              ((equal? b "\n") (string-append acc "\n"))
              (#t (loop (string-append acc b)))))))

  ; Connect, call (thunk socket), then close — even if thunk raises.
  (define (with-tcp-connection host port thunk)
    (let ((sock (tcp-connect host port)))
      (with-exception-handler
        (lambda (e)
          (tcp-close sock)
          (error e))
        (lambda ()
          (let ((result (thunk sock)))
            (tcp-close sock)
            result)))))

  ; Accept-loop: listen on port, call (handler conn) for each connection.
  ; handler is responsible for using the conn; tcp-serve closes it after.
  ; Runs forever — wrap in with-exception-handler to stop.
  (define (tcp-serve port handler)
    (let ((server (tcp-listen port)))
      (let loop ()
        (let ((conn (tcp-accept server)))
          (with-exception-handler
            (lambda (e) (tcp-close conn))
            (lambda ()
              (handler conn)
              (tcp-close conn))))
        (loop)))))
