; lib/orch/exec.lisp — plan executor for the orchestrator.
;
; Walks core plan forms and dispatches them through the tool registry.
; v1 plan grammar (positional, surface keyword form is a later sugar):
;
;   (tool-call    "id" 'tool-symbol ((arg . val) ...))
;   (sequence     step ...)               ; short-circuit on first err
;   (parallel     step ...)               ; fibers + channel collect
;   (final-answer "id")
;
; Concurrency for `parallel` is via Zepo FIBERS, not OS-thread workers.
; The tool registry, schemas, and orch/* modules already live in the
; parent VM. Workers would force source-string serialisation and pay a
; full-VM startup per call. The cooperative scheduler already yields at
; HTTP/poll-bound steps, so two parallel curl-backed tool calls actually
; do overlap on the OS. If a future tool needs CPU parallelism it can
; opt in to spawn-worker explicitly.
;
; Result context shape: alist ((id . step-result) ...) where
;   step-result is (ok value) | (err kind msg).
;
; run-plan returns:
;   (ok ctx)                                 ; plan completed
;   (err 'plan-failed (cons id step-err))    ; sequence short-circuited
;   (err 'bad-plan msg)                      ; malformed plan
;
; zepo-ekd

(module orch/exec
  (export run-plan plan-result step-result-of)

  (import orch/registry)

  ; Top-level entry. ctx starts empty; each step may append (id . result).
  (define (run-plan plan)
    (run-step plan '()))

  (define (run-step plan ctx)
    (cond
      ((not (pair? plan)) (err 'bad-plan "plan form must be a pair"))
      (else
        (let ((tag (car plan)) (rest (cdr plan)))
          (cond
            ((eq? tag 'tool-call)    (run-tool-call    rest ctx))
            ((eq? tag 'sequence)     (run-sequence     rest ctx))
            ((eq? tag 'parallel)     (run-parallel     rest ctx))
            ((eq? tag 'final-answer) (run-final-answer rest ctx))
            (else (err 'bad-plan
                       (string-append "unknown plan form: "
                                      (if (symbol? tag)
                                          (symbol->string tag)
                                          "<non-symbol>")))))))))

  ; (tool-call ID TOOL ARGS) — looks up TOOL in the registry, validates
  ; ARGS, calls it, records the result under ID in ctx, returns (ok ctx).
  ; Tool-internal errors are RECORDED (not propagated) — sequence checks
  ; them and decides whether to short-circuit; parallel surfaces them
  ; alongside successes.
  (define (run-tool-call rest ctx)
    (cond
      ((or (null? rest)
           (null? (cdr rest))
           (null? (cdr (cdr rest))))
       (err 'bad-plan "tool-call needs id, tool, args"))
      (else
        (let ((id   (car rest))
              (tool (car (cdr rest)))
              (args (car (cdr (cdr rest)))))
          (cond
            ((not (string? id))
             (err 'bad-plan "tool-call id must be a string"))
            ((not (symbol? tool))
             (err 'bad-plan "tool-call tool must be a symbol"))
            (else
              (let ((entry (lookup-tool tool)))
                (cond
                  ((not entry)
                   (let ((step (err 'unknown-tool (symbol->string tool))))
                     (ok (cons (cons id step) ctx))))
                  (else
                    (let ((step (call-tool entry args)))
                      (ok (cons (cons id step) ctx))))))))))))

  ; (sequence STEP ...) — run children left-to-right. If any step result
  ; is itself an err, short-circuit and return (err 'plan-failed (cons id
  ; step-err)). Other forms (parallel inside sequence, etc.) propagate
  ; their own err on bad-plan.
  (define (run-sequence steps ctx)
    (cond
      ((null? steps) (ok ctx))
      (else
        (let ((r (run-step (car steps) ctx)))
          (cond
            ((err? r) r)
            (else
              (let* ((new-ctx (result-value r))
                     (bad     (sequence-short-circuit? new-ctx ctx)))
                (cond
                  (bad  (err 'plan-failed bad))
                  (else (run-sequence (cdr steps) new-ctx))))))))))

  ; If the latest step's result is an err, return (cons id err-result);
  ; otherwise #f. ctx grows by cons-ing onto the front, so the most
  ; recent entry is at the head.
  (define (sequence-short-circuit? new-ctx old-ctx)
    (cond
      ((eq? new-ctx old-ctx) #f)
      ((null? new-ctx) #f)
      (else
        (let ((head (car new-ctx)))
          (cond
            ((not (pair? head)) #f)
            ((err? (cdr head)) head)
            (else #f))))))

  ; (parallel STEP ...) — spawn one fiber per child, each writing its
  ; result entry to a shared channel; parent collects N results. Each
  ; step's recorded result is whatever its sub-form returned (an entire
  ; sub-ctx, in fact); we flatten by pulling out the latest entry of
  ; each one. Failures are recorded but do not short-circuit — the
  ; whole batch always completes.
  (define (run-parallel steps ctx)
    (let ((n (length steps)))
      (cond
        ((= n 0) (ok ctx))
        (else
          (let ((ch (make-channel n)))
            (for-each
              (lambda (step)
                (spawn (lambda ()
                  (let ((r (run-step step '())))
                    (channel-send! ch r)))))
              steps)
            (let loop ((i 0) (merged ctx))
              (cond
                ((= i n) (ok merged))
                (else
                  (let ((r (channel-recv! ch)))
                    (cond
                      ((err? r)
                       ; A bad-plan inside a parallel child becomes a
                       ; recorded err but doesn't abort the batch.
                       (loop (+ i 1)
                             (cons (cons (gensym-id) r) merged)))
                      (else
                        ; result-value is the child's ctx (or '()); merge
                        ; its entries onto ours.
                        (loop (+ i 1)
                              (append (result-value r) merged)))))))))))))

  ; (final-answer ID) — no-op for execution; the caller pulls the named
  ; entry out of ctx via plan-result. Recorded as a sentinel so the ctx
  ; remembers which id was the "answer".
  (define (run-final-answer rest ctx)
    (cond
      ((or (null? rest) (not (string? (car rest))))
       (err 'bad-plan "final-answer needs an id string"))
      (else
        (ok (cons (cons "__final__" (ok (car rest))) ctx)))))

  ; Pull the final answer's value out of a finished ctx.
  ; Returns (ok value) | (err 'no-final-answer ...) | (err ...) propagated.
  (define (plan-result ctx)
    (let ((final-id (assoc-cdr "__final__" ctx)))
      (cond
        ((not final-id)
         (err 'no-final-answer "plan did not name a final-answer"))
        ((err? final-id) final-id)
        (else
          (let ((target-id (result-value final-id)))
            (step-result-of target-id ctx))))))

  ; Look up a particular step's result by id.
  (define (step-result-of id ctx)
    (let ((entry (assoc id ctx)))
      (cond
        ((not entry)
         (err 'no-such-step (string-append "no step with id " id)))
        (else (cdr entry)))))

  ; ── Helpers ────────────────────────────────────────────────────────────

  (define (assoc-cdr key alist)
    (let ((p (assoc key alist)))
      (and p (cdr p))))

  ; Synthetic id for unnamed errors (bad-plan inside parallel). Not a
  ; real gensym since these never collide with caller-chosen ids and the
  ; values are debug-only.
  (define gensym-counter (vector 0))
  (define (gensym-id)
    (let ((n (vector-ref gensym-counter 0)))
      (vector-set! gensym-counter 0 (+ n 1))
      (string-append "__err_" (number->string n)))))
