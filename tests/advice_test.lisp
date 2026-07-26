;; zepo-rdan: advice / wrapper convention + the parameterize-hook idiom.
;; zepo-nax0: advise/unadvise operate on GLOBAL bindings (via %global-ref/
;; %global-set!), so each advised target must be a top-level global — a
;; (define ...) inside a deftest body is a LOCAL letrec binding (zepo-3dtd) that
;; advise cannot reach. Targets are therefore defined at top level here, each
;; with a unique name (all top-level defines run at load time before any test
;; thunk, so a shared name would be clobbered by the last definition).
(import test (deftest is =check throws run-tests))

(define (base-greet name) (string-append "Hi " name))

; ── advise: wraps the global ──────────────────────────────────────────────────

(define (wg-f x) (* x 2))
(deftest advise/wraps-global
  (advise 'wg-f (lambda (orig . args) (+ 1 (apply orig args))))
  (let ((r (wg-f 10)))
    (unadvise 'wg-f)
    (=check r 21)))                       ; (10*2)+1

(define (ap-g x) x)
(deftest advise/advised?-predicate
  (is (not (advised? 'ap-g)))
  (advise 'ap-g (lambda (orig . a) (apply orig a)))
  (let ((during (advised? 'ap-g)))
    (unadvise 'ap-g)
    (is during)
    (is (not (advised? 'ap-g)))))

; ── advise: stacking, innermost-first ─────────────────────────────────────────

(define (st-h) "core")
(deftest advise/stacks
  (advise 'st-h (lambda (orig . a) (string-append "[" (apply orig a) "]")))
  (advise 'st-h (lambda (orig . a) (string-append (apply orig a) "!")))
  (let ((r (st-h)))
    (unadvise 'st-h)
    (=check r "[core]!")))

; ── unadvise: restores the original (pre-advice) ──────────────────────────────

(define (ro-k x) x)
(deftest unadvise/restores-original
  (advise 'ro-k (lambda (orig . a) 'wrapped))
  (advise 'ro-k (lambda (orig . a) 'wrapped-again))
  (unadvise 'ro-k)
  (=check (ro-k 5) 5))

(define (idem-m x) x)
(deftest unadvise/idempotent-when-not-advised
  (unadvise 'idem-m)                      ; no-op, must not error
  (=check (idem-m 7) 7))

; ── production idiom: a parameterize'd hook (no global mutation) ──────────────

(deftest hook/parameterize-idiom
  ;; The recommended alternative to advise for library code: a hook held in a
  ;; parameter, switched on for a dynamic extent. Composes, fiber-local, no
  ;; global mutation. These defines are correctly LOCAL — no global advice here.
  (define *on-call* (make-parameter (lambda (x) x)))
  (define (compute x) ((*on-call*) (* x x)))
  (=check
    (list (compute 3)                                   ; default hook: identity
          (parameterize ((*on-call* (lambda (r) (+ r 100))))
            (compute 3))                                ; hooked: 9+100
          (compute 3))                                  ; restored
    '(9 109 9)))

; ── typed advice (zepo-k17w) ────────────────────────────────────────────────────

(define (bef-f x) (* x 10))
(deftest advise/before
  (define log '())
  (advise 'bef-f :before (lambda (x) (set! log (cons x log))))
  (let ((r (bef-f 5)))
    (unadvise 'bef-f)
    (is (= r 50))                ; result unchanged
    (=check log '(5))))          ; before-fn saw the arg

(define (aft-g x) (+ x 1))
(deftest advise/after-sees-result
  (define seen #f)
  (advise 'aft-g :after (lambda (r x) (set! seen (list r x))))
  (let ((r (aft-g 4)))
    (unadvise 'aft-g)
    (is (= r 5))                 ; orig's result returned
    (=check seen '(5 4))))       ; after-fn saw (result arg)

(define (arnd-h x) x)
(deftest advise/around-explicit
  (advise 'arnd-h :around (lambda (orig x) (* 2 (orig x))))
  (let ((r (arnd-h 21)))
    (unadvise 'arnd-h)
    (=check r 42)))

(define (ovr-k x) x)
(deftest advise/override
  (advise 'ovr-k :override (lambda (x) 'replaced))
  (let ((r (ovr-k 9)))
    (unadvise 'ovr-k)
    (=check r 'replaced)))

(define (dflt-m x) x)
(deftest advise/default-is-around
  (advise 'dflt-m (lambda (orig x) (+ 100 (orig x))))   ; 2-arg form
  (let ((r (dflt-m 1)))
    (unadvise 'dflt-m)
    (=check r 101)))

(run-tests)
