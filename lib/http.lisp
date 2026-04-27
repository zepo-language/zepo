; lib/http.lisp — HTTP client helpers built on http-request primitive.
(module http
  (export
    http-get http-post http-put http-delete http-head
    http-get-json http-post-json
    http-ok? http-status http-body http-header)

  (define (http-get url)
    (http-request "GET" url '() '()))

  (define (http-post url body)
    (http-request "POST" url '() body))

  (define (http-put url body)
    (http-request "PUT" url '() body))

  (define (http-delete url)
    (http-request "DELETE" url '() '()))

  (define (http-head url)
    (http-request "HEAD" url '() '()))

  (define (http-ok? resp)
    (let ((s (plist-get resp :status)))
      (and (>= s 200) (< s 300))))

  (define (http-status resp)
    (plist-get resp :status))

  (define (http-body resp)
    (plist-get resp :body))

  ; Not available in v1 (http-request only returns :status and :body).
  ; Returns #f always for forward compatibility.
  (define (http-header resp name)
    #f)

  (define (http-get-json url)
    (let ((resp (http-get url)))
      (if (http-ok? resp)
          (json-parse (http-body resp))
          (error (string-append "http-get-json: status "
                                (number->string (http-status resp)))))))

  (define (http-post-json url data)
    (let ((resp (http-request "POST" url
                              '(("Content-Type" . "application/json"))
                              (json-stringify data))))
      (if (http-ok? resp)
          (json-parse (http-body resp))
          (error (string-append "http-post-json: status "
                                (number->string (http-status resp))))))))
