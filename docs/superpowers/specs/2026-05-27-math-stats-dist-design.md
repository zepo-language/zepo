# Design: `math/stats` + `math/dist`

**Bead:** zepo-7uu
**Date:** 2026-05-27
**Status:** Approved (brainstorm), pending spec review

## Summary

Two new modules in the existing `math` package that bring a statistics and
probability layer to Zepo, building on the current `math/core` (constants,
scalar helpers) and `math/linear` (vectors, matrices, `solve`, `det`):

- **`math/stats`** — deterministic descriptive statistics, paired statistics,
  transforms, and linear regression.
- **`math/dist`** — a seeded `xoshiro128**` PRNG plus uniform and normal
  distributions (pdf / cdf / sampling) and the error function.

`math/stats` is deterministic and ships first (Phase 1). `math/dist` adds the
stochastic layer (Phase 2). `math/dist` does **not** depend on `math/stats` at
runtime.

## Goals / Non-goals

**Goals**
- A conventional, ergonomic stats API usable for AI/ML/data work.
- Fully deterministic descriptive/regression layer with explicit error
  semantics (no silent NaN).
- Reproducible randomness via explicit generator objects.

**Non-goals (explicitly out of scope for v1, noted for a future spec)**
- Inverse CDF / quantile functions (probit / inverse-erf).
- Distributions beyond uniform and normal (t, χ², binomial, Poisson, …).
- A global/implicit RNG — all randomness flows through an explicit `rng`.
- Tensor / n-dimensional arrays (separate effort).

## Module layout & wiring

```
lib/math/
  core.lisp      (existing)
  linear.lisp    (existing)
  stats.lisp     NEW  (module math/stats)
  dist.lisp      NEW  (module math/dist)
  numeric/       (existing)
```

- `(module math/stats …)` imports `math/core` (e.g. `square`, `almost-eq?`)
  and `math/linear` (`solve`, `matvec`, matrix accessors) for multivariate OLS.
- `(module math/dist …)` imports `math/core` (constants, `square`) and defines
  its own internal `erf`. Every `dist` function takes scalars or an `rng`, so it
  needs no sequence coercion and is fully independent of `math/stats`.
- Imported as `(import math/stats)` / `(import math/dist)`, consistent with
  `(import math/core)`.

**Conventions**
- Canonical sequence input is a Scheme **vector** of numbers. Lists are accepted
  via an internal `(->vec xs)` (list|vector → vector), so both
  `(mean #(1 2 3))` and `(mean '(1 2 3))` work.
- Variance/stdev/covariance default to the **sample** estimator (`/(n-1)`,
  Bessel), matching Python's `statistics` and R; population variants are
  `p`-prefixed (`/n`).
- Aggregate / model results are returned as **hashtables** (the package's
  workhorse aggregate; portable across worker channels), not a record type.
- Variance family uses a **two-pass** computation (mean, then sum of squared
  deviations) — stable and clear.

## `math/stats` API

### Descriptive (one sequence)
```
(sum xs) (mean xs)
(variance xs)  (stdev xs)      ; sample, /(n-1)
(pvariance xs) (pstdev xs)     ; population, /n
(median xs)
(quantile xs q)                ; q ∈ [0,1], linear interpolation (type-7; numpy/R default)
(percentile xs p)              ; = (quantile xs (/ p 100))
(mode xs)                      ; most frequent value; smallest value on tie
(span xs)                      ; max − min   (named `span` to avoid clashing with stdlib `range`)
(iqr xs)                       ; (quantile xs 0.75) − (quantile xs 0.25)
```

### Paired (two sequences, equal length)
```
(covariance xs ys)  (pcovariance xs ys)   ; sample / population
(correlation xs ys)                       ; Pearson r (estimator-independent: n-1 vs n cancels)
```

### Transforms (return a new vector)
```
(standardize xs)   ; z-scores using sample stdev (mean → 0, sd → 1)
(normalize xs)     ; min-max scaled into [0,1]
```

### Regression
```
(linreg xs ys) → hashtable { 'slope 'intercept 'r2 'n }     ; simple OLS
(ols X y)      → hashtable { 'coeffs 'r2 }                  ; multivariate
                 ; X = math/linear matrix (rows = observations, cols = features),
                 ; y = vector; coefficients via normal equations XᵀX b = Xᵀy
                 ; solved with math/linear `solve`. 'coeffs is a vector.
```

### Aggregate
```
(summary xs) → hashtable { 'n 'mean 'stdev 'min 'q1 'median 'q3 'max }
```

### Edge-case policy (explicit errors, never silent NaN)
- Empty input → `(error "<fn>: empty sequence")`.
- `variance`/`stdev`/`covariance`/`correlation` with `n < 2`
  → `(error "<fn>: needs >= 2 values")`. Population variants allow `n >= 1`.
- `quantile` with `q ∉ [0,1]` → error.
- `correlation` / `standardize` when a stdev is 0 → `(error "<fn>: zero variance")`.
- Paired functions with unequal lengths → error.
- Non-numeric elements → arithmetic raises `TypeError` (propagated, not caught).

## `math/dist` API

### RNG — `xoshiro128**`, explicit generators only
Four 32-bit state lanes held in a mutable length-4 **vector**, advanced in place.
Seeded by expanding a single integer seed through a `splitmix32` step into the
four lanes (a zero seed still yields a non-zero state). All arithmetic stays
within 63-bit fixnum range via 32-bit masking (`bitwise-and #xFFFFFFFF`).

```
(make-rng seed)        → rng            ; deterministic from integer seed
(rng-next! rng)        → fixnum         ; raw 32-bit draw, advances state
(rng-float! rng)       → float in [0,1) ; one 32-bit draw / 2^32 (32-bit precision)
(rng-int! rng lo hi)   → int in [lo,hi) ; half-open; rejection sampling (no modulo bias)
```

### Error function (exported helpers)
```
(erf x)   ; Abramowitz–Stegun 7.1.26 approximation, |err| ≲ 1.5e-7
(erfc x)  ; 1 − erf x
```

### Uniform on [a,b]
```
(uniform-pdf x a b)        ; 1/(b−a) inside [a,b], else 0
(uniform-cdf x a b)        ; clamped to [0,1]
(uniform-sample! rng a b)  ; a + (b−a)·(rng-float! rng)
```

### Normal(μ, σ)
```
(normal-pdf x mu sigma)
(normal-cdf x mu sigma)        ; via erf
(normal-sample! rng mu sigma)  ; Box–Muller: z = sqrt(−2 ln u1)·cos(2π u2);
                               ; returns one value (stateless — no spare caching)
```

### Edge cases
- `sigma <= 0` → error.
- `uniform-*` with `b < a` → error.
- `uniform-pdf` returns 0 outside `[a,b]`; `uniform-cdf` clamps to `[0,1]`.

### Concurrency
The RNG is an ordinary heap object passed explicitly. Each **worker** has its
own heap/module instance, so generators never cross threads. Within one VM,
fibers are cooperative (no mid-operation preemption), so passing one `rng`
between fibers is safe; reproducible per-fiber/worker work should use its own
`make-rng`.

## Testing

Files: `tests/math/stats_test.lisp`, `tests/math/dist_test.lisp`. Run with
`zepo test`. Uses `deftest` + `assert` / `assert-equal` / `assert-error`, with
`(run-tests)` at the end of each file. Float comparisons use `math/core`'s
`abs-close?` / `almost-eq?`.

**`stats` (deterministic, cross-checked against Python `statistics`/`numpy`):**
- `(mean #(1 2 3 4))` → 2.5; sample `(variance #(2 4 4 4 5 5 7 9))` → 4.5714285…;
  `(median #(1 2 3 4))` → 2.5; `(quantile #(1 2 3 4) 0.5)` → 2.5;
  `(correlation …)` on a known pair.
- `linreg` on a known dataset → expected slope/intercept/r² (perfect line → r²=1).
- `ols` on a small design matrix → recovers planted coefficients.
- `assert-error`: empty input; `variance` of one element; zero-variance
  `correlation`; `quantile` with q = 1.5; unequal-length pairs.

**`dist`:**
- `erf`: `erf(0)=0`, `erf(1)≈0.8427007`, oddness `erf(−x)=−erf(x)` (tol ~1e-6);
  `erfc(x)=1−erf(x)`.
- `normal-cdf`: at μ → 0.5; μ±σ → 0.8413 / 0.1587; uniform pdf/cdf boundaries.
- RNG determinism / golden: `(make-rng 42)` then a few `rng-next!` asserted
  against fixed golden values (regression guard); same seed → identical streams;
  different seeds → differ.
- Sampling sanity (seeded → deterministic): draw N=10000 from
  `normal-sample!` / `uniform-sample!`, then (test-time only) use `math/stats`
  to assert sample mean/stdev are within tolerance of the parameters;
  `rng-int!` stays within `[lo,hi)` and covers both ends.

## Build phases

1. **Phase 1 — `math/stats`** (deterministic). Module + `stats_test.lisp`.
   Ships and is useful standalone.
2. **Phase 2 — `math/dist`** (RNG + distributions). Module + `dist_test.lisp`.
   `dist`'s sampling tests may use `math/stats` at test time only.
