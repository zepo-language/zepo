;; zepo-rdan: advice / wrapper convention + the parameterize-hook idiom.
(import test (deftest is =check throws run-tests))

(define (base-greet name) (string-append "Hi " name))

; ── advise: wraps the global ──────────────────────────────────────────────────

(deftest advise/wraps-global
  (define (f x) (* x 2))
  (advise 'f (lambda (orig . args) (+ 1 (apply orig args))))
  (let ((r (f 10)))
    (unadvise 'f)
    (=check r 21)))                       ; (10*2)+1

(deftest advise/advised?-predicate
  (define (g x) x)
  (is (not (advised? 'g)))
  (advise 'g (lambda (orig . a) (apply orig a)))
  (let ((during (advised? 'g)))
    (unadvise 'g)
    (is during)
    (is (not (advised? 'g)))))

; ── advise: stacking, innermost-first ─────────────────────────────────────────

(deftest advise/stacks
  (define (h) "core")
  (advise 'h (lambda (orig . a) (string-append "[" (apply orig a) "]")))
  (advise 'h (lambda (orig . a) (string-append (apply orig a) "!")))
  (let ((r (h)))
    (unadvise 'h)
    (=check r "[core]!")))

; ── unadvise: restores the original (pre-advice) ──────────────────────────────

(deftest unadvise/restores-original
  (define (k x) x)
  (advise 'k (lambda (orig . a) 'wrapped))
  (advise 'k (lambda (orig . a) 'wrapped-again))
  (unadvise 'k)
  (=check (k 5) 5))

(deftest unadvise/idempotent-when-not-advised
  (define (m x) x)
  (unadvise 'm)                           ; no-op, must not error
  (=check (m 7) 7))

; ── production idiom: a parameterize'd hook (no global mutation) ──────────────

(deftest hook/parameterize-idiom
  ;; The recommended alternative to advise for library code: a hook held in a
  ;; parameter, switched on for a dynamic extent. Composes, fiber-local, no
  ;; global mutation.
  (define *on-call* (make-parameter (lambda (x) x)))
  (define (compute x) ((*on-call*) (* x x)))
  (=check
    (list (compute 3)                                   ; default hook: identity
          (parameterize ((*on-call* (lambda (r) (+ r 100))))
            (compute 3))                                ; hooked: 9+100
          (compute 3))                                  ; restored
    '(9 109 9)))

(run-tests)
