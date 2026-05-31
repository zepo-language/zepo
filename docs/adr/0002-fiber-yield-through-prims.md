# ADR 0002: Fiber yields propagated through prims-calling-execFn are unsafe

- **Status:** Accepted (analysis); fix pending in [[zepo-mi9x]]
- **Date:** 2026-05-30
- **Beads:** zepo-b6hw (this writeup), zepo-mi9x (fix), zepo-gjwb (regressions), zepo-da9t (downstream unblock)

## Context

A class of primitives — `apply`, `with-exception-handler`, `call-with-values`,
and any other prim that calls `vm.execFn` directly to invoke a user closure —
silently corrupts VM state when the inner closure yields the fiber (via
`sleep`, `spawn`, `channel-recv!`, etc.). The downstream symptom most
commonly seen: a top-level `(define VAR (apply LAMBDA-THAT-SLEEPS '()))`
evaluates without obvious error, but `VAR` ends up unbound. The same
pattern flowing through `lib/testing.lisp`'s `run!` was how the bug
originally surfaced (a test thunk that called `sleep` made the caller's
`(define r (run! ...))` silently fail).

## Minimal repro

Two lines:

```lisp
(define x (apply (lambda () (sleep 0.01) 42) '()))
(display x)  ; error: unbound variable: x
```

The error trace shows `apply` / `<anonymous>` still on the stack at the
display site — strong hint that the resume path didn't unwind correctly.

## Verified root cause

Instrumenting `PRIM_CALL` (the bytecode that dispatches `(apply ...)`) at
`src/vm/dispatch.zig:842` to log when `pfn(...)` returns an error confirmed:

```
[ewdc-debug] prim returned error=FiberYielded yield_requested=false block=true park=false
```

Sequence of events:

1. `(sleep 0.01)` inside the closure sets `vm.yield_requested = true`,
   `vm.block_on_yield = true`, `vm.park_on_yield = true`, and returns
   success (NIL).
2. The **inner** dispatch loop (executing the closure's bytecode) sees
   `yield_requested`, advances PC past the sleep CALL, clears
   `yield_requested` and `park_on_yield`, and returns
   `DispatchResult.yielded`.
3. `execFn` (called by `primApply`) translates `.yielded` into
   `error.FiberYielded`.
4. `primApply` propagates that error up to its caller.
5. The **outer** `PRIM_CALL` handler in `dispatch.zig` was invoking
   `primApply` via `const prim_val = try pfn(...);`. The `try` catches
   `error.FiberYielded` and rethrows it. **It never reaches the
   `if (vm.yield_requested)` block at line 845+ where PC advancement
   and proper parking would happen.**
6. The outer frame's PC stays at the apply CALL. The inner closure's
   frame is still on the call stack with no continuation waiting for
   its return value.
7. On fiber resume, the closure runs to completion, its frame pops, the
   value goes "nowhere" (there's no waiting execFn frame), and the outer
   dispatch ends up with stale PC / corrupt register state. The
   `STORE_GLOBAL` that should have written `r` (or `x`) never executes.

## Why this is a *class* of bugs, not one bug

Any primitive that hands a user closure to `execFn` and propagates the
result back as its own return value is affected. The set today:

- `src/prims/apply.zig` — `primApply`
- `src/prims/apply.zig` — `primCallWithValues` (via the producer thunk)
- `src/prims/pairs.zig` — `primWithExceptionHandler` (commit `c80b18f`
  added a partial fix that lets the *handler thunk* yield correctly,
  but the *body thunk* yielding still loses state if called from a
  defining context)
- `src/prims/eval_prim.zig` — `primEval`, which already mitigates the
  bug by converting `FiberYielded` to `ContractViolation` (i.e. *forbids*
  yields inside eval'd code instead of supporting them)

Inside `for-each` (defined in `lib/stdlib.lisp` and itself implemented
via `apply`), the same trigger appears — which is what surfaced the
bug originally inside `lib/testing.lisp`'s `run!`.

## Why `eval`'s mitigation isn't enough as a general fix

Converting `FiberYielded` to `ContractViolation` (eval's choice) means
yields inside the prim's thunk become a hard error. That's acceptable
for `eval` (REPL-style; if you want async, don't use eval). It's NOT
acceptable for `apply` — `(apply thunk args)` is the workhorse for
calling stored closures, and forbidding yields would break
`for-each`-style traversal that legitimately wants to sleep, spawn, or
recv inside the per-element thunk.

The real fix has to thread the closure's eventual return value back to
the outer frame's register on resume. See zepo-mi9x for the two
candidate strategies (conservative-but-limiting vs.
proper-continuation-tracking).

## Locked-in regression input

`tests/runtime/ewdc_minimal_repro.lisp` contains the two-line repro.
It's intentionally a `.lisp` file (not a Zig test) so the fix bead can
flip a single CI invocation from "this errors with UnboundVariable" to
"this prints 42". When the fix lands, that file becomes a passing
smoke check.
