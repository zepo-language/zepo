;; zepo-iv6k: keyword-arg tolerance via kw + rest. A rest param after #:keyword
;; params captures the UNKNOWN keyword pairs as a flat plist, enabling tolerant
;; and forwarding APIs. Keyword params take a literal default: (f x :k DEFAULT).
(import test (deftest is =check throws run-tests))

; ── strict kw (no rest) is unchanged ────────────────────────────────────────────

(deftest kw/binds-known
  (=check ((lambda (x :a 0) (list x a)) 1 :a 2) '(1 2)))

(deftest kw/uses-default
  (=check ((lambda (x :a 7) (list x a)) 1) '(1 7)))

(deftest kw/unknown-without-rest-errors
  (is (guard (e (#t #t)) ((lambda (x :a 0) a) 1 :a 2 :bad 3) #f)))

; ── kw + rest: unknown keys forwarded into rest ─────────────────────────────────

(deftest kw-rest/captures-unknown
  (=check ((lambda (x :a 0 . rest) (list x a rest)) 1 :a 2 :zzz 9 :q 5)
          '(1 2 (:zzz 9 :q 5))))

(deftest kw-rest/empty-when-all-known
  (=check ((lambda (x :a 0 . rest) (list x a rest)) 1 :a 2) '(1 2 ())))

(deftest kw-rest/known-not-in-rest
  ;; a is bound and does NOT appear in rest; only unrecognized pairs do
  (=check ((lambda (:a 0 :b 0 . rest) (list a b rest)) :a 1 :b 2 :other 3)
          '(1 2 (:other 3))))

(deftest kw-rest/preserves-order
  (=check ((lambda (:a 0 . rest) rest) :a 1 :x 10 :y 20 :z 30)
          '(:x 10 :y 20 :z 30)))

; ── forwarding pattern (the motivating use case) ────────────────────────────────

(deftest kw-rest/forwarding
  (define (inner x :b 0 :c 0) (list 'inner x b c))
  (define (wrap x :log #f . rest)
    (list 'logged log (apply inner x rest)))
  (=check (wrap 0 :b 10 :c 20 :log #t)
          '(logged #t (inner 0 10 20))))

(run-tests)
