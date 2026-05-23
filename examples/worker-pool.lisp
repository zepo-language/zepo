; zepo-0us: worker-pool example
;
; A fixed pool of OS-thread workers that square numbers in parallel.
; Workers read jobs from a shared channel and write results to another.
;
; Run:
;   zepo examples/worker-pool.lisp

(define N-WORKERS 4)
(define N-JOBS    20)

(define job-ch    (make-channel 32))
(define result-ch (make-channel 32))

; Each worker reads numbers from job-ch, squares them, writes to result-ch.
; A #f sentinel tells the worker to exit cleanly.
(define worker-code
  "(lambda (jobs out)
    (let loop ()
      (let ((x (channel-recv! jobs)))
        (when x
          (channel-send! out (* x x))
          (loop)))))")

; Spawn the pool.
(define workers
  (let loop ((i 0) (acc '()))
    (if (= i N-WORKERS) acc
        (loop (+ i 1)
              (cons (spawn-worker worker-code job-ch result-ch)
                    acc)))))

; Submit N-JOBS jobs.
(let loop ((i 0))
  (when (< i N-JOBS)
    (channel-send! job-ch i)
    (loop (+ i 1))))

; Collect N-JOBS results (order may differ from submission order).
(define results
  (let loop ((n 0) (acc '()))
    (if (= n N-JOBS) acc
        (loop (+ n 1) (cons (channel-recv! result-ch) acc)))))

; Sort and display.
(define sorted (sort results <))
(for-each (lambda (r) (display r) (display " ")) sorted)
(newline)

; Send one #f sentinel per worker to signal shutdown, then wait for all to finish.
(let loop ((i 0))
  (when (< i N-WORKERS)
    (channel-send! job-ch #f)
    (loop (+ i 1))))

(let loop ((ws workers))
  (when (pair? ws)
    (let wait ()
      (when (worker-alive? (car ws))
        (sleep 0.01)
        (wait)))
    (loop (cdr ws))))
