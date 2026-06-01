# ADR 0004 — Dynamic variables via fiber-local parameter objects

- Status: Accepted
- Date: 2026-06-01
- Bead: zepo-6o3p (implementation); zepo-ko80 (investigation that preceded it)

## Context

Zepo had no dynamic (special) variable facility: no `parameterize`, no
`make-parameter`, no `fluid-let`/`dynamic-wind`. The investigation in
zepo-ko80 confirmed this and noted two viable routes:

- **(a)** a cheap `parameterize`-style macro over a single global cell — no
  VM work, but the cell is per-VM, so it is *not* fiber-safe; and
- **(b)** real, fiber-local parameter objects backed by a per-fiber dynamic
  binding stack.

The CL-idioms epic (zepo-7bit) has several children that want dynamic
binding — restarts (g120), the advice/wrapper convention (rdan), and the
with-X resource conventions (qqzm). Every one of them would eventually need
fiber-local semantics. Choosing (a) now would mean reworking all of them
when the per-VM cell leaks across fibers. We pick (b).

## Decision

Implement R7RS-style parameter objects and `parameterize` natively.

### Semantics (R7RS, with one pragmatic extension)

- `(make-parameter init)` and `(make-parameter init converter)` return a
  **parameter object**. The converter (if supplied) is applied to `init` and
  to every value bound via `parameterize` or set via the mutation extension.
- A parameter object is **callable**:
  - `(p)` → returns the current dynamic value (the most recent
    `parameterize` binding in the current fiber, else the object's default).
  - `(p v)` → mutation extension (non-R7RS but common): converts `v` and
    overwrites the topmost active binding for `p`, or the default if none is
    active. Useful for REPL/imperative code.
- `(parameterize ((p1 v1) (p2 v2) ...) body...)` evaluates each `vi`, applies
  each parameter's converter, installs the bindings for the dynamic extent of
  `body`, and removes them on exit — including non-local exit via `raise`.

### Binding model: per-fiber dynamic stack

The active bindings live on a **per-fiber `dynamic_stack`** of
`DynamicFrame { param, value }`, modeled exactly on the existing per-fiber
exception `handler_stack`:

- Each fiber owns its own `dynamic_stack`; it is swapped in/out alongside
  `handler_stack` on fiber context switch (`src/vm/sched.zig`). This is what
  makes parameters fiber-local for free — a value parameterized in one fiber
  is invisible to another.
- A parameter *read* walks the current fiber's `dynamic_stack` top-down for a
  frame whose `param` matches by identity (pointer equality), falling back to
  the parameter object's stored default.
- The parameter object stores only `default` + `converter`; the live value is
  never stored in the object (that would not be fiber-local).

### Unwind safety

Zepo has **no continuations** (`call/cc` does not exist), so the only
non-local exit is `raise`. `parameterize` lowers to `PUSH_PARAM` ops + a
trailing `POP_PARAMS count` op (never tail-calling out of the body, so the
pop always runs on normal return). For the exceptional path, `HandlerFrame`
records the `dynamic_stack` depth at handler-install time, and `tryHandle`
truncates `dynamic_stack` back to that depth when it unwinds call frames.
That covers every escape route in the language.

## What this is NOT (scope limits)

- No `dynamic-wind` / `unwind-protect` general mechanism — `parameterize` is
  the only dynamic-extent construct introduced here. (with-X conventions in
  qqzm can build on `guard` + `parameterize`.)
- No thread-level concerns beyond fibers — Zepo concurrency is fibers only.
- The `(p v)` mutation form is a deliberate extension, documented as such.

## Consequences

- A new heap `Kind.parameter` (slot 14 of the u4 header; 15 remains free).
- A new per-fiber VM stack with its own GC rooting — parameterized values can
  be otherwise unreachable, so `dynamic_stack` frames MUST be GC-traced
  (unlike `handler_stack`, whose handlers are reachable via registers).
- Two new IR ops + two new bytecode opcodes (`PUSH_PARAM`, `POP_PARAMS`).
- Downstream beads (g120, rdan, qqzm) may now assume fiber-local dynamic
  binding exists.
