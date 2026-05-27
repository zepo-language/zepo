# math/tensor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Lisp n-dimensional array module `math/tensor` for Zepo (construction, indexing, reshape/transpose/slice, elementwise math, reductions, 2-D matmul).

**Architecture:** One self-contained Zepo module, `lib/math/tensor.lisp`. A tensor is a hashtable `{ 'shape : vector of dims (each >=1), 'data : flat row-major Scheme vector of length ∏shape }`. All shape-changing ops copy (reshape is the one exception — it shares the buffer). Elementwise ops support scalar + identical-shape only (no broadcasting). No runtime changes. Bead: **zepo-py2**. Spec: `docs/superpowers/specs/2026-05-27-math-tensor-design.md`.

**Tech Stack:** Zepo Lisp. Tests use the `test` module (`deftest`, `is`, `=check`, `throws`, `run-tests`); float comparisons via `math/core`'s `abs-close?`.

---

## Conventions for every task

- **Bead tag:** each contiguous new block of code gets a single `; zepo-py2` comment.
- **`#(...)` vector literals are NOT readable** in Zepo (reader throws `UnexpectedChar`). Always build vectors with `(vector …)` / `(make-vector …)` / `(list->vector …)`.
- **Loops:** use named-`let` (Zepo does TCO on self-tail calls).
- **Integer `/`** returns a float on non-exact division (`(/ 10 4)` → 2.5); even division of integers stays integer (`(/ 6 3)` → 2). Both are numerically fine for tests via `abs-close?` / `=check`.
- **Run the test suite** (repo `lib/` takes precedence, no reinstall):
  ```bash
  ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp
  ```
  Pass looks like `Summary: N passed, 0 failed` then `ok`.
- **Do NOT run `zig build`** — this is pure Lisp.
- All work happens on branch `zepo-py2` (already checked out). Commit after each task.

## File structure

```
lib/math/tensor.lisp        NEW  (module math/tensor)
tests/math/tensor_test.lisp NEW
```

`tensor.lisp` holds the whole module: internal helpers (offset math, shape utilities) plus the public API. It is self-contained — no `(import …)` needed (arithmetic, vector, list, and hashtable ops are all built in). The test file imports `test`, `math/core` (for `abs-close?`), and `math/tensor`.

---

### Task 1: Skeleton, internal helpers, constructor + introspection

**Files:**
- Create: `lib/math/tensor.lisp`
- Create: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test** — `tests/math/tensor_test.lisp`:
```lisp
(import test)
(import math/core)     ; abs-close?
(import math/tensor)

(deftest tensor/construct-introspect
  (let ((t (tensor (list 2 3) (list 1 2 3 4 5 6))))
    (is (tensor? t))
    (=check (shape t) (list 2 3))
    (=check (rank t) 2)
    (=check (size t) 6))
  ;; shape/data accept vectors too
  (let ((t (tensor (vector 4) (vector 9 9 9 9))))
    (=check (shape t) (list 4))
    (=check (rank t) 1))
  (is (not (tensor? 5)))
  (is (not (tensor? (list 1 2)))))

(run-tests)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — module `math/tensor` not found.

- [ ] **Step 3: Write minimal implementation** — `lib/math/tensor.lisp`:
```lisp
(module math/tensor
  (export tensor tensor? shape rank size)

  ;; ── internal helpers (zepo-py2) ──────────────────────────────────────────
  (define (->vec xs) (if (vector? xs) xs (list->vector xs)))

  (define (prod-vec v)
    (let ((n (vector-length v)))
      (let loop ((i 0) (acc 1))
        (if (= i n) acc (loop (+ i 1) (* acc (vector-ref v i)))))))

  ;; build a tensor hashtable from a shape vector + data vector (no validation)
  (define (make-tensor shape-vec data-vec)
    (let ((t (make-hash-table)))
      (hash-set! t 'shape shape-vec)
      (hash-set! t 'data data-vec)
      t))

  (define (tensor-shape-vec t) (hash-get t 'shape #f))
  (define (tensor-data t)      (hash-get t 'data #f))

  ;; row-major flat offset from a list of indices and a shape vector (Horner).
  (define (flat-offset shape-vec idxs)
    (let ((n (vector-length shape-vec)))
      (let loop ((i 0) (rest idxs) (off 0))
        (if (= i n) off
            (loop (+ i 1) (cdr rest)
                  (+ (* off (vector-ref shape-vec i)) (car rest)))))))

  ;; inverse of flat-offset: flat index -> list of per-axis indices.
  (define (unflatten shape-vec flat)
    (let loop ((i (- (vector-length shape-vec) 1)) (rem flat) (acc (quote ())))
      (if (< i 0) acc
          (let ((d (vector-ref shape-vec i)))
            (loop (- i 1) (quotient rem d) (cons (modulo rem d) acc))))))

  ;; ── construction + introspection (zepo-py2) ──────────────────────────────
  (define (tensor shape data)
    (let ((sv (->vec shape)) (dv (->vec data)))
      (let ((r (vector-length sv)))
        (if (= r 0) (error "tensor: shape must have at least one dimension"))
        (let dloop ((i 0))
          (if (< i r)
              (let ((d (vector-ref sv i)))
                (if (or (not (integer? d)) (< d 1))
                    (error "tensor: every dimension must be an integer >= 1"))
                (dloop (+ i 1)))))
        (if (not (= (vector-length dv) (prod-vec sv)))
            (error "tensor: data length does not match product of shape"))
        (let nloop ((i 0))
          (if (< i (vector-length dv))
              (begin
                (if (not (number? (vector-ref dv i)))
                    (error "tensor: data must be numeric"))
                (nloop (+ i 1)))))
        (make-tensor sv dv))))

  (define (tensor? x)
    (and (hash-table? x)
         (vector? (hash-get x 'shape #f))
         (vector? (hash-get x 'data #f))))

  (define (shape t) (vector->list (tensor-shape-vec t)))
  (define (rank t)  (vector-length (tensor-shape-vec t)))
  (define (size t)  (vector-length (tensor-data t))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS — 1 test, `Summary: 1 passed, 0 failed`.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): skeleton, helpers, tensor/tensor?/shape/rank/size (zepo-py2)"
```

---

### Task 2: `zeros`, `ones`, `full`, `arange`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test** (add before `(run-tests)`):
```lisp
(deftest tensor/factories
  (=check (shape (zeros (list 2 2))) (list 2 2))
  (=check (size (zeros (list 2 2))) 4)
  (let ((z (zeros (list 3)))) (is (abs-close? (tref z 0) 0 1e-9)))
  (let ((o (ones (list 3))))  (is (abs-close? (tref o 2) 1 1e-9)))
  (let ((f (full (list 2 2) 7))) (is (abs-close? (tref f 1 1) 7 1e-9)))
  (let ((a (arange 5)))
    (=check (shape a) (list 5))
    (=check (tref a 0) 0)
    (=check (tref a 4) 4))
  (throws (arange 0)))
```
> Note: this test uses `tref` (Task 4). If running tasks strictly in order, temporarily check values with `(tensor->nested …)` instead, or run this test after Task 4. Easiest: implement Task 2's functions now, and let this `deftest` start passing once Task 4 lands. To keep the suite green per-task, place the value-checking asserts that need `tref` after Task 4; the `shape`/`size`/`throws` asserts pass now.

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `zeros` unbound.

- [ ] **Step 3: Write minimal implementation** — add `zeros ones full arange` to `(export …)` and add to body:
```lisp
  ;; zepo-py2: factory constructors.
  (define (full shape v)
    (let ((sv (->vec shape)))
      (let dloop ((i 0))
        (if (< i (vector-length sv))
            (let ((d (vector-ref sv i)))
              (if (or (not (integer? d)) (< d 1))
                  (error "full: every dimension must be an integer >= 1"))
              (dloop (+ i 1)))))
      (make-tensor sv (make-vector (prod-vec sv) v))))

  (define (zeros shape) (full shape 0))
  (define (ones  shape) (full shape 1))

  (define (arange n)
    (if (or (not (integer? n)) (< n 1)) (error "arange: n must be an integer >= 1"))
    (let ((dv (make-vector n 0)))
      (let loop ((i 0))
        (if (= i n) (make-tensor (vector n) dv)
            (begin (vector-set! dv i i) (loop (+ i 1)))))))
```

- [ ] **Step 4: Run test to verify it passes** (after Task 4 lands, or with the value asserts deferred)

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): zeros, ones, full, arange (zepo-py2)"
```

---

### Task 3: `from-nested` + `tensor->nested`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/nested
  (let ((t (from-nested (list (list 1 2 3) (list 4 5 6)))))
    (=check (shape t) (list 2 3))
    (=check (tensor->nested t) (list (list 1 2 3) (list 4 5 6))))
  (let ((t (from-nested (list 1 2 3 4))))    ; 1-D
    (=check (shape t) (list 4))
    (=check (tensor->nested t) (list 1 2 3 4)))
  (throws (from-nested (list (list 1 2) (list 3))))   ; ragged
  (throws (from-nested (quote ()))))                   ; empty
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `from-nested` unbound.

- [ ] **Step 3: Write minimal implementation** — add `from-nested tensor->nested` to `(export …)` and add:
```lisp
  ;; zepo-py2: infer shape from the first element down; flatten row-major.
  (define (nested-shape n)
    (if (pair? n) (cons (length n) (nested-shape (car n))) (quote ())))

  (define (flatten-nested n)
    (if (pair? n)
        (apply append (map flatten-nested n))
        (list n)))

  (define (from-nested nested)
    (if (not (pair? nested)) (error "from-nested: need a non-empty nested list"))
    (let* ((shape-list (nested-shape nested))
           (sv (list->vector shape-list))
           (flat (flatten-nested nested)))
      ;; rectangularity: flattened length must equal product of inferred shape
      (if (not (= (length flat) (prod-vec sv)))
          (error "from-nested: ragged or inconsistent nested list"))
      (tensor sv flat)))

  ;; rebuild nested lists from shape + flat data using offset arithmetic.
  (define (tensor->nested t)
    (let ((sv (tensor-shape-vec t)) (dv (tensor-data t)))
      (let build ((axis 0) (off 0) (block (vector-length dv)))
        (if (= axis (vector-length sv))
            (vector-ref dv off)
            (let* ((dim (vector-ref sv axis)) (sub (quotient block dim)))
              (let loop ((k 0) (acc (quote ())))
                (if (= k dim) (reverse acc)
                    (loop (+ k 1)
                          (cons (build (+ axis 1) (+ off (* k sub)) sub) acc)))))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): from-nested + tensor->nested (zepo-py2)"
```

---

### Task 4: `tref` / `tset!`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/index
  (let ((t (from-nested (list (list 1 2 3) (list 4 5 6)))))
    (=check (tref t 0 0) 1)
    (=check (tref t 1 2) 6)
    (tset! t 99 0 1)
    (=check (tref t 0 1) 99)
    (throws (tref t 0))        ; too few indices (rank 2)
    (throws (tref t 0 5))      ; out of bounds
    (throws (tref t -1 0))     ; negative index
    (throws (tref t 2 0))))    ; out of bounds
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `tref` unbound.

- [ ] **Step 3: Write minimal implementation** — add `tref tset!` to `(export …)` and add:
```lisp
  ;; zepo-py2: validate index list against the shape, return the flat offset.
  (define (check-index shape-vec idxs)
    (let ((r (vector-length shape-vec)))
      (if (not (= (length idxs) r))
          (error "tensor index: wrong number of indices for rank"))
      (let loop ((i 0) (rest idxs))
        (if (< i r)
            (let ((k (car rest)) (d (vector-ref shape-vec i)))
              (if (or (not (integer? k)) (< k 0) (>= k d))
                  (error "tensor index: out of bounds"))
              (loop (+ i 1) (cdr rest)))))
      (flat-offset shape-vec idxs)))

  (define (tref t . idxs)
    (vector-ref (tensor-data t) (check-index (tensor-shape-vec t) idxs)))

  (define (tset! t val . idxs)
    (vector-set! (tensor-data t) (check-index (tensor-shape-vec t) idxs) val))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS. (Task 2's value-checking asserts now pass too.)

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): tref + tset! with bounds checks (zepo-py2)"
```

---

### Task 5: `reshape`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/reshape
  (let* ((a (arange 6))                 ; 0..5, shape (6)
         (b (reshape a (list 2 3))))
    (=check (shape b) (list 2 3))
    (=check (tref b 0 0) 0)
    (=check (tref b 1 2) 5)
    (let ((c (reshape b (list 3 2))))
      (=check (shape c) (list 3 2))
      (=check (tref c 2 1) 5)))
  (throws (reshape (arange 6) (list 2 2))))   ; size mismatch (4 != 6)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `reshape` unbound.

- [ ] **Step 3: Write minimal implementation** — add `reshape` to `(export …)` and add:
```lisp
  ;; zepo-py2: same total size; SHARES the data buffer (row-major unchanged).
  (define (reshape t shape)
    (let ((sv (->vec shape)))
      (let dloop ((i 0))
        (if (< i (vector-length sv))
            (let ((d (vector-ref sv i)))
              (if (or (not (integer? d)) (< d 1))
                  (error "reshape: every dimension must be an integer >= 1"))
              (dloop (+ i 1)))))
      (if (not (= (prod-vec sv) (size t)))
          (error "reshape: new shape size does not match element count"))
      (make-tensor sv (tensor-data t))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): reshape (shared buffer) (zepo-py2)"
```

---

### Task 6: `transpose`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/transpose
  (let* ((a (from-nested (list (list 1 2 3) (list 4 5 6))))   ; 2x3
         (b (transpose a)))                                    ; 3x2
    (=check (shape b) (list 3 2))
    (=check (tensor->nested b) (list (list 1 4) (list 2 5) (list 3 6))))
  (let ((a (from-nested (list (list 1 2) (list 3 4)))))
    (is (t-equal? (transpose (transpose a)) a))))   ; uses t-equal? (Task 8); see note
```
> Note: the double-transpose assert uses `t-equal?` from Task 8. If running strictly in order, replace it with `(=check (tensor->nested (transpose (transpose a))) (list (list 1 2) (list 3 4)))` for now, or land it after Task 8.

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `transpose` unbound.

- [ ] **Step 3: Write minimal implementation** — add `transpose` to `(export …)` and add:
```lisp
  ;; zepo-py2: reverse all axes; copy with remapped indices.
  (define (reverse-vec v) (list->vector (reverse (vector->list v))))

  (define (transpose t)
    (let* ((sv (tensor-shape-vec t))
           (out-sv (reverse-vec sv))
           (dv (tensor-data t))
           (n (vector-length dv))
           (out (make-vector n 0)))
      (let loop ((flat 0))
        (if (= flat n) (make-tensor out-sv out)
            (let* ((idx (unflatten sv flat))
                   (oidx (reverse idx))
                   (ooff (flat-offset out-sv oidx)))
              (vector-set! out ooff (vector-ref dv flat))
              (loop (+ flat 1)))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): transpose (reverse axes) (zepo-py2)"
```

---

### Task 7: `slice`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/slice
  (let* ((a (from-nested (list (list 1 2 3 4)        ; 3x4
                               (list 5 6 7 8)
                               (list 9 10 11 12))))
         (b (slice a 1 1 3)))                          ; cols [1,3) -> 3x2
    (=check (shape b) (list 3 2))
    (=check (tensor->nested b) (list (list 2 3) (list 6 7) (list 10 11))))
  (let ((a (from-nested (list (list 1 2) (list 3 4) (list 5 6)))))  ; 3x2
    (=check (tensor->nested (slice a 0 1 3)) (list (list 3 4) (list 5 6))))  ; rows [1,3)
  (throws (slice (arange 5) 1 0 2))     ; axis out of range
  (throws (slice (arange 5) 0 2 2))     ; start not < end
  (throws (slice (arange 5) 0 0 9)))    ; end > dim
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `slice` unbound.

- [ ] **Step 3: Write minimal implementation** — add `slice` to `(export …)` and add:
```lisp
  ;; zepo-py2: copy the sub-tensor along one axis over [start,end).
  (define (bump-axis idx axis start)
    (let loop ((i 0) (rest idx) (acc (quote ())))
      (if (null? rest) (reverse acc)
          (loop (+ i 1) (cdr rest)
                (cons (if (= i axis) (+ (car rest) start) (car rest)) acc)))))

  (define (slice t axis start end)
    (let* ((sv (tensor-shape-vec t)) (r (vector-length sv)))
      (if (or (not (integer? axis)) (< axis 0) (>= axis r))
          (error "slice: axis out of range"))
      (let ((dim (vector-ref sv axis)))
        (if (not (and (integer? start) (integer? end)
                      (<= 0 start) (< start end) (<= end dim)))
            (error "slice: bad range (need 0 <= start < end <= dim)"))
        (let ((out-sv (vector-copy sv)))
          (vector-set! out-sv axis (- end start))
          (let* ((n (prod-vec out-sv)) (dv (tensor-data t)) (out (make-vector n 0)))
            (let loop ((flat 0))
              (if (= flat n) (make-tensor out-sv out)
                  (let* ((oidx (unflatten out-sv flat))
                         (iidx (bump-axis oidx axis start))
                         (ioff (flat-offset sv iidx)))
                    (vector-set! out flat (vector-ref dv ioff))
                    (loop (+ flat 1))))))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): slice along one axis (zepo-py2)"
```

---

### Task 8: Elementwise — `t-zip`, `t+`/`t-`/`t*`/`t/`, `t-map`, `t-equal?`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/elementwise
  (let ((a (from-nested (list (list 1 2) (list 3 4))))
        (b (from-nested (list (list 10 20) (list 30 40)))))
    (=check (tensor->nested (t+ a b)) (list (list 11 22) (list 33 44)))
    (=check (tensor->nested (t* a 2)) (list (list 2 4) (list 6 8)))
    (=check (tensor->nested (t* 2 a)) (list (list 2 4) (list 6 8)))
    (=check (tensor->nested (t- b a)) (list (list 9 18) (list 27 36)))
    (=check (tensor->nested (t-map (lambda (x) (* x x)) a)) (list (list 1 4) (list 9 16)))
    (=check (tensor->nested (t-zip max a b)) (list (list 10 20) (list 30 40)))
    (is (t-equal? a a))
    (is (not (t-equal? a b))))
  (throws (t+ (from-nested (list 1 2 3)) (from-nested (list 1 2)))))  ; shape mismatch
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `t+` unbound.

- [ ] **Step 3: Write minimal implementation** — add `t+ t- t* t/ t-map t-zip t-equal?` to `(export …)` and add:
```lisp
  ;; zepo-py2: elementwise. Both tensors (identical shape) OR tensor + scalar.
  (define (same-shape? a b)
    (equal? (vector->list (tensor-shape-vec a)) (vector->list (tensor-shape-vec b))))

  (define (t-zip f a b)
    (cond
      ((and (tensor? a) (tensor? b))
       (if (not (same-shape? a b)) (error "t-zip: shape mismatch"))
       (let* ((da (tensor-data a)) (db (tensor-data b)) (n (vector-length da))
              (out (make-vector n 0)))
         (let loop ((i 0))
           (if (= i n) (make-tensor (vector-copy (tensor-shape-vec a)) out)
               (begin (vector-set! out i (f (vector-ref da i) (vector-ref db i)))
                      (loop (+ i 1)))))))
      ((and (tensor? a) (number? b))
       (let* ((da (tensor-data a)) (n (vector-length da)) (out (make-vector n 0)))
         (let loop ((i 0))
           (if (= i n) (make-tensor (vector-copy (tensor-shape-vec a)) out)
               (begin (vector-set! out i (f (vector-ref da i) b)) (loop (+ i 1)))))))
      ((and (number? a) (tensor? b))
       (let* ((db (tensor-data b)) (n (vector-length db)) (out (make-vector n 0)))
         (let loop ((i 0))
           (if (= i n) (make-tensor (vector-copy (tensor-shape-vec b)) out)
               (begin (vector-set! out i (f a (vector-ref db i))) (loop (+ i 1)))))))
      (else (error "t-zip: operands must be tensors or numbers"))))

  (define (t+ a b) (t-zip + a b))
  (define (t- a b) (t-zip - a b))
  (define (t* a b) (t-zip * a b))
  (define (t/ a b) (t-zip / a b))

  (define (t-map f t)
    (let* ((d (tensor-data t)) (n (vector-length d)) (out (make-vector n 0)))
      (let loop ((i 0))
        (if (= i n) (make-tensor (vector-copy (tensor-shape-vec t)) out)
            (begin (vector-set! out i (f (vector-ref d i))) (loop (+ i 1)))))))

  (define (t-equal? a b)
    (and (tensor? a) (tensor? b)
         (same-shape? a b)
         (equal? (vector->list (tensor-data a)) (vector->list (tensor-data b)))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): elementwise t-zip/t+/t-/t*/t-divide, t-map, t-equal? (zepo-py2)"
```

---

### Task 9: Reductions — `t-sum`, `t-mean`, `t-max`, `t-min` (whole + along axis)

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/reductions
  (let ((a (from-nested (list (list 1 2 3) (list 4 5 6)))))   ; 2x3
    ;; whole-tensor
    (=check (t-sum a) 21)
    (is (abs-close? (t-mean a) 3.5 1e-9))
    (=check (t-max a) 6)
    (=check (t-min a) 1)
    ;; along axis 0 -> length-3 (column sums)
    (=check (tensor->nested (t-sum a 0)) (list 5 7 9))
    ;; along axis 1 -> length-2 (row sums)
    (=check (tensor->nested (t-sum a 1)) (list 6 15))
    (=check (tensor->nested (t-max a 0)) (list 4 5 6))
    (is (abs-close? (car (tensor->nested (t-mean a 1))) 2.0 1e-9)))
  ;; reducing a 1-D tensor's only axis -> scalar
  (=check (t-sum (from-nested (list 1 2 3 4)) 0) 10)
  (throws (t-sum (arange 3) 1)))    ; axis out of range
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `t-sum` unbound.

- [ ] **Step 3: Write minimal implementation** — add `t-sum t-mean t-max t-min` to `(export …)` and add:
```lisp
  ;; zepo-py2: shape vector with one axis removed; index list with k inserted.
  (define (remove-index v axis)
    (let ((n (vector-length v)) (out (make-vector (- (vector-length v) 1) 0)))
      (let loop ((i 0) (j 0))
        (if (= i n) out
            (if (= i axis) (loop (+ i 1) j)
                (begin (vector-set! out j (vector-ref v i)) (loop (+ i 1) (+ j 1))))))))

  ;; splice k into the output-index list at position axis -> input-index list.
  (define (splice-index oidx axis k)
    (let loop ((i 0) (rest oidx) (acc (quote ())))
      (cond ((= i axis)
             ;; insert k here, then continue copying the rest at shifted positions
             (let cont ((r rest) (a (cons k acc)))
               (if (null? r) (reverse a) (cont (cdr r) (cons (car r) a)))))
            ((null? rest) (reverse acc))   ; axis == rank-of-output (append at end)
            (else (loop (+ i 1) (cdr rest) (cons (car rest) acc))))))

  ;; combine with a sentinel so max/min can use the first value as the seed.
  (define (seeded f) (lambda (acc x) (if (null? acc) x (f acc x))))

  (define (reduce-axis combine seed final t axis)
    (let* ((sv (tensor-shape-vec t)) (r (vector-length sv)))
      (if (or (not (integer? axis)) (< axis 0) (>= axis r))
          (error "reduce: axis out of range"))
      (let ((dim (vector-ref sv axis)) (dv (tensor-data t)))
        (if (= r 1)
            ;; 1-D reduction collapses to a scalar
            (let loop ((k 0) (acc seed))
              (if (= k dim) (final acc dim) (loop (+ k 1) (combine acc (vector-ref dv k)))))
            (let* ((out-sv (remove-index sv axis)) (n (prod-vec out-sv)) (out (make-vector n 0)))
              (let ocell ((flat 0))
                (if (= flat n) (make-tensor out-sv out)
                    (let ((oidx (unflatten out-sv flat)))
                      (let rloop ((k 0) (acc seed))
                        (if (= k dim)
                            (begin (vector-set! out flat (final acc dim)) (ocell (+ flat 1)))
                            (let ((ioff (flat-offset sv (splice-index oidx axis k))))
                              (rloop (+ k 1) (combine acc (vector-ref dv ioff))))))))))))))

  ;; whole-tensor folds.
  (define (fold-all combine seed t)
    (let* ((d (tensor-data t)) (n (vector-length d)))
      (let loop ((i 0) (acc seed)) (if (= i n) acc (loop (+ i 1) (combine acc (vector-ref d i)))))))

  (define (t-sum t . rest)
    (if (null? rest) (fold-all + 0 t)
        (reduce-axis + 0 (lambda (a c) a) t (car rest))))

  (define (t-mean t . rest)
    (if (null? rest) (/ (fold-all + 0 t) (size t))
        (reduce-axis + 0 (lambda (a c) (/ a c)) t (car rest))))

  (define (t-max t . rest)
    (if (null? rest) (fold-all (seeded max) (quote ()) t)
        (reduce-axis (seeded max) (quote ()) (lambda (a c) a) t (car rest))))

  (define (t-min t . rest)
    (if (null? rest) (fold-all (seeded min) (quote ()) t)
        (reduce-axis (seeded min) (quote ()) (lambda (a c) a) t (car rest))))
```
- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS. (If `splice-index` mis-handles the axis-at-end case, verify with a 3-D example: reducing axis 2 of a (2,2,2) tensor.)

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): reductions (whole + along axis) (zepo-py2)"
```

---

### Task 10: `matmul`

**Files:**
- Modify: `lib/math/tensor.lisp`
- Modify: `tests/math/tensor_test.lisp`

- [ ] **Step 1: Write the failing test**:
```lisp
(deftest tensor/matmul
  (let ((a (from-nested (list (list 1 2 3) (list 4 5 6))))      ; 2x3
        (b (from-nested (list (list 7 8) (list 9 10) (list 11 12)))))  ; 3x2
    ;; [[1*7+2*9+3*11, 1*8+2*10+3*12],[4*7+5*9+6*11, 4*8+5*10+6*12]]
    (=check (tensor->nested (matmul a b)) (list (list 58 64) (list 139 154))))
  (let ((id (from-nested (list (list 1 0) (list 0 1))))
        (m  (from-nested (list (list 5 6) (list 7 8)))))
    (is (t-equal? (matmul id m) m)))
  (throws (matmul (from-nested (list (list 1 2) (list 3 4)))      ; 2x2
                  (from-nested (list (list 1 2 3)))))             ; 1x3 (inner 2 != 1)
  (throws (matmul (arange 4) (arange 4))))   ; not rank 2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: FAIL — `matmul` unbound.

- [ ] **Step 3: Write minimal implementation** — add `matmul` to `(export …)` and add:
```lisp
  ;; zepo-py2: 2-D matrix multiply (m k)·(k n) -> (m n).
  (define (matmul a b)
    (let ((sa (tensor-shape-vec a)) (sb (tensor-shape-vec b)))
      (if (or (not (= (vector-length sa) 2)) (not (= (vector-length sb) 2)))
          (error "matmul: both operands must be rank 2"))
      (let ((m (vector-ref sa 0)) (k (vector-ref sa 1))
            (k2 (vector-ref sb 0)) (n (vector-ref sb 1)))
        (if (not (= k k2)) (error "matmul: inner dimensions must match"))
        (let ((da (tensor-data a)) (db (tensor-data b)) (out (make-vector (* m n) 0)))
          (let iloop ((i 0))
            (if (= i m) (make-tensor (list->vector (list m n)) out)
                (begin
                  (let jloop ((j 0))
                    (if (< j n)
                        (begin
                          (let ((s (let ploop ((p 0) (acc 0))
                                     (if (= p k) acc
                                         (ploop (+ p 1)
                                                (+ acc (* (vector-ref da (+ (* i k) p))
                                                          (vector-ref db (+ (* p n) j)))))))))
                            (vector-set! out (+ (* i n) j) s))
                          (jloop (+ j 1)))))
                  (iloop (+ i 1)))))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add lib/math/tensor.lisp tests/math/tensor_test.lisp
git commit -m "feat(math/tensor): 2-D matmul (zepo-py2)"
```

---

### Task 11: Consolidated error / edge-case tests

**Files:**
- Modify: `tests/math/tensor_test.lisp` (tests only)

- [ ] **Step 1: Write the test** (most guards already exist; this is a focused sweep):
```lisp
(deftest tensor/errors
  (throws (tensor (list 2 2) (list 1 2 3)))     ; data length != product
  (throws (tensor (list 0 2) (list)))           ; dim < 1
  (throws (tensor (list 2) (list "a" "b")))     ; non-numeric data
  (throws (arange 0))                           ; n < 1
  (throws (from-nested (list (list 1 2) (list 3))))  ; ragged
  (throws (reshape (arange 6) (list 4)))        ; size mismatch
  (throws (slice (arange 5) 0 3 1))             ; start >= end
  (throws (t* (from-nested (list 1 2)) (from-nested (list 1 2 3))))  ; shape mismatch
  (throws (matmul (arange 3) (arange 3))))      ; not rank 2
```

- [ ] **Step 2: Run test to verify it passes** (implementation already raises these)

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: PASS. If any `throws` fails, add the missing guard to the named function and re-run.

- [ ] **Step 3: Commit**
```bash
git add tests/math/tensor_test.lisp
git commit -m "test(math/tensor): consolidated error coverage (zepo-py2)"
```

---

### Task 12: Install, full regression, reference docs

**Files:**
- Modify: `docs/reference.md` (add a `math/tensor` subsection in the Math Libraries section, before `## Zig FFI`)

- [ ] **Step 1: Install libs so the installed binary ships the module**

Run: `zig build install-global`
Expected: exit 0.

- [ ] **Step 2: Run the suite against the installed binary (no ZEPO_PATH)**

Run: `/Users/leslierussell/.local/bin/zepo test tests/math/tensor_test.lisp`
Expected: `ok`, 0 failed.

- [ ] **Step 3: Full Zig regression (ensure nothing else broke)**

Run: `zig build test` and confirm exit code 0. (Some pre-existing negative-test stderr lines are normal; the exit code is authoritative.)

- [ ] **Step 4: Add a reference-docs subsection.** In `docs/reference.md`, in the `## Math Libraries` section just before `## Zig FFI`, add:
````markdown
### math/tensor

Pure-Lisp n-dimensional arrays (row-major) for data shaping and small linear algebra. A tensor is a `{shape, data}` hashtable; all dims are ≥ 1.

Exports: `tensor` (shape + flat data), `zeros`, `ones`, `full`, `arange`, `from-nested`; `tensor?`, `shape` (→ list), `rank`, `size`, `tensor->nested`; `tref`/`tset!` (multi-index get/set); `reshape` (shares buffer), `transpose` (reverse axes), `slice` (one axis, `[start,end)`); `t+`/`t-`/`t*`/`t/` (elementwise, identical-shape or tensor+scalar), `t-map`, `t-zip`, `t-equal?`; `t-sum`/`t-mean`/`t-max`/`t-min` (whole-tensor, or along an `axis`); `matmul` (2-D). No broadcasting, no strided views; shape mismatches and out-of-range indices/axes raise errors.

```scheme
(import math/tensor)
(define a (from-nested (list (list 1 2 3) (list 4 5 6))))   ; 2x3
(shape (transpose a))            ; => (3 2)
(tensor->nested (t* a 10))       ; => ((10 20 30) (40 50 60))
(t-sum a 0)                      ; => tensor (5 7 9)  (column sums)
(tensor->nested (matmul a (transpose a)))  ; => ((14 32) (32 77))
```
````

- [ ] **Step 5: Commit**
```bash
git add docs/reference.md
git commit -m "docs(reference): document math/tensor (zepo-py2)"
```

---

## Final integration (after all tasks)

```bash
git checkout master && git merge --no-ff zepo-py2 -m "merge zepo-py2: math/tensor pure-Lisp ndarray"
git branch -d zepo-py2
bd close zepo-py2
git push
```

---

## Self-review notes (author)

- **Spec coverage:** construction (`tensor`/`zeros`/`ones`/`full`/`arange`/`from-nested` → Tasks 1-3), introspection (`tensor?`/`shape`/`rank`/`size`/`tensor->nested` → Tasks 1,3), indexing (`tref`/`tset!` → Task 4), shape ops (`reshape`/`transpose`/`slice` → Tasks 5-7), elementwise (`t+`/`t-`/`t*`/`t/`/`t-map`/`t-zip`/`t-equal?` → Task 8), reductions whole+axis (Task 9), `matmul` (Task 10), error policy (Task 11 + per-function guards), docs (Task 12). All spec sections are covered.
- **Naming consistency:** helpers `->vec`, `prod-vec`, `make-tensor`, `tensor-shape-vec`, `tensor-data`, `flat-offset`, `unflatten`, `reverse-vec`, `bump-axis`, `remove-index`, `splice-index`, `seeded`, `fold-all`, `reduce-axis`, `same-shape?` are each defined before first use. Public names match the spec exactly.
- **Known wrinkle to watch (Task 9):** `splice-index` must handle the case where `axis` equals the output rank (i.e. inserting at the end). The provided code handles `(= i axis)` mid-list and the `axis == length` append case via the `((null? rest) …)` branch only when axis < length; for axis at the very end the `(= i axis)` triggers when `rest` is `()`, inserting `k` then copying nothing — correct. Verify with a 3-D reduction over the last axis (test includes a 2×3 axis-1 case; add a (2,2,2) axis-2 check if unsure).
- **Assumptions verified during design:** `number?`, `integer?`, `quotient`, `modulo`, `vector-copy`, `apply`, `reverse`, `length`, `hash-table?`, 2-arg `max`/`min`, `list->vector`/`vector->list` all exist. `#(...)` literals are NOT readable — all test data uses `(list …)` / `from-nested`.
```
