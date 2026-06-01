# ADR 0006 — Single-dispatch generic functions

- Status: Accepted (implemented)
- Date: 2026-06-01
- Bead: zepo-gz21 (blocks epic zepo-7bit)

## Context

Zepo has no type-driven dispatch and no user-defined types — only built-in type
predicates (`pair?`, `number?`, …). The bead asks for single-dispatch generic
functions (`defgeneric`/`defmethod`) dispatching on the first argument's type,
explicitly scoped to `:primary` methods (no multiple dispatch, no
`:before`/`:after`/`:around`, no MOP). The acceptance example dispatches on user
types (`circle`, `rect`), so a user-type mechanism is a prerequisite.

Two design questions the bead flags:
1. **How do user types work** — add `defstruct`, or use plists/tagged data?
2. **What is the type language** — can methods specialize on primitives like
   `pair`/`string`, and how is a value's type determined cheaply (the benchmark
   forbids an order-of-magnitude dispatch regression)?

## Decision

### User types: `defstruct` over tagged vectors

A struct value is a vector `#( %struct <type-sym> field0 field1 … )`, where
`%struct` is a fixed marker symbol and `<type-sym>` is the struct's type name.
`(defstruct NAME field...)` is a stdlib macro generating:

- constructor `(make-NAME field...)` → the tagged vector,
- predicate `(NAME? x)`,
- accessors `(NAME-field x)` for each field.

Rationale: vectors already exist, the tagged-vector convention is collision-
resistant (a plain vector never starts with the `%struct` marker), and it keeps
the whole feature in the stdlib + one tiny primitive. No new heap kind, no VM
object work. (A future native record kind can replace the representation behind
the same macros without changing user code.)

### `type-of`: one O(1) primitive

`(type-of x)` returns a **symbol** naming x's type:

- immediates/builtins → `integer`, `float`, `boolean`, `char`, `null`, `pair`,
  `string`, `symbol`, `vector`, `procedure`, `hash-table`, `bytevector`,
  `parameter`, `fiber`, `foreign`;
- a `%struct`-tagged vector → its `<type-sym>` (e.g. `circle`).

It is a native primitive that reads the value's immediate tag / heap Kind in
constant time (a predicate-chain in Lisp would add ~a dozen checks per dispatch
and risk the benchmark regression the bead warns about). Numbers report the
*specific* type (`integer`/`float`), not a coarse `number` — honest and lets a
method specialize precisely; a method that wants both defines both (documented).

Methods MAY specialize on any `type-of` result, including primitives:
`(defmethod describe ((x string)) …)` is legal.

### `defgeneric` / `defmethod` / dispatch

- `(defgeneric NAME (args...) [:documentation "…"])` registers NAME in a global
  registry and defines NAME as a dispatcher closure.
- `(defmethod NAME ((arg TYPE) more...) body...)` registers, under NAME and the
  symbol TYPE, a method closure `(lambda (arg more...) body...)`.
- Method storage: a global hash-table `*generics*` : NAME-symbol →
  (hash-table TYPE-symbol → method). Lookup at call time is
  `(type-of (car args))` → table get. Calling NAME with no applicable method
  raises a clear error naming the generic and the offending type.

Dispatch cost = one `type-of` (constant) + one hash-table get + an `apply` —
i.e. comparable to the hand-rolled "hash-table of procedures" alternative, as
the acceptance requires. (Per-call-site caching from the sketch is deferred; it
is a transparent optimization that needs no API change.)

## Scope limits

- Single dispatch only (first argument). Multiple dispatch is a follow-up.
- `:primary` methods only — no method combination / `call-next-method`.
- No inheritance / subtype relationships: `type-of` is exact. (A struct is its
  own type; there is no "is-a" hierarchy yet.)
- `type-of` returns specific number types (`integer`/`float`), not `number`.

## Consequences

- One new primitive: `type-of`. Everything else (`defstruct`, `defgeneric`,
  `defmethod`, the registry helpers) lives in the stdlib.
- New surface: `type-of`, `defstruct` (+ generated `make-`/`?`/accessors),
  `defgeneric`, `defmethod`.
- The tagged-vector struct representation is an implementation detail behind the
  `defstruct` macros and can later become a native record kind.
