;; zepo-65r: fiber blast-test + benchmark. Counterpart to worker-blast.lisp, but
;; for FIBERS — cooperative green threads sharing one OS thread and ONE heap.
;; The contrast matters:
;;   - workers serialize portable values across heaps; fibers pass live pointers,
;;     so a fiber can mutate shared state and channels move values with no copy.
;;   - workers are OS threads (~ms to spawn); fibers are cheap to create and
;;     switch, so the throughput numbers are orders of magnitude higher.
;; Correctness checks abort via (error ...) on mismatch; reach the end and all held.

(define checks 0)                                          ; zepo-65r
(define (check label got want)
  (set! checks (+ checks 1))
  (if (equal? got want)
      (begin (display "  ok  ") (display label) (newline))
      (error "FAIL" label 'got got 'want want)))

;; ── Section 1: spawn + fiber-join returns the thunk's value ─────────────────
(display "Section 1: spawn + fiber-join return values") (newline)
(let loop ((i 0) (sum 0))
  (if (< i 8)
      (let ((f (spawn (lambda () (* i i)))))               ; capture i by closure
        (loop (+ i 1) (+ sum (fiber-join f))))
      (check "joined squares 0..7 summed" sum 140)))       ; 0+1+4+9+16+25+36+49

;; ── Section 2: fibers share ONE heap (no copy) ──────────────────────────────
;; Each fiber mutates a shared top-level accumulator — impossible across workers,
;; trivial across fibers. fiber-join forces each to run to completion.
(display "Section 2: shared-heap mutation across fibers") (newline)
(define total 0)
(define shared (make-hash-table))
(hash-set! shared "hits" 0)
(let ((handles
        (let loop ((i 1) (acc (quote ())))
          (if (<= i 50)
              (loop (+ i 1)
                    (cons (spawn (lambda ()
                                   (set! total (+ total i))
                                   (hash-set! shared "hits"
                                              (+ (hash-get shared "hits" 0) 1))))
                          acc))
              acc))))
  (for-each fiber-join handles)
  (check "shared counter summed across 50 fibers" total 1275)   ; 50*51/2
  (check "shared hashtable mutated in place"      (hash-get shared "hits" 0) 50))

;; ── Section 3: producer/consumer over an in-heap channel ────────────────────
(display "Section 3: producer/consumer over a channel") (newline)
(define (run-pipe n)
  (let ((ch (make-channel 16)))
    (spawn (lambda ()                                      ; producer
             (let loop ((i 1))
               (if (<= i n) (begin (channel-send! ch i) (loop (+ i 1)))
                   (channel-send! ch 'done)))))
    (let ((consumer
            (spawn (lambda ()                              ; consumer accumulates
                     (let loop ((acc 0))
                       (let ((v (channel-recv! ch)))
                         (if (number? v) (loop (+ acc v)) acc)))))))
      (fiber-join consumer))))
(check "producer/consumer summed 1..100" (run-pipe 100) 5050)

;; ── Section 4: error propagation ────────────────────────────────────────────
(display "Section 4: fiber error flags + result") (newline)
(let ((f (spawn (lambda () (error "boom")))))
  (let wait ()
    (if (or (fiber-done? f) (fiber-errored? f))
        (begin
          (check "errored fiber is flagged errored" (fiber-errored? f) #t)
          (check "errored fiber is not flagged done" (fiber-done? f) #f))
        (begin (yield) (wait)))))

;; ── Correctness summary ─────────────────────────────────────────────────────
(display "ALL ") (display checks) (display " CHECKS PASSED") (newline)
(newline)

;; ── Benchmark phase ─────────────────────────────────────────────────────────
;; Timed with current-time-ms; tune volume with a numeric arg:
;;   zepo fiber-blast.lisp -- 4
(define (parse-scale args)
  (let loop ((a args) (found 1))
    (if (null? a) found
        (let ((n (string->number (car a))))
          (loop (cdr a) (if (and n (> n 0)) n found))))))
(define scale (parse-scale (argv)))

(define (bench label ops thunk)
  (let ((t0 (current-time-ms)))
    (thunk)
    (let ((dt (- (current-time-ms) t0)))
      (display "  ") (display label) (display ": ")
      (display ops) (display " ops in ") (display dt) (display " ms")
      (if (> dt 0)
          (begin (display "  (")
                 (display (quotient (* ops 1000) dt))
                 (display " ops/sec)")))
      (newline))))

(display "Benchmark (scale=") (display scale) (display ")") (newline)

;; Order matters: the "few live fibers" workloads run FIRST. spawn+join is run
;; LAST because completed fibers are not yet reaped (see zepo-4d6) — the GC roots
;; every entry of vm.fibers each collection, so once tens of thousands of dead
;; fibers accumulate, later GCs slow down and would taint the other numbers.

;; B1: raw yield throughput — one fiber yields M times while main parks in join.
;; Measures bare cooperative context-switch cost (only ~2 live fibers).
(define yield-iters (* 100000 scale))
(bench "yield (context switch)" yield-iters
  (lambda ()
    (fiber-join
      (spawn (lambda ()
               (let loop ((i 0))
                 (if (< i yield-iters) (begin (yield) (loop (+ i 1))) i)))))))

;; B2: channel send/recv throughput between two fibers (no serialization, no copy).
(define chan-iters (* 50000 scale))
(bench "channel send/recv" chan-iters
  (lambda () (run-pipe chan-iters)))

;; B3: spawn + immediate fiber-join, serially. Measures green-thread
;; create/run/teardown (contrast with worker-blast's ~1ms OS-thread spawn).
;; This scales linearly since zepo-4d6 (completed fibers are reaped from the
;; scheduler set and their handles are nursery-collected, so neither the GC root
;; scan nor old-gen pressure grows with total spawns). Kept as a regression guard:
;; if ops/sec starts degrading as you raise the scale, that fix has regressed.
(define spawn-iters (* 20000 scale))
(bench "spawn+join" spawn-iters
  (lambda ()
    (let loop ((i 0))
      (if (< i spawn-iters)
          (begin (fiber-join (spawn (lambda () i))) (loop (+ i 1)))))))
