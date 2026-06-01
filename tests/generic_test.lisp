;; zepo-gz21: structs + single-dispatch generic functions.
(import test (deftest is =check throws run-tests))

; ── type-of ─────────────────────────────────────────────────────────────────────

(deftest type-of/builtins
  (=check (list (type-of 1) (type-of 1.5) (type-of #t) (type-of #\a)
                (type-of '()) (type-of '(1)) (type-of "s") (type-of 'x)
                (type-of (vector 1)) (type-of car))
          '(integer float boolean char null pair string symbol vector procedure)))

; ── defstruct ─────────────────────────────────────────────────────────────────

(deftest defstruct/constructor-predicate-accessors
  (defstruct point x y)
  (let ((p (make-point 3 4)))
    (is (point? p))
    (=check (point-x p) 3)
    (=check (point-y p) 4)))

(deftest defstruct/predicate-rejects-other
  (defstruct a v)
  (defstruct b v)
  (is (not (a? (make-b 1))))
  (is (not (a? (vector 1 2)))))

(deftest defstruct/type-of-returns-type
  (defstruct widget label)
  (=check (type-of (make-widget "ok")) 'widget))

; ── defgeneric / defmethod ──────────────────────────────────────────────────────

(deftest generic/dispatches-on-user-type
  (defstruct circle radius)
  (defstruct rect w h)
  (defgeneric area (shape))
  (defmethod area ((s circle)) (* 100 (circle-radius s)))   ; avoid float compare
  (defmethod area ((s rect)) (* (rect-w s) (rect-h s)))
  (=check (area (make-circle 2)) 200)
  (=check (area (make-rect 3 4)) 12))

(deftest generic/dispatches-on-primitive-type
  (defgeneric kind (x))
  (defmethod kind ((x integer)) 'an-int)
  (defmethod kind ((x string)) 'a-str)
  (=check (kind 7) 'an-int)
  (=check (kind "z") 'a-str))

(deftest generic/extra-args-passed-through
  (defstruct vec2 x y)
  (defgeneric scale (v k))
  (defmethod scale ((v vec2) k) (make-vec2 (* (vec2-x v) k) (* (vec2-y v) k)))
  (let ((r (scale (make-vec2 2 3) 10)))
    (=check (vec2-x r) 20)
    (=check (vec2-y r) 30)))

(deftest generic/redefining-method-overrides
  (defstruct thing v)
  (defgeneric label (t))
  (defmethod label ((t thing)) 'first)
  (defmethod label ((t thing)) 'second)
  (=check (label (make-thing 1)) 'second))

(deftest generic/no-applicable-method-errors
  (defstruct only-this v)
  (defgeneric op (x))
  (defmethod op ((x only-this)) 'ok)
  (is (guard (e (#t #t)) (op 42) #f)))   ; calling on int → error → guard true

(run-tests)
