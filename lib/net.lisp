; lib/net.lisp — high-level TCP helpers built on tcp-* primitives.
; zepo-nj6: tcp-recv returns eof-object on close; tcp-recv-line is a built-in.
(module net
  (export tcp-recv-all with-tcp-connection tcp-serve)

  ; Read from socket until EOF, return accumulated string.
  (define (tcp-recv-all sock)
    (let loop ((acc ""))
      (let ((chunk (tcp-recv sock 4096)))
        (if (eof-object? chunk)
            acc
            (loop (string-append acc chunk))))))

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

  ; Accept-loop: listen on port, spawn a fiber per connection.
  ; handler is called in a new fiber with the accepted conn.
  ; tcp-serve closes conn after handler returns or raises.
  ; Runs forever — wrap in with-exception-handler to stop.
  (define (tcp-serve port handler)
    (let ((server (tcp-listen port)))
      (let loop ()
        (let ((conn (tcp-accept server)))
          (spawn (lambda ()
                   (with-exception-handler
                     (lambda (e) (tcp-close conn))
                     (lambda ()
                       (handler conn)
                       (tcp-close conn))))))
        (loop)))))
