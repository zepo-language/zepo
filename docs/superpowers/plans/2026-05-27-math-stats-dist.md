# math/stats + math/dist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a statistics module (`math/stats`) and a distributions module (`math/dist`) to Zepo's `math` package.

**Architecture:** Two single-file Zepo modules under `lib/math/`, mirroring the existing `core.lisp`/`linear.lisp`. `math/stats` is deterministic and builds on `math/core` + `math/linear`. `math/dist` adds a seeded `xoshiro128**` PRNG and uniform/normal distributions; it depends only on `math/core`. Bead: **zepo-7uu**. Spec: `docs/superpowers/specs/2026-05-27-math-stats-dist-design.md`.

**Tech Stack:** Zepo Lisp (Scheme-flavored). Tests use the `test` module (`deftest`, `is`, `=check`, `throws`, `run-tests`). Floats compared with `math/core`'s `abs-close?`.

---

## Conventions for every task

- **Bead tag:** each contiguous new block of code gets a single `; zepo-7uu` comment.
- **Loops:** use named-`let` (Zepo does TCO on self-tail calls), never recursion that grows the stack per element.
- **Coercion:** sequence inputs go through `(->vec xs)`; bind length once with `let*`.
- **Run tests (repo lib takes precedence, no reinstall):**
  ```bash
  ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp
  ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp
  ```
- **Float asserts:** `(is (abs-close? GOT WANT 1e-9))` (tighter tol for exact results, `1e-6` for `erf`/`cdf`).
- All work happens on branch `zepo-7uu` (already checked out). Commit after each task.

## File structure

```
lib/math/stats.lisp        NEW  (module math/stats)   — Phase 1
lib/math/dist.lisp         NEW  (module math/dist)    — Phase 2
tests/math/stats_test.lisp NEW
tests/math/dist_test.lisp  NEW
```

`stats.lisp` responsibility: descriptive/paired/transform/regression/summary over numeric vectors. `dist.lisp` responsibility: PRNG + error function + uniform/normal distributions. Each test file imports `test`, `math/core` (for `abs-close?`), and the module under test.

---

# PHASE 1 — `math/stats`

### Task 1: Module skeleton + `->vec` + `sum` + `mean`

**Files:**
- Create: `lib/math/stats.lisp`
- Create: `tests/math/stats_test.lisp`

- [ ] **Step 1: Write the failing test**

`tests/math/stats_test.lisp`:
```lisp
(import test)
(import math/core)   ; abs-close?
(import math/stats)

(deftest stats/sum-and-mean
  (=check (sum (vector 1 2 3 4)) 10)
  (=check (sum '(1 2 3 4)) 10)            ; list coerced
  (is (abs-close? (mean (vector 1 2 3 4)) 2.5 1e-9))
  (is (abs-close? (mean '(2 4 6)) 4.0 1e-9)))

(run-tests)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — module `math/stats` not found.

- [ ] **Step 3: Write minimal implementation**

`lib/math/stats.lisp`:
```lisp
(module math/stats
  (export ->vec sum mean)

  (import math/core)    ; square, abs-close? (used later)
  (import math/linear)  ; solve, matvec, mat (used by ols)

  ;; zepo-7uu: canonical input is a vector; accept a list too.
  (define (->vec xs) (if (vector? xs) xs (list->vector xs)))

  (define (sum xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (let loop ((i 0) (acc 0))
        (if (= i n) acc (loop (+ i 1) (+ acc (vector-ref v i)))))))

  (define (mean xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "mean: empty sequence"))
      (/ (sum v) n))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — `stats/sum-and-mean`. Summary: 1 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): module skeleton + ->vec, sum, mean (zepo-7uu)"
```

---

### Task 2: Variance family — `variance`/`stdev` (sample) + `pvariance`/`pstdev` (population)

**Files:**
- Modify: `lib/math/stats.lisp` (add to `export` + body)
- Modify: `tests/math/stats_test.lisp`

- [ ] **Step 1: Write the failing test** (add before `(run-tests)`)

```lisp
(deftest stats/variance-stdev
  ;; sample variance of (vector 2 4 4 4 5 5 7 9) = 4.571428571...
  (is (abs-close? (variance (vector 2 4 4 4 5 5 7 9)) 4.5714285714 1e-9))
  (is (abs-close? (stdev    (vector 2 4 4 4 5 5 7 9)) 2.1380899353 1e-9))
  ;; population variance of same data = 4.0, pstdev = 2.0
  (is (abs-close? (pvariance (vector 2 4 4 4 5 5 7 9)) 4.0 1e-9))
  (is (abs-close? (pstdev    (vector 2 4 4 4 5 5 7 9)) 2.0 1e-9)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — `variance` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `variance stdev pvariance pstdev` to the `(export …)` list. Add to the body:
```lisp
  ;; zepo-7uu: two-pass sum of squared deviations from the mean.
  (define (ss xs)
    (let* ((v (->vec xs)) (n (vector-length v)) (m (mean v)))
      (let loop ((i 0) (acc 0))
        (if (= i n) acc
            (loop (+ i 1) (+ acc (square (- (vector-ref v i) m))))))))

  (define (pvariance xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "pvariance: empty sequence"))
      (/ (ss v) n)))

  (define (variance xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (< n 2) (error "variance: needs >= 2 values"))
      (/ (ss v) (- n 1))))

  (define (pstdev xs) (sqrt (pvariance xs)))
  (define (stdev  xs) (sqrt (variance  xs)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): sample + population variance/stdev (zepo-7uu)"
```

---

### Task 3: Order statistics — `median`, `quantile`, `percentile`, `span`, `iqr`, `mode`

**Files:**
- Modify: `lib/math/stats.lisp`
- Modify: `tests/math/stats_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest stats/order-stats
  (is (abs-close? (median (vector 1 2 3 4))   2.5 1e-9))
  (is (abs-close? (median (vector 1 2 3 4 5)) 3.0 1e-9))
  (is (abs-close? (quantile (vector 1 2 3 4) 0.5)  2.5 1e-9))
  (is (abs-close? (quantile (vector 1 2 3 4) 0.0)  1.0 1e-9))
  (is (abs-close? (quantile (vector 1 2 3 4) 1.0)  4.0 1e-9))
  ;; type-7: q=0.25 of 1..4 -> 1 + 0.75*(0.25*3 mod) = 1.75
  (is (abs-close? (quantile (vector 1 2 3 4) 0.25) 1.75 1e-9))
  (is (abs-close? (percentile (vector 1 2 3 4) 50) 2.5 1e-9))
  (is (abs-close? (span (vector 3 1 4 1 5)) 4.0 1e-9))
  (is (abs-close? (iqr  (vector 1 2 3 4 5 6 7 8)) 3.5 1e-9))
  (=check (mode (vector 1 2 2 3 3 3 4)) 3)
  (=check (mode (vector 4 4 1 1)) 1))            ; tie -> smallest
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — `median` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `median quantile percentile span iqr mode` to `(export …)`. Add to body:
```lisp
  ;; zepo-7uu: sorted copy as a vector (sort works on lists).
  (define (sorted-vec xs) (list->vector (sort (vector->list (->vec xs)) <)))

  ;; type-7 quantile with linear interpolation (numpy/R default).
  (define (quantile xs q)
    (if (or (< q 0) (> q 1)) (error "quantile: q must be in [0,1]"))
    (let* ((s (sorted-vec xs)) (n (vector-length s)))
      (if (= n 0) (error "quantile: empty sequence"))
      (if (= n 1) (vector-ref s 0)
          (let* ((h  (* (- n 1) q))
                 (lo (floor h))
                 (frac (- h lo))
                 (i (inexact->exact lo)))
            (if (>= i (- n 1)) (vector-ref s (- n 1))
                (+ (vector-ref s i)
                   (* frac (- (vector-ref s (+ i 1)) (vector-ref s i)))))))))

  (define (percentile xs p) (quantile xs (/ p 100)))
  (define (median xs)       (quantile xs 0.5))
  (define (iqr xs)          (- (quantile xs 0.75) (quantile xs 0.25)))

  (define (span xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "span: empty sequence"))
      (let loop ((i 1) (lo (vector-ref v 0)) (hi (vector-ref v 0)))
        (if (= i n) (- hi lo)
            (let ((x (vector-ref v i)))
              (loop (+ i 1) (if (< x lo) x lo) (if (> x hi) x hi)))))))

  ;; mode: most frequent value; smallest value on a tie (operates on sorted run-lengths).
  (define (mode xs)
    (let* ((s (sorted-vec xs)) (n (vector-length s)))
      (if (= n 0) (error "mode: empty sequence"))
      (let loop ((i 1)
                 (cur (vector-ref s 0)) (cur-cnt 1)
                 (best (vector-ref s 0)) (best-cnt 1))
        (if (= i n) best
            (let ((x (vector-ref s i)))
              (if (= x cur)
                  (let ((c (+ cur-cnt 1)))
                    (if (> c best-cnt)
                        (loop (+ i 1) cur c x c)
                        (loop (+ i 1) cur c best best-cnt)))
                  (loop (+ i 1) x 1 best best-cnt)))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): median, quantile, percentile, span, iqr, mode (zepo-7uu)"
```

---

### Task 4: Paired stats — `covariance`/`pcovariance` + `correlation`

**Files:**
- Modify: `lib/math/stats.lisp`
- Modify: `tests/math/stats_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest stats/paired
  ;; perfectly correlated y = 2x + 1
  (is (abs-close? (correlation (vector 1 2 3 4) (vector 3 5 7 9)) 1.0 1e-9))
  (is (abs-close? (correlation (vector 1 2 3 4) (vector 9 7 5 3)) -1.0 1e-9))
  ;; sample covariance of x=1..4, y=2,4,5,4 : mean_x=2.5,mean_y=3.75
  ;; sum dev products = (-1.5)(-1.75)+(-.5)(.25)+(.5)(1.25)+(1.5)(.25)=3.0 ; /(4-1)=1.0
  (is (abs-close? (covariance (vector 1 2 3 4) (vector 2 4 5 4)) 1.0 1e-9))
  (is (abs-close? (pcovariance (vector 1 2 3 4) (vector 2 4 5 4)) 0.75 1e-9)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — `correlation` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `covariance pcovariance correlation` to `(export …)`. Add to body:
```lisp
  ;; zepo-7uu: sum of products of deviations (two-pass).
  (define (sp xs ys)
    (let* ((vx (->vec xs)) (vy (->vec ys)) (n (vector-length vx)))
      (if (not (= n (vector-length vy)))
          (error "covariance: sequences differ in length"))
      (let ((mx (mean vx)) (my (mean vy)))
        (let loop ((i 0) (acc 0))
          (if (= i n) acc
              (loop (+ i 1)
                    (+ acc (* (- (vector-ref vx i) mx)
                              (- (vector-ref vy i) my)))))))) )

  (define (pcovariance xs ys)
    (let ((n (vector-length (->vec xs))))
      (if (= n 0) (error "pcovariance: empty sequence"))
      (/ (sp xs ys) n)))

  (define (covariance xs ys)
    (let ((n (vector-length (->vec xs))))
      (if (< n 2) (error "covariance: needs >= 2 values"))
      (/ (sp xs ys) (- n 1))))

  (define (correlation xs ys)
    (let ((sx (stdev xs)) (sy (stdev ys)))
      (if (or (= sx 0) (= sy 0)) (error "correlation: zero variance"))
      (/ (covariance xs ys) (* sx sy))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): covariance, pcovariance, correlation (zepo-7uu)"
```

---

### Task 5: Transforms — `standardize` + `normalize`

**Files:**
- Modify: `lib/math/stats.lisp`
- Modify: `tests/math/stats_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest stats/transforms
  (let ((z (standardize (vector 1 2 3 4 5))))
    (is (abs-close? (mean z) 0.0 1e-9))
    (is (abs-close? (stdev z) 1.0 1e-9)))
  (let ((u (normalize (vector 10 20 30))))
    (is (abs-close? (vector-ref u 0) 0.0 1e-9))
    (is (abs-close? (vector-ref u 1) 0.5 1e-9))
    (is (abs-close? (vector-ref u 2) 1.0 1e-9))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — `standardize` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `standardize normalize` to `(export …)`. Add to body:
```lisp
  ;; zepo-7uu: z-score each element using the sample stdev.
  (define (standardize xs)
    (let* ((v (->vec xs)) (n (vector-length v)) (m (mean v)) (sd (stdev v)))
      (if (= sd 0) (error "standardize: zero variance"))
      (let ((out (make-vector n 0)))
        (let loop ((i 0))
          (if (= i n) out
              (begin (vector-set! out i (/ (- (vector-ref v i) m) sd))
                     (loop (+ i 1))))))))

  ;; min-max scale into [0,1].
  (define (normalize xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "normalize: empty sequence"))
      (let loop ((i 1) (lo (vector-ref v 0)) (hi (vector-ref v 0)))
        (if (< i n)
            (let ((x (vector-ref v i)))
              (loop (+ i 1) (if (< x lo) x lo) (if (> x hi) x hi)))
            (begin
              (if (= lo hi) (error "normalize: zero range"))
              (let ((out (make-vector n 0)) (rng (- hi lo)))
                (let fill ((j 0))
                  (if (= j n) out
                      (begin (vector-set! out j (/ (- (vector-ref v j) lo) rng))
                             (fill (+ j 1)))))))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): standardize + normalize transforms (zepo-7uu)"
```

---

### Task 6: Simple regression — `linreg`

**Files:**
- Modify: `lib/math/stats.lisp`
- Modify: `tests/math/stats_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest stats/linreg
  (let ((m (linreg (vector 1 2 3 4) (vector 3 5 7 9))))   ; y = 2x + 1 exactly
    (is (abs-close? (hash-get m 'slope 0)     2.0 1e-9))
    (is (abs-close? (hash-get m 'intercept 0) 1.0 1e-9))
    (is (abs-close? (hash-get m 'r2 0)        1.0 1e-9))
    (=check (hash-get m 'n 0) 4)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — `linreg` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `linreg` to `(export …)`. Add to body:
```lisp
  ;; zepo-7uu: ordinary least squares for a single predictor.
  (define (linreg xs ys)
    (let* ((vx (->vec xs)) (vy (->vec ys)) (n (vector-length vx)))
      (if (not (= n (vector-length vy)))
          (error "linreg: sequences differ in length"))
      (if (< n 2) (error "linreg: needs >= 2 points"))
      (let ((mx (mean vx)) (my (mean vy)))
        (let loop ((i 0) (sxy 0) (sxx 0))
          (if (= i n)
              (begin
                (if (= sxx 0) (error "linreg: x has zero variance"))
                (let* ((slope (/ sxy sxx))
                       (intercept (- my (* slope mx)))
                       (r (correlation vx vy)))
                  (let ((m (make-hash-table)))
                    (hash-set! m 'slope slope)
                    (hash-set! m 'intercept intercept)
                    (hash-set! m 'r2 (square r))
                    (hash-set! m 'n n)
                    m)))
              (let ((dx (- (vector-ref vx i) mx))
                    (dy (- (vector-ref vy i) my)))
                (loop (+ i 1) (+ sxy (* dx dy)) (+ sxx (* dx dx)))))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): simple OLS linreg (zepo-7uu)"
```

---

### Task 7: Multivariate regression — `ols`

**Files:**
- Modify: `lib/math/stats.lisp`
- Modify: `tests/math/stats_test.lisp`

Uses `math/linear`'s `mat` (constructor `(mat rows cols v...)`), `mat-ref`, and `solve` (solves `A b = y` for a square `A` matrix and vector `y`). We form the normal-equations system `(XᵀX) b = Xᵀy` directly from `X` (a matrix, rows = observations, cols = features) and `y` (a vector).

- [ ] **Step 1: Write the failing test**

```lisp
(deftest stats/ols
  ;; X columns: [1 (intercept), x] ; y = 1 + 2x exactly -> coeffs (1 2), r2 1
  (let* ((X (rows->mat (list (list 1 1) (list 1 2) (list 1 3) (list 1 4))))
         (y (vector 3 5 7 9))
         (m (ols X y))
         (c (hash-get m 'coeffs #f)))
    (is (abs-close? (vector-ref c 0) 1.0 1e-7))
    (is (abs-close? (vector-ref c 1) 2.0 1e-7))
    (is (abs-close? (hash-get m 'r2 0) 1.0 1e-7))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — `ols` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `ols` to `(export …)`. Add to body:
```lisp
  ;; zepo-7uu: column i of design matrix X as a vector (rows = observations).
  (define (col X i)
    (let* ((r (mat-rows X)) (out (make-vector r 0)))
      (let loop ((k 0))
        (if (= k r) out
            (begin (vector-set! out k (mat-ref X k i)) (loop (+ k 1)))))))

  ;; multivariate OLS via the normal equations (XᵀX) b = Xᵀy, solved with math/linear.
  (define (ols X y)
    (let* ((vy (->vec y))
           (rows (mat-rows X))
           (cols (mat-cols X)))
      (if (not (= rows (vector-length vy)))
          (error "ols: X rows must match y length"))
      ;; build A = XᵀX (cols x cols) and b = Xᵀy (length cols)
      (let ((cvecs (let loop ((j 0) (acc '()))
                     (if (= j cols) (list->vector (reverse acc))
                         (loop (+ j 1) (cons (col X j) acc)))))
            (a-vals (make-vector (* cols cols) 0))
            (b (make-vector cols 0)))
        (let iloop ((i 0))
          (if (< i cols)
              (begin
                (vector-set! b i (dot (vector-ref cvecs i) vy))
                (let jloop ((j 0))
                  (if (< j cols)
                      (begin
                        (vector-set! a-vals (+ (* i cols) j)
                                     (dot (vector-ref cvecs i) (vector-ref cvecs j)))
                        (jloop (+ j 1)))))
                (iloop (+ i 1)))))
        (let* ((A (apply mat cols cols (vector->list a-vals)))
               (coeffs (solve A b))
               (yhat (matvec X coeffs))
               (ybar (mean vy)))
          ;; r2 = 1 - SS_res/SS_tot
          (let loop ((k 0) (ss-res 0) (ss-tot 0))
            (if (= k rows)
                (let ((m (make-hash-table)))
                  (hash-set! m 'coeffs coeffs)
                  (hash-set! m 'r2 (if (= ss-tot 0) 1.0 (- 1.0 (/ ss-res ss-tot))))
                  m)
                (loop (+ k 1)
                      (+ ss-res (square (- (vector-ref vy k) (vector-ref yhat k))))
                      (+ ss-tot (square (- (vector-ref vy k) ybar))))))))))
```

> Note: confirm `math/linear` exports `rows->mat`, `mat`, `mat-ref`, `mat-rows`, `mat-cols`, `dot`, `matvec`, `solve` (it does per `lib/math/linear.lisp`). `mat`'s constructor is `(mat rows cols v...)`; we splice the flat values with `apply`.

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): multivariate ols via normal equations (zepo-7uu)"
```

---

### Task 8: `summary` aggregate

**Files:**
- Modify: `lib/math/stats.lisp`
- Modify: `tests/math/stats_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest stats/summary
  (let ((s (summary (vector 1 2 3 4 5 6 7 8))))
    (=check (hash-get s 'n 0) 8)
    (is (abs-close? (hash-get s 'mean 0)   4.5 1e-9))
    (is (abs-close? (hash-get s 'min 0)    1.0 1e-9))
    (is (abs-close? (hash-get s 'max 0)    8.0 1e-9))
    (is (abs-close? (hash-get s 'median 0) 4.5 1e-9))
    (is (abs-close? (hash-get s 'q1 0)     2.75 1e-9))
    (is (abs-close? (hash-get s 'q3 0)     6.25 1e-9))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: FAIL — `summary` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `summary` to `(export …)`. Add to body:
```lisp
  ;; zepo-7uu: five-number summary plus n, mean, stdev.
  (define (summary xs)
    (let* ((v (->vec xs)) (n (vector-length v)))
      (if (= n 0) (error "summary: empty sequence"))
      (let ((s (sorted-vec v)) (m (make-hash-table)))
        (hash-set! m 'n n)
        (hash-set! m 'mean (mean v))
        (hash-set! m 'stdev (if (< n 2) 0.0 (stdev v)))
        (hash-set! m 'min (vector-ref s 0))
        (hash-set! m 'max (vector-ref s (- n 1)))
        (hash-set! m 'q1 (quantile v 0.25))
        (hash-set! m 'median (quantile v 0.5))
        (hash-set! m 'q3 (quantile v 0.75))
        m)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/math/stats.lisp tests/math/stats_test.lisp
git commit -m "feat(math/stats): summary aggregate (zepo-7uu)"
```

---

### Task 9: Edge-case error tests

**Files:**
- Modify: `tests/math/stats_test.lisp` (tests only — implementation already raises these)

- [ ] **Step 1: Write the test**

```lisp
(deftest stats/errors
  (throws (mean (vector )))
  (throws (variance (vector 5)))               ; n < 2
  (is (abs-close? (pvariance (vector 5)) 0.0 1e-9))  ; population allows n=1
  (throws (correlation (vector 1 1 1) (vector 1 2 3)))     ; zero variance in x
  (throws (quantile (vector 1 2 3) 1.5))             ; q out of range
  (throws (covariance (vector 1 2 3) (vector 1 2)))        ; unequal lengths
  (throws (linreg (vector 1 1 1) (vector 2 4 6))))         ; x zero variance
```

- [ ] **Step 2: Run test to verify it passes** (implementation already raises)

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp`
Expected: PASS — 9 tests pass. If any `throws` fails, the corresponding guard is missing — add it to the named function in `lib/math/stats.lisp` and re-run.

- [ ] **Step 3: Commit**

```bash
git add tests/math/stats_test.lisp
git commit -m "test(math/stats): edge-case error coverage (zepo-7uu)"
```

---

# PHASE 2 — `math/dist`

### Task 10: PRNG core — `make-rng` + `rng-next!` (`xoshiro128**`) + golden test

**Files:**
- Create: `lib/math/dist.lisp`
- Create: `tests/math/dist_test.lisp`

- [ ] **Step 1: Write the failing test**

`tests/math/dist_test.lisp`:
```lisp
(import test)
(import math/core)
(import math/dist)

(deftest dist/rng-determinism
  ;; same seed -> identical streams
  (let ((a (make-rng 42)) (b (make-rng 42)))
    (=check (rng-next! a) (rng-next! b))
    (=check (rng-next! a) (rng-next! b))
    (=check (rng-next! a) (rng-next! b)))
  ;; different seeds -> first draw differs
  (let ((a (make-rng 1)) (b (make-rng 2)))
    (is (not (= (rng-next! a) (rng-next! b)))))
  ;; raw draws are non-negative 32-bit fixnums
  (let ((r (make-rng 7)))
    (let ((x (rng-next! r)))
      (is (>= x 0))
      (is (< x 4294967296)))))

(run-tests)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: FAIL — module `math/dist` not found.

- [ ] **Step 3: Write minimal implementation**

`lib/math/dist.lisp`:
```lisp
(module math/dist
  (export make-rng rng-next!)

  (import math/core)   ; pi, square (used later)

  ;; zepo-7uu: 32-bit helpers. Lanes are kept as non-negative fixnums < 2^32.
  (define mask32 4294967295)            ; #xFFFFFFFF
  (define (m32 x) (bitwise-and x mask32))
  (define (rotl x k)
    (m32 (bitwise-or (m32 (arithmetic-shift x k))
                     (arithmetic-shift x (- k 32)))))

  ;; splitmix32 step — expands a seed into well-mixed 32-bit words.
  (define (splitmix32-next state)        ; returns (cons new-state output)
    (let* ((z0 (m32 (+ state 2654435769)))           ; +0x9E3779B9
           (z1 (m32 (* (bitwise-xor z0 (arithmetic-shift z0 -16)) 569420461))) ; *0x21F0AAAD
           (z2 (m32 (* (bitwise-xor z1 (arithmetic-shift z1 -15)) 1935289751))) ; *0x735A2D97
           (z3 (m32 (bitwise-xor z2 (arithmetic-shift z2 -15)))))
      (cons z0 z3)))

  ;; rng state = a length-4 vector of 32-bit lanes.
  (define (make-rng seed)
    (let ((st (make-vector 4 0)))
      (let loop ((i 0) (s (m32 seed)))
        (if (= i 4)
            (begin
              ;; guard against the all-zero state
              (if (and (= (vector-ref st 0) 0) (= (vector-ref st 1) 0)
                       (= (vector-ref st 2) 0) (= (vector-ref st 3) 0))
                  (vector-set! st 0 1))
              st)
            (let ((p (splitmix32-next s)))
              (vector-set! st i (cdr p))
              (loop (+ i 1) (car p)))))))

  ;; xoshiro128** next 32-bit output; advances state in place.
  (define (rng-next! st)
    (let* ((s0 (vector-ref st 0)) (s1 (vector-ref st 1))
           (s2 (vector-ref st 2)) (s3 (vector-ref st 3))
           (result (m32 (* (rotl (m32 (* s1 5)) 7) 9)))
           (t (m32 (arithmetic-shift s1 9))))
      (let ((n2 (bitwise-xor s2 s0))
            (n3 (bitwise-xor s3 s1)))
        (let ((n1 (bitwise-xor s1 n2))
              (n0 (bitwise-xor s0 n3)))
          (vector-set! st 0 n0)
          (vector-set! st 1 n1)
          (vector-set! st 2 (bitwise-xor n2 t))
          (vector-set! st 3 (rotl n3 11))
          result)))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: PASS — `dist/rng-determinism`.

- [ ] **Step 5: Record golden values, then add a regression test**

Capture the actual first three draws of seed 42 (paste real numbers from a quick run):
```bash
ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo -e '(import math/dist)(define r (make-rng 42))(display (rng-next! r))(newline)(display (rng-next! r))(newline)(display (rng-next! r))(newline)'
```
Add a golden test to `tests/math/dist_test.lisp` (replace `G1 G2 G3` with the printed values):
```lisp
(deftest dist/rng-golden
  (let ((r (make-rng 42)))
    (=check (rng-next! r) G1)
    (=check (rng-next! r) G2)
    (=check (rng-next! r) G3)))
```
Run again; expect PASS. (If `zepo -e` is unavailable, write a 4-line scratch `.lisp` printing the draws and run it directly.)

- [ ] **Step 6: Commit**

```bash
git add lib/math/dist.lisp tests/math/dist_test.lisp
git commit -m "feat(math/dist): xoshiro128** seeded PRNG + golden test (zepo-7uu)"
```

---

### Task 11: `rng-float!` + `rng-int!`

**Files:**
- Modify: `lib/math/dist.lisp`
- Modify: `tests/math/dist_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest dist/rng-float-int
  (let ((r (make-rng 99)))
    (let loop ((i 0))
      (if (< i 1000)
          (let ((f (rng-float! r)) (k (rng-int! r 5 10)))
            (is (>= f 0.0)) (is (< f 1.0))
            (is (>= k 5)) (is (< k 10))
            (loop (+ i 1))))))
  ;; degenerate / error cases
  (throws (rng-int! (make-rng 1) 5 5))     ; empty half-open range
  (throws (rng-int! (make-rng 1) 9 2)))    ; hi < lo
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: FAIL — `rng-float!` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `rng-float! rng-int!` to `(export …)`. Add to body:
```lisp
  (define two32 4294967296.0)           ; 2^32 as float

  ;; uniform float in [0,1) at 32-bit precision.
  (define (rng-float! st) (/ (rng-next! st) two32))

  ;; uniform integer in [lo,hi) — rejection sampling to avoid modulo bias.
  (define (rng-int! st lo hi)
    (let ((range (- hi lo)))
      (if (<= range 0) (error "rng-int!: hi must be > lo"))
      (let ((threshold (- 4294967296 (modulo 4294967296 range))))
        (let loop ()
          (let ((x (rng-next! st)))
            (if (< x threshold) (+ lo (modulo x range)) (loop)))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/math/dist.lisp tests/math/dist_test.lisp
git commit -m "feat(math/dist): rng-float! + unbiased rng-int! (zepo-7uu)"
```

---

### Task 12: `erf` + `erfc`

**Files:**
- Modify: `lib/math/dist.lisp`
- Modify: `tests/math/dist_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest dist/erf
  (is (abs-close? (erf 0)  0.0       1e-7))
  (is (abs-close? (erf 1)  0.8427007 1e-6))
  (is (abs-close? (erf -1) -0.8427007 1e-6))   ; oddness
  (is (abs-close? (erf 2)  0.9953222 1e-6))
  (is (abs-close? (erfc 1) (- 1.0 (erf 1)) 1e-9)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: FAIL — `erf` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `erf erfc` to `(export …)`. Add to body (uses primitives `exp`, `abs`):
```lisp
  ;; zepo-7uu: Abramowitz & Stegun 7.1.26 rational approximation, |err| <= 1.5e-7.
  (define (erf x)
    (let* ((ax (abs x))
           (tt (/ 1.0 (+ 1.0 (* 0.3275911 ax))))
           (poly (* tt (+ 0.254829592
                          (* tt (+ -0.284496736
                                   (* tt (+ 1.421413741
                                            (* tt (+ -1.453152027
                                                     (* tt 1.061405429))))))))))
           (y (- 1.0 (* poly (exp (- (* ax ax)))))))
      (if (< x 0) (- y) y)))

  (define (erfc x) (- 1.0 (erf x)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/math/dist.lisp tests/math/dist_test.lisp
git commit -m "feat(math/dist): erf/erfc (A&S 7.1.26) (zepo-7uu)"
```

---

### Task 13: Uniform distribution — `uniform-pdf` / `uniform-cdf` / `uniform-sample!`

**Files:**
- Modify: `lib/math/dist.lisp`
- Modify: `tests/math/dist_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest dist/uniform
  (is (abs-close? (uniform-pdf 5 0 10) 0.1 1e-9))
  (is (abs-close? (uniform-pdf -1 0 10) 0.0 1e-9))
  (is (abs-close? (uniform-cdf 2.5 0 10) 0.25 1e-9))
  (is (abs-close? (uniform-cdf -5 0 10) 0.0 1e-9))
  (is (abs-close? (uniform-cdf 99 0 10) 1.0 1e-9))
  (let ((r (make-rng 3)))
    (let loop ((i 0))
      (if (< i 1000)
          (let ((x (uniform-sample! r 2 8)))
            (is (>= x 2)) (is (< x 8)) (loop (+ i 1))))))
  (throws (uniform-pdf 5 10 0)))           ; b < a
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: FAIL — `uniform-pdf` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `uniform-pdf uniform-cdf uniform-sample!` to `(export …)`. Add to body:
```lisp
  (define (uniform-pdf x a b)
    (if (< b a) (error "uniform-pdf: b must be >= a"))
    (if (or (< x a) (> x b)) 0.0 (/ 1.0 (- b a))))

  (define (uniform-cdf x a b)
    (if (< b a) (error "uniform-cdf: b must be >= a"))
    (cond ((< x a) 0.0)
          ((> x b) 1.0)
          (else (/ (- x a) (- b a)))))

  (define (uniform-sample! st a b)
    (if (< b a) (error "uniform-sample!: b must be >= a"))
    (+ a (* (- b a) (rng-float! st))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/math/dist.lisp tests/math/dist_test.lisp
git commit -m "feat(math/dist): uniform pdf/cdf/sample! (zepo-7uu)"
```

---

### Task 14: Normal distribution — `normal-pdf` / `normal-cdf` / `normal-sample!`

**Files:**
- Modify: `lib/math/dist.lisp`
- Modify: `tests/math/dist_test.lisp`

- [ ] **Step 1: Write the failing test**

```lisp
(deftest dist/normal
  (is (abs-close? (normal-pdf 0 0 1) 0.3989422804 1e-9))   ; 1/sqrt(2pi)
  (is (abs-close? (normal-cdf 0 0 1) 0.5 1e-9))
  (is (abs-close? (normal-cdf 1 0 1) 0.8413447 1e-6))
  (is (abs-close? (normal-cdf -1 0 1) 0.1586553 1e-6))
  (throws (normal-pdf 0 0 0))             ; sigma <= 0
  (throws (normal-sample! (make-rng 1) 0 -1)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: FAIL — `normal-pdf` unbound.

- [ ] **Step 3: Write minimal implementation**

Add `normal-pdf normal-cdf normal-sample!` to `(export …)`. Add to body (uses `pi` from `math/core`, primitives `exp`, `sqrt`, `ln`, `cos`):
```lisp
  (define sqrt2 1.4142135623730951)

  (define (normal-pdf x mu sigma)
    (if (<= sigma 0) (error "normal-pdf: sigma must be > 0"))
    (let ((z (/ (- x mu) sigma)))
      (/ (exp (* -0.5 (square z))) (* sigma (sqrt (* 2.0 pi))))))

  (define (normal-cdf x mu sigma)
    (if (<= sigma 0) (error "normal-cdf: sigma must be > 0"))
    (* 0.5 (+ 1.0 (erf (/ (- x mu) (* sigma sqrt2))))))

  ;; Box-Muller: one normal per two uniforms (no spare-value caching).
  (define (normal-sample! st mu sigma)
    (if (<= sigma 0) (error "normal-sample!: sigma must be > 0"))
    (let ((u1 (rng-float! st)) (u2 (rng-float! st)))
      ;; guard ln(0): rng-float! is [0,1); nudge a zero u1 to a tiny positive
      (let ((uu (if (= u1 0.0) 1e-12 u1)))
        (+ mu (* sigma (* (sqrt (* -2.0 (ln uu))) (cos (* 2.0 pi u2))))))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/math/dist.lisp tests/math/dist_test.lisp
git commit -m "feat(math/dist): normal pdf/cdf/sample! (zepo-7uu)"
```

---

### Task 15: Sampling-sanity tests (seeded, deterministic)

**Files:**
- Modify: `tests/math/dist_test.lisp` (add `(import math/stats)` at top for test-time stats)

- [ ] **Step 1: Add the import and test**

At the top of `tests/math/dist_test.lisp`, add after the existing imports:
```lisp
(import math/stats)   ; test-time only: validate sample moments
```
Add the test:
```lisp
(deftest dist/sampling-moments
  ;; 10k normal(5,2) draws -> sample mean ~5, sample stdev ~2
  (let ((r (make-rng 12345)) (n 10000))
    (let ((xs (make-vector n 0)))
      (let loop ((i 0))
        (if (< i n) (begin (vector-set! xs i (normal-sample! r 5 2)) (loop (+ i 1)))))
      (is (abs-close? (mean xs)  5.0 0.1))
      (is (abs-close? (stdev xs) 2.0 0.1))))
  ;; 10k uniform(0,10) draws -> mean ~5
  (let ((r (make-rng 678)) (n 10000))
    (let ((xs (make-vector n 0)))
      (let loop ((i 0))
        (if (< i n) (begin (vector-set! xs i (uniform-sample! r 0 10)) (loop (+ i 1)))))
      (is (abs-close? (mean xs) 5.0 0.15)))))
```

- [ ] **Step 2: Run test to verify it passes**

Run: `ZEPO_PATH="$PWD/lib" /Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp`
Expected: PASS — all `dist/*` tests. (Tolerances are generous and the seed is fixed, so this is deterministic; if it fails, the sampler or RNG has a real bug.)

- [ ] **Step 3: Commit**

```bash
git add tests/math/dist_test.lisp
git commit -m "test(math/dist): seeded sampling moment checks (zepo-7uu)"
```

---

### Task 16: Install, full-suite regression, docs note

**Files:**
- Modify: `docs/reference.md` (add a short `math/stats` + `math/dist` subsection near the existing math docs)

- [ ] **Step 1: Reinstall libs so the installed binary ships the new modules**

Run: `zig build install-global`
Expected: exit 0.

- [ ] **Step 2: Run both new suites against the installed binary (no ZEPO_PATH) to confirm install**

Run:
```bash
/Users/leslierussell/.local/bin/zepo test tests/math/stats_test.lisp
/Users/leslierussell/.local/bin/zepo test tests/math/dist_test.lisp
```
Expected: both `ok`, 0 failed.

- [ ] **Step 3: Full Zig suite regression (ensure nothing else broke)**

Run: `zig build test`
Expected: exit 0.

- [ ] **Step 4: Add a reference-docs subsection**

In `docs/reference.md`, near the existing math/vector sections, add a concise subsection listing the new modules and their exported functions (signatures only, mirroring the style of the existing entries). Keep it factual; no examples beyond one per module.

- [ ] **Step 5: Commit**

```bash
git add docs/reference.md
git commit -m "docs(reference): document math/stats + math/dist (zepo-7uu)"
```

---

## Final integration (after all tasks)

- [ ] Merge to master and close the bead:
```bash
git checkout master && git merge --no-ff zepo-7uu -m "merge zepo-7uu: math/stats + math/dist"
git branch -d zepo-7uu
bd close zepo-7uu
git push
```

---

## Self-review notes (author)

- **Spec coverage:** every `math/stats` export (sum, mean, variance/stdev, pvariance/pstdev, median, quantile, percentile, span, iqr, mode, covariance/pcovariance, correlation, standardize, normalize, linreg, ols, summary) and every `math/dist` export (make-rng, rng-next!, rng-float!, rng-int!, erf, erfc, uniform-{pdf,cdf,sample!}, normal-{pdf,cdf,sample!}) has an implementing task. Edge-case policy → Task 9 + per-function `throws` tests. Testing strategy → Tasks 9, 10(golden), 15(moments).
- **Naming consistency:** `->vec`, `ss`, `sp`, `sorted-vec`, `col` are internal helpers defined before first use; `m32`/`rotl`/`splitmix32-next` defined before `make-rng`/`rng-next!`. Hash keys are symbols (`'slope`, `'coeffs`, `'q1`, …) consistently.
- **Assumptions to verify during execution (fail loudly if wrong):** `math/linear` exports `rows->mat`, `mat`, `mat-ref`, `mat-rows`, `mat-cols`, `dot`, `matvec`, `solve`; `(mat rows cols v...)` takes a flat value list; primitives `exp`, `ln`, `cos`, `sqrt`, `abs`, `floor`, `inexact->exact`, `modulo`, `sort`, `list->vector`, `vector->list` exist (all confirmed during design). If `mat`'s arity differs, build the matrix with `rows->mat` from a list of rows instead.
```
