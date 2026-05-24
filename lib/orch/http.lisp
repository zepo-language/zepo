; lib/orch/http.lisp — HTTP client for the orchestrator.
;
; Built on a curl subprocess because the in-process http-request primitive
; is stubbed in Zig 0.16 (zepo-04p). When the native client lands this
; module can be re-implemented on top of it without changing the API.
;
; zepo-0p1

(module orch/http
  (export http-post-json)

  ; Send a POST with a JSON body and return (ok (cons status body))
  ; on HTTP completion (status may be any value, including 4xx/5xx),
  ; or (err kind msg) if the request itself failed (no connection,
  ; timeout, malformed args).
  ;
  ; Body is sent as raw bytes; the caller is responsible for JSON
  ; serialization. Response body is returned as a string; the caller
  ; decides whether to json-parse it.
  ;
  ; Optional timeout-secs (default 60) caps the entire request.
  (define (http-post-json url body-str . rest)
    (let ((timeout (if (null? rest) 60 (car rest))))
      (let ((p (process-spawn
                 "curl"
                 "-s"
                 "-X" "POST"
                 "-H" "Content-Type: application/json"
                 "--data-binary" "@-"
                 "--max-time" (number->string timeout)
                 "-w" "%{http_code}"
                 url)))
        (process-send p body-str)
        (process-close-stdin p)
        (let ((out  (process-recv-all p))
              (code (process-wait p)))
          (cond
            ((= code 0) (parse-curl-output out))
            ((= code 28) (err 'timeout
                              (string-append "request exceeded "
                                             (number->string timeout)
                                             " seconds")))
            ((= code 6) (err 'dns "could not resolve host"))
            ((= code 7) (err 'connect "could not connect to host"))
            (else (err 'curl-error
                       (string-append "curl exit code "
                                      (number->string code)))))))))

  ; Curl's -w "%{http_code}" appends the 3-digit HTTP status to stdout
  ; with no separator. Split: last 3 bytes = status, rest = body.
  (define (parse-curl-output out)
    (let ((len (string-length out)))
      (if (< len 3)
          (err 'protocol
               (string-append "response shorter than 3 bytes: "
                              (number->string len)))
          (let* ((status-str (substring out (- len 3) len))
                 (body       (substring out 0 (- len 3)))
                 (status     (string->number status-str)))
            (if (not status)
                (err 'protocol
                     (string-append "could not parse status: "
                                    status-str))
                (ok (cons status body))))))))
