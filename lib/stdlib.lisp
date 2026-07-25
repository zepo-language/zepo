; Zepo prelude — derived forms and list utilities.
;
; `let`, `let*`, `letrec`, `and`, `or`, `when`, `unless` are recognized by
; the AST builder and desugared to core forms. Everything else is plain
; Zepo code on top of the primitives.

(define (length lst)
  (if (null? lst)
      0
      (+ 1 (length (cdr lst)))))

(define (map f . lists)
  (letrec ((cars (lambda (ls)
                   (if (null? ls) (quote ()) (cons (car (car ls)) (cars (cdr ls))))))
           (cdrs (lambda (ls)
                   (if (null? ls) (quote ()) (cons (cdr (car ls)) (cdrs (cdr ls))))))
           (go   (lambda (ls)
                   (if (null? (car ls))
                       (quote ())
                       (cons (apply f (cars ls)) (go (cdrs ls)))))))
    (go lists)))

(define (filter pred lst)
  (cond ((null? lst) (quote ()))
        ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
        (#t (filter pred (cdr lst)))))

(define (fold-left f acc lst)
  (if (null? lst)
      acc
      (fold-left f (f acc (car lst)) (cdr lst))))

(define (fold-right f init lst)
  (if (null? lst)
      init
      (f (car lst) (fold-right f init (cdr lst)))))

(define (append . lists)
  (letrec ((append2 (lambda (lst1 lst2)
                      (if (null? lst1)
                          lst2
                          (cons (car lst1) (append2 (cdr lst1) lst2)))))
           (concat  (lambda (ls)
                      (if (null? ls) (quote ())
                          (if (null? (cdr ls)) (car ls)
                              (append2 (car ls) (concat (cdr ls))))))))
    (concat lists)))

(define (reverse lst)
  (if (null? lst)
      (quote ())
      (append (reverse (cdr lst)) (cons (car lst) (quote ())))))

(define (for-each f . lists)
  (letrec ((cars (lambda (ls)
                   (if (null? ls) (quote ()) (cons (car (car ls)) (cars (cdr ls))))))
           (cdrs (lambda (ls)
                   (if (null? ls) (quote ()) (cons (cdr (car ls)) (cdrs (cdr ls))))))
           (go   (lambda (ls)
                   (if (null? (car ls))
                       (quote ())
                       (begin (apply f (cars ls)) (go (cdrs ls)))))))
    (go lists)))

(define (assoc key lst)
  (cond ((null? lst) #f)
        ((equal? key (car (car lst))) (car lst))
        (#t (assoc key (cdr lst)))))

(define (member x lst)
  (cond ((null? lst) #f)
        ((equal? x (car lst)) lst)
        (#t (member x (cdr lst)))))

(define (caar x) (car (car x)))
(define (cadr x) (car (cdr x)))
(define (cdar x) (cdr (car x)))
(define (cddr x) (cdr (cdr x)))
(define (caddr x) (car (cdr (cdr x))))
(define (cadddr x) (car (cdr (cdr (cdr x)))))

(define (zero? n) (= n 0))
(define (positive? n) (> n 0))
(define (negative? n) (< n 0))

(define (abs n) (if (< n 0) (- n) n))

(define (min2 a b) (if (< a b) a b))
(define (max2 a b) (if (> a b) a b))
; Zepo standard library.
; Loaded after the prelude. Depends on all primitives and prelude definitions.

;;; ── List predicates ───────────────────────────────────────────────────────

(define (list? x)
  (let loop ((fast x) (slow x))
    (cond ((null? fast) #t)
          ((not (pair? fast)) #f)
          ((null? (cdr fast)) #t)
          ((not (pair? (cdr fast))) #f)
          ((eq? (cddr fast) slow) #f)
          (#t (loop (cddr fast) (cdr slow))))))

;;; ── List access ───────────────────────────────────────────────────────────

(define (list-ref lst n)
  (if (= n 0)
      (car lst)
      (list-ref (cdr lst) (- n 1))))

(define (list-tail lst n)
  (if (= n 0)
      lst
      (list-tail (cdr lst) (- n 1))))

(define (last lst)
  (if (null? (cdr lst))
      (car lst)
      (last (cdr lst))))

(define (take lst n)
  (if (or (= n 0) (null? lst))
      (quote ())
      (cons (car lst) (take (cdr lst) (- n 1)))))

(define (drop lst n)
  (list-tail lst n))

;;; ── List generation ───────────────────────────────────────────────────────

(define (iota count . args)
  (let ((start (if (null? args) 0 (car args)))
        (step  (if (or (null? args) (null? (cdr args))) 1 (cadr args))))
    (let loop ((i 0) (acc (quote ())))
      (if (= i count)
          (reverse acc)
          (loop (+ i 1) (cons (+ start (* i step)) acc))))))

;;; ── List higher-order ─────────────────────────────────────────────────────

(define (any pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) #t)
        (#t (any pred (cdr lst)))))

(define (every pred lst)
  (cond ((null? lst) #t)
        ((not (pred (car lst))) #f)
        (#t (every pred (cdr lst)))))

(define (find pred lst)
  (cond ((null? lst) #f)
        ((pred (car lst)) (car lst))
        (#t (find pred (cdr lst)))))

(define (remove pred lst)
  (filter (lambda (x) (not (pred x))) lst))

(define (count pred lst)
  (fold-left (lambda (acc x) (if (pred x) (+ acc 1) acc)) 0 lst))

(define (flatten lst)
  (cond ((null? lst) (quote ()))
        ((pair? (car lst)) (append (flatten (car lst)) (flatten (cdr lst))))
        (#t (cons (car lst) (flatten (cdr lst))))))

(define (zip . lists)
  (if (any null? lists)
      (quote ())
      (cons (map car lists) (apply zip (map cdr lists)))))

;;; ── Alist helpers ─────────────────────────────────────────────────────────

(define (alist-get key al)
  (let ((pair (assoc key al)))
    (if pair (cdr pair) #f)))

(define (alist-set key val al)
  (cons (cons key val)
        (filter (lambda (p) (not (equal? (car p) key))) al)))

(define (alist-delete key al)
  (filter (lambda (p) (not (equal? (car p) key))) al))

(define (alist-keys al)
  (map car al))

(define (alist-values al)
  (map cdr al))

(define (assq key lst)
  (cond ((null? lst) #f)
        ((eq? key (car (car lst))) (car lst))
        (#t (assq key (cdr lst)))))

(define (memq x lst)
  (cond ((null? lst) #f)
        ((eq? x (car lst)) lst)
        (#t (memq x (cdr lst)))))

;;; ── Numbers ───────────────────────────────────────────────────────────────

(define (min first . rest)
  (fold-left min2 first rest))

(define (max first . rest)
  (fold-left max2 first rest))

; Simple O(n) expt — fast expt added when even?/modulo available.
(define (expt base exp)
  (if (= exp 0)
      1
      (* base (expt base (- exp 1)))))

;;; ── Characters ────────────────────────────────────────────────────────────

(define (char=?  a b) (= (char->integer a) (char->integer b)))
(define (char<?  a b) (< (char->integer a) (char->integer b)))
(define (char>?  a b) (> (char->integer a) (char->integer b)))
(define (char<=? a b) (<= (char->integer a) (char->integer b)))
(define (char>=? a b) (>= (char->integer a) (char->integer b)))

(define (char-alphabetic? c)
  (let ((n (char->integer c)))
    (or (and (>= n 65) (<= n 90))
        (and (>= n 97) (<= n 122)))))

(define (char-numeric? c)
  (let ((n (char->integer c)))
    (and (>= n 48) (<= n 57))))

(define (char-whitespace? c)
  (let ((n (char->integer c)))
    (or (= n 32) (= n 9) (= n 10) (= n 13))))

(define (char-upcase c)
  (let ((n (char->integer c)))
    (if (and (>= n 97) (<= n 122))
        (integer->char (- n 32))
        c)))

(define (char-downcase c)
  (let ((n (char->integer c)))
    (if (and (>= n 65) (<= n 90))
        (integer->char (+ n 32))
        c)))

;;; ── Strings ───────────────────────────────────────────────────────────────

(define (string=?  a b) (equal? a b))
(define (string<?  a b)
  (let loop ((i 0))
    (cond ((= i (string-length a)) (< (string-length a) (string-length b)))
          ((= i (string-length b)) #f)
          ((char<? (string-ref a i) (string-ref b i)) #t)
          ((char>? (string-ref a i) (string-ref b i)) #f)
          (#t (loop (+ i 1))))))
(define (string>?  a b) (string<? b a))
(define (string<=? a b) (not (string>? a b)))
(define (string>=? a b) (not (string<? a b)))

(define (string->list s)
  (let loop ((i (- (string-length s) 1)) (acc (quote ())))
    (if (< i 0)
        acc
        (loop (- i 1) (cons (string-ref s i) acc)))))

(define (string-contains s sub)
  (let ((sl (string-length s))
        (pl (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i pl) sl) #f)
            ((equal? (substring s i (+ i pl)) sub) i)
            (#t (loop (+ i 1)))))))

(define (string-join strs sep)
  (if (null? strs)
      ""
      (fold-left (lambda (acc s) (string-append acc sep s))
                 (car strs)
                 (cdr strs))))

(define (string-trim-left s)
  (let loop ((i 0))
    (cond ((= i (string-length s)) "")
          ((char-whitespace? (string-ref s i)) (loop (+ i 1)))
          (#t (substring s i (string-length s))))))

(define (string-trim-right s)
  (let loop ((i (- (string-length s) 1)))
    (cond ((< i 0) "")
          ((char-whitespace? (string-ref s i)) (loop (- i 1)))
          (#t (substring s 0 (+ i 1))))))

(define (string-trim s)
  (string-trim-left (string-trim-right s)))

(define (string-split s delim)
  (define delim-str (if (char? delim) (char->string delim) delim))
  (let ((dl (string-length delim-str))
        (sl (string-length s)))
    (let loop ((i 0) (start 0) (acc (quote ())))
      (cond ((> (+ i dl) sl)
             (reverse (cons (substring s start sl) acc)))
            ((equal? (substring s i (+ i dl)) delim-str)
             (loop (+ i dl) (+ i dl) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

;;; ── Higher-order utilities ────────────────────────────────────────────────

(define (compose f g) (lambda (x) (f (g x))))
(define (identity x) x)
(define (const x) (lambda args x))
(define (flip f) (lambda (a b) (f b a)))

;;; ── I/O ───────────────────────────────────────────────────────────────────

(define (println x) (begin (display x) (newline)))

;;; ── Misc ──────────────────────────────────────────────────────────────────

(define (assert expr)
  (if (not expr) (error "Assertion failed") expr))

;;; ── Vector utilities ──────────────────────────────────────────────────────

(define (vector->list v)
  (let loop ((i (- (vector-length v) 1)) (acc (quote ())))
    (if (< i 0)
        acc
        (loop (- i 1) (cons (vector-ref v i) acc)))))

(define (list->vector lst)
  (let* ((len (length lst))
         (v   (make-vector len #f)))
    (let loop ((i 0) (l lst))
      (if (null? l)
          v
          (begin (vector-set! v i (car l))
                 (loop (+ i 1) (cdr l)))))))

(define (vector-map f v)
  (let* ((len (vector-length v))
         (out (make-vector len #f)))
    (let loop ((i 0))
      (if (= i len)
          out
          (begin (vector-set! out i (f (vector-ref v i)))
                 (loop (+ i 1)))))))

(define (vector-for-each f v)
  (let loop ((i 0))
    (if (= i (vector-length v))
        (quote ())
        (begin (f (vector-ref v i))
               (loop (+ i 1))))))

;;; ── Extended cXr ──────────────────────────────────────────────────────────

(define (caaar x)  (car (car (car x))))
(define (cdaar x)  (cdr (car (car x))))
(define (cadar x)  (car (cdr (car x))))
(define (cddar x)  (cdr (cdr (car x))))
(define (caadr x)  (car (car (cdr x))))
(define (cdadr x)  (cdr (car (cdr x))))
(define (cdddr x)  (cdr (cdr (cdr x))))
(define (cadaar x) (car (cdr (car (car x)))))
(define (caddar x) (car (cdr (cdr (car x)))))
(define (cadadr x) (car (cdr (car (cdr x)))))
(define (caaddr x) (car (car (cdr (cdr x)))))
(define (cddddr x) (cdr (cdr (cdr (cdr x)))))
(define (caaaar x) (car (car (car (car x)))))

;;; ── Sort ──────────────────────────────────────────────────────────────────

;; zepo-sb7: tail-recursive merge sort. The old version's `merge` was
;; non-tail-recursive — every cons added a stack frame, so a list of 50k
;; elements stacked 50k frames per merge pass and blew the heap. Now merge
;; builds its result in reverse via an accumulator then splices it back with
;; rev-append, both of which are tail calls. Split is unchanged (already
;; tail-recursive). The recursion in `sort` itself is depth log2(n).
(define (sort lst less?)
  (define (rev-append rev tail)
    (if (null? rev) tail
        (rev-append (cdr rev) (cons (car rev) tail))))
  (define (merge a b)
    (let loop ((a a) (b b) (acc (quote ())))
      (cond ((null? a) (rev-append acc b))
            ((null? b) (rev-append acc a))
            ((less? (car a) (car b))
             (loop (cdr a) b (cons (car a) acc)))
            (#t
             (loop a (cdr b) (cons (car b) acc))))))
  (define (split lst)
    (let loop ((fast lst) (slow lst) (left (quote ())))
      (if (or (null? fast) (null? (cdr fast)))
          (cons left slow)
          (loop (cddr fast) (cdr slow) (cons (car slow) left)))))
  (if (or (null? lst) (null? (cdr lst)))
      lst
      (let* ((halves (split lst))
             (left   (sort (car halves) less?))
             (right  (sort (cdr halves) less?)))
        (merge left right))))

;;; ── Added after Zig primitives ────────────────────────────────────────────

(define (even? n) (= (modulo n 2) 0))
(define (odd?  n) (not (even? n)))

(define (gcd a b)
  (if (= b 0) (abs a) (gcd b (modulo a b))))

(define (lcm a b)
  (/ (abs (* a b)) (gcd a b)))

; Fast expt using even? now that modulo is available.
(define (expt base exp)
  (cond ((= exp 0) 1)
        ((even? exp) (let ((half (expt base (/ exp 2)))) (* half half)))
        (#t (* base (expt base (- exp 1))))))

(define (list->string chars)
  (apply string-append (map char->string chars)))

(define (writeln x) (begin (write x) (newline)))

;;; ── Plist helpers ─────────────────────────────────────────────────────────
; Plists are flat lists: (key1 val1 key2 val2 ...)

(define (plist-get pl key)
  (cond ((null? pl) #f)
        ((equal? (car pl) key) (cadr pl))
        (#t (plist-get (cddr pl) key))))

(define (plist-set pl key val)
  (cond ((null? pl) (list key val))
        ((equal? (car pl) key) (cons key (cons val (cddr pl))))
        (#t (cons (car pl) (cons (cadr pl) (plist-set (cddr pl) key val))))))

(define (plist-has? pl key)
  (cond ((null? pl) #f)
        ((equal? (car pl) key) #t)
        (#t (plist-has? (cddr pl) key))))

(define (plist-keys pl)
  (if (null? pl)
      (quote ())
      (cons (car pl) (plist-keys (cddr pl)))))

(define (plist-values pl)
  (if (null? pl)
      (quote ())
      (cons (cadr pl) (plist-values (cddr pl)))))

(define (plist-delete pl key)
  (cond ((null? pl) (quote ()))
        ((equal? (car pl) key) (cddr pl))
        (#t (cons (car pl) (cons (cadr pl) (plist-delete (cddr pl) key))))))

(define (plist->alist pl)
  (if (null? pl)
      (quote ())
      (cons (cons (car pl) (cadr pl)) (plist->alist (cddr pl)))))

(define (alist->plist al)
  (if (null? al)
      (quote ())
      (cons (car (car al)) (cons (cdr (car al)) (alist->plist (cdr al))))))

; Result objects — used by FFI and anything that can fail without throwing.
; Shape:
;   ok:  (cons 'ok value)                 — single-alloc success wrapper.
;   err: (list 'err kind-symbol message)  — symbol kind + string message.
; Constructors avoid clashing with the built-in `error` primitive.

(define (ok val) (cons (quote ok) val))

(define (err kind message) (list (quote err) kind message))

(define (ok? r)
  (and (pair? r) (eq? (car r) (quote ok))))

(define (err? r)
  (and (pair? r) (eq? (car r) (quote err))))

(define (result-value r) (cdr r))

(define (err-kind r) (cadr r))

(define (err-message r) (caddr r))

;;; ── String utilities ──────────────────────────────────────────────────────

(define (string-repeat str n)
  (if (<= n 0) ""
      (string-append str (string-repeat str (- n 1)))))

(define (string-replace str old new)
  (let ((slen (string-length str))
        (olen (string-length old)))
    (if (= olen 0) str
        (let loop ((i 0) (acc ""))
          (if (> (+ i olen) slen)
              (string-append acc (substring str i slen))
              (if (equal? (substring str i (+ i olen)) old)
                  (loop (+ i olen) (string-append acc new))
                  (loop (+ i 1) (string-append acc (substring str i (+ i 1))))))))))

(define (string-pad-left str width ch)
  (let ((len (string-length str)))
    (if (>= len width) str
        (string-append (string-repeat (char->string ch) (- width len)) str))))

(define (string-pad-right str width ch)
  (let ((len (string-length str)))
    (if (>= len width) str
        (string-append str (string-repeat (char->string ch) (- width len))))))

(define (string-prefix? prefix str)
  (let ((plen (string-length prefix))
        (slen (string-length str)))
    (if (> plen slen) #f
        (equal? prefix (substring str 0 plen)))))

(define (string-suffix? suffix str)
  (let ((suflen (string-length suffix))
        (slen (string-length str)))
    (if (> suflen slen) #f
        (equal? suffix (substring str (- slen suflen) slen)))))

(define (string-index str ch . rest)
  (let ((start (if (null? rest) 0 (car rest)))
        (len (string-length str)))
    (let loop ((i start))
      (cond ((>= i len) #f)
            ((equal? (string-ref str i) ch) i)
            (#t (loop (+ i 1)))))))

(defmacro guard (var-and-clauses . body)
  `(with-exception-handler
     (lambda (,(car var-and-clauses))
       (cond
         ,@(cdr var-and-clauses)
         (else (raise ,(car var-and-clauses)))))
     (lambda () ,@body)))

; zepo-rdan: advice / wrapper convention.
;
; (advise 'name wrapper) replaces the global function bound to `name` with a
; wrapper. The wrapper is called as (wrapper orig arg ...), where `orig` is the
; function that was bound just before this advise — invoke it with
; (apply orig args). Advice stacks; (unadvise 'name) restores the original
; (pre-advice) function and drops all advice on it.
;
;   (advise 'http-get
;     (lambda (orig . args)
;       (log "fetching" (car args))
;       (apply orig args)))
;   (unadvise 'http-get)
;
; advise MUTATES the global binding, so it is best for REPL / debugging /
; instrumentation. For cross-cutting concerns in library code, prefer a
; parameterize'd hook instead (a make-parameter holding the hook, switched on
; for a dynamic extent) — that composes and is fiber-local. See the language
; reference ("Advice and dynamic hooks") for the production idiom.
(define *advice-originals* (make-hash-table))

; zepo-k17w: build the wrapper for a typed advice. `orig` is the function being
; advised (the value just before this advise, so advice stacks); `fn` is the
; advice function. Types:
;   :before   fn runs before orig, called (fn arg...); its result is ignored
;   :after    orig runs, then (fn result arg...); orig's result is returned
;   :around   fn is called (fn orig arg...) and calls orig itself
;   :override fn replaces orig entirely
(define (%advice-wrapper orig type fn)
  (cond
    ((eq? type ':before)
     (lambda args (apply fn args) (apply orig args)))
    ((eq? type ':after)
     (lambda args (let ((r (apply orig args))) (apply fn (cons r args)) r)))
    ((eq? type ':around)
     (lambda args (apply fn (cons orig args))))
    ((eq? type ':override) fn)
    (else (error "unknown advice type:" type))))

; (advise 'name fn)            — :around (fn is called (fn orig arg...))
; (advise 'name :type fn)      — typed advice (:before/:after/:around/:override)
(define (advise name . rest)
  (let ((type (if (= (length rest) 2) (car rest) ':around))
        (fn   (if (= (length rest) 2) (car (cdr rest)) (car rest))))
    (unless (hash-contains? *advice-originals* name)
      (hash-set! *advice-originals* name (%global-ref name)))
    (let ((current (%global-ref name)))
      (%global-set! name (%advice-wrapper current type fn)))
    name))

(define (unadvise name)
  (when (hash-contains? *advice-originals* name)
    (%global-set! name (hash-get *advice-originals* name))
    (hash-delete! *advice-originals* name))
  name)

(define (advised? name)
  (hash-contains? *advice-originals* name))

; zepo-gz21: structs + single-dispatch generic functions.
;
; A struct value is a vector tagged  #( %struct <type-sym> field... )  — the
; %struct marker makes it distinguishable from a plain vector, and type-of
; (a primitive) returns <type-sym> for it. defstruct generates a constructor,
; a predicate, and one accessor per field.
;
;   (defstruct circle radius)
;   (circle? (make-circle 5))      ; => #t
;   (circle-radius (make-circle 5)) ; => 5
(define (%make-struct type fields)
  (let ((v (make-vector (+ 2 (length fields)) 0)))
    (vector-set! v 0 '%struct)
    (vector-set! v 1 type)
    (let loop ((fs fields) (i 2))
      (if (null? fs) v
          (begin (vector-set! v i (car fs)) (loop (cdr fs) (+ i 1)))))))

(define (%struct-is? x type)
  (and (vector? x)
       (>= (vector-length x) 2)
       (eq? (vector-ref x 0) '%struct)
       (eq? (vector-ref x 1) type)))

(defmacro defstruct (name . fields)
  (let ((mk (string->symbol (string-append "make-" (symbol->string name))))
        (pred (string->symbol (string-append (symbol->string name) "?"))))
    `(begin
       (define (,mk ,@fields) (%make-struct ',name (list ,@fields)))
       (define (,pred x) (%struct-is? x ',name))
       ,@(let loop ((fs fields) (i 2) (acc '()))
           (if (null? fs)
               (reverse acc)
               (loop (cdr fs) (+ i 1)
                     (cons `(define (,(string->symbol
                                       (string-append (symbol->string name) "-"
                                                      (symbol->string (car fs))))
                                     s)
                              (vector-ref s ,i))
                           acc)))))))

; Generic functions. *generics* maps a generic name to a hash-table of
; type-symbol -> method closure. Dispatch is on (type-of (car args)).
(define *generics* (make-hash-table))

(define (%register-generic! name)
  (if (not (hash-contains? *generics* name))
      (hash-set! *generics* name (make-hash-table))))

(define (%add-method! name type method)
  (%register-generic! name)
  (hash-set! (hash-get *generics* name) type method))

(define (%dispatch-generic name args)
  (if (null? args)
      (error "generic called with no arguments:" name)
      (let ((table (hash-get *generics* name)))
        (let ((method (and table (hash-get table (type-of (car args))))))
          (if method
              (apply method args)
              (error "no applicable method for generic"
                     name 'on-type (type-of (car args))))))))

;   (defgeneric area (shape))
;   (defmethod area ((s circle)) (* 3.14159 (circle-radius s) (circle-radius s)))
; args / opts (e.g. :documentation) are accepted for shape but not yet used.
(defmacro defgeneric (name args . opts)
  `(begin
     (%register-generic! ',name)
     (define ,name (lambda %generic-args (%dispatch-generic ',name %generic-args)))))

;   (defmethod NAME ((arg TYPE) more...) body...)  — dispatches on arg's type.
(defmacro defmethod (name spec . body)
  (let ((arg (car (car spec)))      ; the dispatch parameter name
        (type (car (cdr (car spec)))) ; its type symbol
        (rest (cdr spec)))           ; remaining (untyped) params
    `(%add-method! ',name ',type (lambda (,arg ,@rest) ,@body))))

; zepo-g120: default interactive debugger. The REPL installs it via
; (%set-debugger-hook! %default-debugger); it is never called in non-interactive
; runs. It runs at the signal site of an UNHANDLED condition — restarts are
; still live — lists them, and lets the user pick one to invoke (no extra args).
; Returning normally declines, so the condition propagates to the normal error
; report. Restart clauses that need arguments can't be driven from here.
(define (%debugger-list rs i)
  (if (not (null? rs))
      (begin
        (display "  ") (display i) (display ": ") (display (car rs))
        (let ((rep (restart-report (car rs))))
          (if rep (begin (display "  — ") (display rep))))
        (newline)
        (%debugger-list (cdr rs) (+ i 1)))))

; zepo-qqzm: unwind-protect — run CLEANUP after BODY whether BODY returns
; normally or raises. This is the foundation of the with-X resource convention:
;   (let ((r (acquire)))
;     (unwind-protect (use r) (release r)))
; Built on guard, so CLEANUP runs on the error path (then the condition is
; re-raised) and on the normal path. LIMITATION: Zepo has no continuations and
; no VM-level unwind hook, so a restart that transfers control OUT of BODY (see
; restart-case) bypasses CLEANUP. For ordinary acquire/use/release this is right.
;;
;; >>> (unwind-protect 42 'cleanup-ran)
;; => 42
(defmacro unwind-protect (body . cleanup)
  (let ((res (gensym)) (exn (gensym)))
    `(guard (,exn (#t ,@cleanup (raise ,exn)))
       (let ((,res ,body))
         ,@cleanup
         ,res))))

; zepo-qqzm: (with-output-string (p) body...) — bind P to a fresh string output
; port for BODY (write to it with port-display / port-write) and return the
; accumulated string.
;
;;
;; >>> (with-output-string (p) (port-display p "x = ") (port-write p 42))
;; => "x = 42"
(defmacro with-output-string (binding . body)
  (let ((p (car binding)))
    `(let ((,p (open-output-string)))
       ,@body
       (get-output-string ,p))))

; zepo-qqzm: (with-temp-file (path) body...) — create a unique empty temp file,
; bind PATH to it for BODY, and delete it afterward (even if BODY raises).
;;
;; >>> (with-temp-file (p) (file-write-string p "hi") (file-read-string p))
;; => "hi"
(define (%temp-path)
  (string-append "/tmp/zepo-"
                 (number->string (getpid)) "-"
                 (number->string (current-time-ms)) "-"
                 (symbol->string (gensym "t"))))
(defmacro with-temp-file (binding . body)
  (let ((path (car binding)))
    `(let ((,path (%temp-path)))
       (file-write-string ,path "")
       (unwind-protect
         (begin ,@body)
         (file-delete ,path)))))

(define (%default-debugger cond)
  (let ((restarts (compute-restarts)))
    (if (null? restarts)
        cond
        (begin
          (display "Unhandled condition: ") (display cond) (newline)
          (display "Available restarts:") (newline)
          (%debugger-list restarts 0)
          (display "Restart number (blank to abort): ")
          (let ((n (string->number (read-line))))
            (if (and n (>= n 0) (< n (length restarts)))
                (invoke-restart (list-ref restarts n))
                cond))))))

;;; ── R7RS stdlib additions (zepo-7mwa) ──────────────────────────────────────
;; NOTE: pairs are now mutable (zepo-asu1: set-car!/set-cdr!/list-set!). Strings
;; are still immutable, so string-set!/string-fill! (zepo-1meg) and the
;; port-parameter forms with-input-from-string / with-output-to-string
;; (zepo-gwj5) remain tracked separately. open-input-string is a primitive
;; (fmemopen-backed).

; eqv?-based membership / association (eqv? is a primitive).
(define (memv x lst)
  (cond ((null? lst) #f)
        ((eqv? x (car lst)) lst)
        (#t (memv x (cdr lst)))))

(define (assv key lst)
  (cond ((null? lst) #f)
        ((eqv? key (car (car lst))) (car lst))
        (#t (assv key (cdr lst)))))

; (make-list n [fill]) → list of n copies of fill (default #f).
(define (make-list n . rest)
  (let ((fill (if (null? rest) #f (car rest))))
    (let loop ((i n) (acc (quote ())))
      (if (<= i 0) acc (loop (- i 1) (cons fill acc))))))

; (list-copy obj) → a shallow copy of the list; a non-pair (incl. an improper
; tail) is returned as-is, per R7RS.
(define (list-copy lst)
  (if (pair? lst)
      (cons (car lst) (list-copy (cdr lst)))
      lst))

; (list-set! lst k v) — mutate the k-th pair's car in place (zepo-asu1).
(define (list-set! lst k v)
  (set-car! (list-tail lst k) v))

; Identity-based equality over homogeneous arguments.
(define (symbol=? a b . rest)
  (and (eq? a b) (or (null? rest) (apply symbol=? b rest))))

(define (boolean=? a b . rest)
  (and (eq? a b) (or (null? rest) (apply boolean=? b rest))))

; Case-insensitive comparisons.
(define (char-ci=? a b) (char=? (char-downcase a) (char-downcase b)))
(define (string-ci=? a b) (string=? (string-downcase a) (string-downcase b)))

; Exactness. In zepo an exact number is a fixnum; an inexact one is a float.
(define (inexact? x) (float? x))
(define (exact? x) (and (number? x) (not (float? x))))
(define exact inexact->exact)
(define inexact exact->inexact)
(define (exact-integer? x) (and (exact? x) (integer? x)))

; (exact-integer-sqrt n) → (values s r), s = floor(sqrt n), r = n - s*s.
; The loop corrects for floating-point error in either direction.
(define (exact-integer-sqrt n)
  (let loop ((s (exact (floor (sqrt (inexact n))))))
    (cond ((> (* s s) n) (loop (- s 1)))
          ((> (* (+ s 1) (+ s 1)) n) (values s (- n (* s s))))
          (#t (loop (+ s 1))))))

; Truncating / flooring division, each returning (values quotient remainder).
(define (truncate/ n d) (values (quotient n d) (remainder n d)))
(define (floor/ n d)
  (let ((r (modulo n d)))
    (values (quotient (- n r) d) r)))

; String helpers (immutable-safe).
(define (string-copy s . rest)
  (let ((start (if (null? rest) 0 (car rest)))
        (end   (if (or (null? rest) (null? (cdr rest)))
                   (string-length s)
                   (car (cdr rest)))))
    (substring s start end)))

(define (string-map f . strs)
  (list->string (apply map f (map string->list strs))))

(define (string-for-each f . strs)
  (apply for-each f (map string->list strs)))

(define (string->vector s) (list->vector (string->list s)))
(define (vector->string v) (list->string (vector->list v)))

;;; ── R7RS special forms as macros (zepo-qaxw) ───────────────────────────────
;; case, do, delay/force, let-values/let*-values, define-values, case-lambda,
;; and dynamic-wind. (cond => is handled in the AST builder.) These sit after
;; guard/gensym/cond/vector ops/call-with-values and the 7mwa additions, all of
;; which they use.

; (case key ((d ...) body...) ... (else body...)) — also supports => clauses.
(defmacro case (key . clauses)
  (let ((k (gensym)))
    `(let ((,k ,key))
       (cond
         ,@(map (lambda (clause)
                  (let ((datums (car clause))
                        (body (cdr clause)))
                    (let ((test (if (eq? datums 'else) 'else `(memv ,k ',datums))))
                      (if (and (pair? body) (eq? (car body) '=>))
                          `(,test (,(cadr body) ,k))
                          `(,test ,@body)))))
                clauses)))))

; (do ((var init step) ...) (test result...) command...) — iteration.
(defmacro do (specs test-and-result . commands)
  (let ((loop (gensym))
        (vars  (map car specs))
        (inits (map cadr specs))
        (steps (map (lambda (s) (if (pair? (cddr s)) (caddr s) (car s))) specs))
        (test   (car test-and-result))
        (result (cdr test-and-result)))
    `(let ,loop ,(map list vars inits)
       (if ,test
           ,(if (null? result) #f `(begin ,@result))
           (begin ,@commands (,loop ,@steps))))))

; Promises. A promise is a tagged, mutable 3-slot vector: #(%promise forced? x).
(define (promise? x)
  (and (vector? x) (= (vector-length x) 3) (eq? (vector-ref x 0) '%promise)))
(define (make-promise v) (vector '%promise #t v))
(defmacro delay (expr) `(vector '%promise #f (lambda () ,expr)))
(define (force p)
  (if (promise? p)
      (if (vector-ref p 1)
          (vector-ref p 2)
          (let ((v ((vector-ref p 2))))
            (if (vector-ref p 1)                 ; forcing may have forced it
                (vector-ref p 2)
                (begin (vector-set! p 1 #t) (vector-set! p 2 v) v))))
      p))

; (let-values (((a b) expr) ...) body) / let*-values. Nested call-with-values;
; both expand sequentially (identical for the common single-binding case).
(defmacro let-values (bindings . body)
  (if (null? bindings)
      `(begin ,@body)
      (let ((b (car bindings)))
        `(call-with-values
           (lambda () ,(cadr b))
           (lambda ,(car b)
             (let-values ,(cdr bindings) ,@body))))))
(defmacro let*-values (bindings . body)
  `(let-values ,bindings ,@body))

; (define-values (a b ...) expr) — bind each name to a value of expr.
(defmacro define-values (formals expr)
  (let ((tmp (gensym)))
    `(begin
       (define ,tmp (call-with-values (lambda () ,expr) list))
       ,@(let loop ((fs formals) (i 0) (acc '()))
           (if (null? fs)
               (reverse acc)
               (loop (cdr fs) (+ i 1)
                     (cons `(define ,(car fs) (list-ref ,tmp ,i)) acc)))))))

; (case-lambda (formals body...) ...) — dispatch on argument count.
(define (%formals-fixed-count f)
  (let loop ((f f) (n 0))
    (cond ((null? f) n)
          ((pair? f) (loop (cdr f) (+ n 1)))
          (#t n))))                              ; dotted: n = required count
(define (%formals-variadic? f)
  (let loop ((f f))
    (cond ((null? f) #f)
          ((pair? f) (loop (cdr f)))
          (#t #t))))                             ; ends in a rest symbol
(defmacro case-lambda clauses
  (let ((args (gensym)) (n (gensym)))
    `(lambda ,args
       (let ((,n (length ,args)))
         (cond
           ,@(map (lambda (clause)
                    (let ((formals (car clause))
                          (body (cdr clause)))
                      (if (%formals-variadic? formals)
                          `((>= ,n ,(%formals-fixed-count formals))
                            (apply (lambda ,formals ,@body) ,args))
                          `((= ,n ,(%formals-fixed-count formals))
                            (apply (lambda ,formals ,@body) ,args)))))
                  clauses)
           (else (error "case-lambda: no clause matches arity" ,n)))))))

; (dynamic-wind before thunk after) — after runs on normal AND non-local exit.
; zepo's only non-local exit is raise, so guard fully covers unwind.
(define (dynamic-wind before thunk after)
  (before)
  (guard (e (#t (after) (raise e)))
    (let ((r (thunk)))
      (after)
      r)))
