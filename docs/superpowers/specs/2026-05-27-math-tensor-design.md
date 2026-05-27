# Design: `math/tensor`

**Bead:** zepo-py2
**Date:** 2026-05-27
**Status:** Approved (brainstorm), pending spec review

## Summary

A pure-Lisp n-dimensional array (ndarray) module for Zepo's `math` package,
for data shaping and small/medium linear algebra: reshape, transpose, slice,
elementwise math, reductions, and 2-D matrix multiply. No runtime changes — the
data buffer is a flat row-major Scheme vector, exactly the storage `math/linear`
already uses for matrices.

## Goals / Non-goals

**Goals**
- A clean, conventional ndarray API usable for data wrangling and prototyping.
- Correctness and explicit error semantics (never silent NaN), fully unit-tested.
- Stays channel-portable for workers (a hashtable of a vector of numbers).

**Non-goals (out of scope for v1; noted for a future spec)**
- Contiguous unboxed-`f64` storage / a Zig `f64vector` runtime primitive. v1 uses
  boxed Scheme numbers; if throughput ever matters, swap storage behind this API.
- Strided **views**: reshape/transpose/slice are copy-based (reshape is the lone
  exception — it shares the buffer; see below). No stride bookkeeping.
- **Broadcasting** beyond scalar: elementwise ops require identical shapes (or a
  tensor + a scalar). No size-1 stretching or rank alignment.
- Rank-0 scalars and 0-length dimensions: all dims must be ≥ 1.
- A dtype system: tensors hold ordinary Scheme numbers; ops use generic arithmetic.
- 1-D `dot` / arbitrary axis permutations / multi-axis slicing in one call.

## Representation

```
tensor = hashtable {
  'shape : vector of dims  (non-empty; each dim an integer >= 1)
  'data  : flat row-major Scheme vector, length = (product of shape)
}
```

- Shape is stored as a **vector** internally; an internal `tensor-shape-vec`
  accessor avoids repeated conversions. `(shape t)` returns a **list** for callers.
- Row-major (C-order) layout. The flat offset of index `(i_0 … i_{k-1})` for shape
  `(d_0 … d_{k-1})` is the standard mixed-radix value
  `((…(i_0·d_1 + i_1)·d_2 + i_2)…)·d_{k-1} + i_{k-1}`.
- This matches the existing "portable hashtable + vector" pattern, so a tensor
  crosses a worker channel like any other portable value.

## API

### Construction
```
(tensor shape data)   ; shape list|vector, data list|vector (flattened);
                      ; validates: dims integer >=1, len(data) = product(shape),
                      ; elements numeric
(zeros shape)         ; all 0
(ones shape)          ; all 1
(full shape v)        ; all v
(arange n)            ; 1-D tensor shape (n), data 0..n-1 ; requires n >= 1
(from-nested nested)  ; infer shape from rectangular nested lists, flatten
                      ; row-major; errors on ragged or empty structure
```

### Introspection
```
(tensor? x)        ; #t for a well-formed tensor hashtable, else #f
(shape t)          ; list of dims
(rank t)           ; integer (number of dims)
(size t)           ; integer (product of shape)
(tensor->nested t) ; nested lists mirroring shape (inverse of from-nested)
```

### Indexing (row-major)
```
(tref t i j ...)        ; element at the multi-index; #indices must equal rank
(tset! t val i j ...)   ; set element in place (vector-set! on 'data)
```
Indices must be integers with `0 <= idx_k < dim_k`. Negative indices are
forbidden (consistent with Zepo's other indexing primitives). Wrong index count
(≠ rank) or out-of-bounds → error.

### Shape ops
```
(reshape t shape)      ; product must equal (size t); returns a tensor SHARING
                       ; the same 'data buffer (row-major layout unchanged).
                       ; Caveat: tset! through a reshaped tensor aliases the
                       ; original — the one place data is shared.
(transpose t)          ; reverse ALL axes (rank-2 = ordinary matrix transpose);
                       ; copies into a new buffer with remapped indices
(slice t axis start end); copy the sub-tensor along one axis over [start,end);
                       ; result keeps the same rank with that axis shortened.
                       ; Requires 0<=axis<rank and 0<=start<end<=dim.
```

### Elementwise (always returns a NEW tensor; never mutates)
```
(t+ a b) (t- a b) (t* a b) (t/ a b)
```
- tensor ⊕ tensor: shapes must be `equal?`, else error (message shows both shapes).
- tensor ⊕ scalar or scalar ⊕ tensor: the scalar applies to every element
  (`(t* a 2)` and `(t* 2 a)` both valid; operand order matters for `t-`/`t/`).
```
(t-map f t)     ; new tensor, f applied to each element
(t-zip f a b)   ; new tensor, f applied pairwise; same shape-match/scalar rules.
                ; The four arithmetic ops are thin wrappers over t-zip.
(t-equal? a b)  ; #t iff same shape and all elements equal?
```
A "scalar" operand is any value that is a number rather than a tensor.

### Reductions
```
(t-sum  t [axis])   (t-mean t [axis])   (t-max t [axis])   (t-min t [axis])
```
- No `axis` → reduce all elements → a scalar number.
- With `axis` (in `[0,rank)`) → remove that axis → a tensor of rank−1
  (e.g. shape `(3 4)`, sum axis 0 → `(4)`, axis 1 → `(3)`).
- If reducing would leave rank 0 (reducing a 1-D tensor's only axis), return a
  **scalar number** instead (rank-0 tensors are out of scope).
- `t-mean`'s divisor is the reduced count (always ≥ 1 since dims ≥ 1).

### Linear algebra
```
(matmul a b)   ; both rank 2: (m k)·(k n) -> (m n); inner dims must match.
```

## Error policy (explicit, never silent NaN)

- Construction: non-integer/`<1` dim → error; `len(data) != product(shape)` → error;
  non-numeric element → error; `(arange n)` with `n<1` → error; `from-nested`
  ragged/empty → error.
- Indexing: index count ≠ rank → error; index non-integer, `<0`, or `>= dim` → error.
- `reshape`: product ≠ `(size t)` → error. `slice`: `axis` out of range or not
  `0<=start<end<=dim` → error.
- Elementwise/`t-zip`: tensor↔tensor shape mismatch → error (shows both shapes).
- Reductions: `axis` out of `[0,rank)` → error.
- `matmul`: operand not rank-2, or inner dims differ → error.

Every error message names the offending shapes/indices.

## Module layout

`lib/math/tensor.lisp` — `(module math/tensor (export …))`. Self-contained
(no imports needed; arithmetic and vector ops are built in). Sits alongside
`core.lisp`, `linear.lisp`, `stats.lisp`, `dist.lisp`.

## Testing

`tests/math/tensor_test.lisp`, run with
`ZEPO_PATH="$PWD/lib" zepo test tests/math/tensor_test.lisp`. Uses `deftest`,
`is`, `=check`, `throws`; float results compared with `math/core`'s `abs-close?`;
exact integer data compared via `(tensor->nested t)` + `=check`.

- **Construction/introspection:** `(from-nested '((1 2 3)(4 5 6)))` → `(shape)` `(2 3)`,
  `(rank)` 2, `(size)` 6, `(tref t 1 2)` 6; `zeros`/`ones`/`full`/`arange` shapes & values.
- **Indexing:** `tset!` then `tref` round-trip; out-of-bounds and wrong-arity `throws`.
- **reshape:** size 6 → `(2 3)` → `(3 2)`, `tref` consistency; size-mismatch `throws`.
- **transpose:** 2×3 → 3×2 with correct elements; `(transpose (transpose t))` equals `t`.
- **slice:** 3×4 along axis 1 over `[1,3)` → 3×2 with the right elements.
- **elementwise:** `t+` same-shape; `t*` scalar (both operand orders); shape-mismatch
  `throws`; `(t-map sqrt t)`; `(t-zip max a b)`; `t-equal?` true/false cases.
- **reductions:** whole-tensor `t-sum`/`t-mean`/`t-max`/`t-min`; along-axis on a 2×3
  (axis 0 → length-3, axis 1 → length-2) with known sums; 1-D axis reduction → scalar.
- **matmul:** `(2×3)·(3×2)` against a hand-computed product; inner-dim mismatch `throws`.

## Future work (separate specs)

- Contiguous unboxed-`f64` storage via a Zig runtime primitive, behind this API.
- Strided views (zero-copy reshape/transpose/slice), broadcasting, rank-0 scalars,
  arbitrary axis permutations, multi-axis slicing, `eye`, 1-D `dot`, and
  `tensor`↔`math/linear` matrix interop.
