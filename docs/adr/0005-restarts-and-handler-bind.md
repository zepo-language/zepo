# ADR 0005 — Restarts and non-unwinding handlers (handler-bind)

- Status: Accepted (implemented)
- Date: 2026-06-01
- Bead: zepo-g120 (blocks epic zepo-7bit)
- Related: ADR 0004 (per-fiber dynamic stack — the template for the new
  per-fiber restart stack), zepo-9bi (existing handler stack), mi9x (fiber
  yield through prims).

## Context

Zepo today has `error`/`raise` plus `with-exception-handler` (and the `guard`
macro on top of it). All of these are **unwind-then-handle**: when a condition
is raised, `tryHandle` (src/vm/dispatch.zig) pops the call stack down to the
handler's recorded `frame_depth` *before* the handler runs. By the time a
handler executes, everything between the handler and the signal site is gone.

Restarts (CL `restart-case` / `invoke-restart`) require the opposite: a handler
must be able to run *while the signaling context is still live*, inspect the
available restarts, and transfer control into a chosen `restart-case` that is
lexically/dynamically **inside** the protected body — i.e. deeper on the stack
than the handler. That is impossible under unwind-then-handle: the
`restart-case` frame has already been discarded when the handler runs.

This is precisely why Common Lisp separates `handler-bind` (handler runs at the
signal site, no unwinding; may decline by returning) from `handler-case`
(unwinds, like Zepo's current `with-exception-handler`). **Restarts are built on
`handler-bind`, not `handler-case`.** Therefore implementing restarts correctly
requires first adding a non-unwinding handler path.

A pragmatic "restarts without handler-bind" shortcut was considered and
rejected: it cannot satisfy the bead's own acceptance example
(`a handler invokes 'use-default`), because the restart-case is unwound before
the (outer) handler runs. See "Alternatives".

## Decision

Add a non-unwinding signal path and restarts, in three layers, all per-fiber
and modeled on the existing per-fiber `handler_stack` / `dynamic_stack`:

### 1. `handler-bind` — non-unwinding handlers

`(handler-bind ((pred handler-fn) ...) body...)` installs handlers that run at
the signal site with the stack intact. Represented by tagging the existing
`HandlerFrame` with a `kind: enum { unwinding, binding }`. `with-exception-handler`
keeps `kind = .unwinding` (unchanged); `handler-bind` pushes `kind = .binding`.

### 2. A unified `signal` protocol

`error`/`raise` no longer immediately return a Zig error. They call
`vm.signal(condition)`, which walks `handler_stack` top-down (most-recent
first), honoring installation order across both kinds:

- **binding handler**: call it in place via `callValue([condition])` with the
  stack intact. While it runs, it is marked inactive (a `signal_floor` index)
  so the handler and any nested signal skip it (CL rule). If it **returns
  normally**, it *declined* — continue to the next outer handler. If it performs
  a non-local transfer (invokes a restart, or an enclosing unwinding handler),
  that transfer propagates as a Zig error and we never return.
- **unwinding handler**: stop the walk and return `error.UserError`, recording
  the `signal_floor` so the existing `tryHandle` resumes the unwind-then-handle
  behavior **at that handler** (skipping the binding handlers already declined
  above it).
- **no handler handles it**: propagate `error.UserError` to the top level / REPL.

### 3. `restart-case` / `invoke-restart`

`(restart-case BODY (NAME (param...) [:report STR] clause-body...) ...)`:
- Each clause is lowered to a **closure** `(lambda (param...) clause-body...)`
  capturing the restart-case's lexical scope.
- New per-fiber `restart_stack` of `RestartFrame { name, clause_fn, report,
  frame_depth, resume_pc, resume_func, dst_reg, dynamic_depth }`. `frame_depth`
  is the restart-case's own call frame — the transfer target. One frame is
  pushed per clause (new ops `PUSH_RESTART` / `POP_RESTARTS count`), exactly
  mirroring `PUSH_HANDLER`/`POP_HANDLER` and `PUSH_PARAM`/`POP_PARAMS`.
- BODY runs; last expr → `dst`; then `POP_RESTARTS`. Normal exit returns BODY's
  value (clauses not run).

`(invoke-restart 'NAME arg...)`: find the most-recent `restart_stack` entry
named NAME; set `vm.pending_restart = { frame, args }`; return a new internal
`error.RestartInvoked`. The dispatch loop catches it (sibling to `tryHandle`)
and performs a transfer identical in shape to `tryHandle`: unwind call frames to
`frame.frame_depth`, truncate `dynamic_stack` to `frame.dynamic_depth`, set the
restart-case frame to resume at `frame.resume_pc`/`resume_func`, and push a
frame applying `frame.clause_fn` to the args whose RETURN lands in
`frame.dst_reg`. Result: the clause runs in the restart-case's place and
`restart-case` evaluates to the clause's value; the handler does **not** regain
control (correct CL semantics).

Support procedures: `(compute-restarts)` → list of active restart name symbols
(most-recent first); `(find-restart 'NAME)` → name or #f; `(restart-report r)`
→ the :report string. These let a handler and the REPL enumerate options.

### 4. REPL integration — debugger at the signal site

A post-mortem picker in `cli/repl_cmd.zig` does NOT work: by the time an error
returns to the REPL the scheduler has been torn down and the `restart-case`
call frames are dead, so there is nothing live to transfer into. CL solves this
with a *break loop* that runs **at the signal site**, before unwinding — which
is exactly what `handler-bind` gives us.

So the debugger is a default `handler-bind` handler that the REPL wraps around
each top-level evaluation. When an otherwise-unhandled condition reaches it, the
handler (running with the stack intact) prints the condition and lists
`(compute-restarts)` with their `:report` strings, reads a choice via the
existing `read-line` prim, and calls `(invoke-restart chosen ...)` — transferring
into the still-live `restart-case`. If the user declines, the handler returns
normally (declines), and the condition propagates to the normal top-level error
print. This debugger is written in Lisp (in the prelude or REPL bootstrap) over
`compute-restarts`/`find-restart`/`invoke-restart`/`read-line`; no VM↔terminal
coupling is added.

## Cross-cutting requirements

- **GC rooting**: `restart_stack` frames hold heap values (`name`, `clause_fn`,
  `report`) that may be otherwise unreachable — they MUST be traced in
  `vmRootVisit` (like `dynamic_stack`, unlike `handler_stack`). `pending_restart`
  args likewise while pending.
- **Per-fiber swap**: `restart_stack` is saved/restored in `sched.zig`
  alongside `handler_stack`/`dynamic_stack`, with a `main_restart_snapshot`.
- **Unwind truncation**: `HandlerFrame` gains `restart_depth`; `tryHandle`
  truncates `restart_stack` to it on unwind (a raise escaping a restart-case
  removes its restarts), exactly as it already does for `dynamic_depth`.
- **Fiber yield**: because `restart_stack` is per-fiber and swapped like
  `handler_stack`, restarts survive `(yield)`/`spawn` the same way handlers do
  (mi9x). Verified by test.
- **No continuations / no unwind-protect**: Zepo still has neither. Restart
  transfer therefore needs no cleanup-form replay; `raise` and `invoke-restart`
  are the only non-local exits and both are covered.

## Scope limits (what this is NOT)

- No `signal`/`warn` distinction or full CL condition type hierarchy — `error`
  and `raise` remain the only signaling primitives; handlers dispatch on the
  condition value with ordinary predicates.
- No `unwind-protect`/cleanup replay during transfer (no such mechanism exists
  yet; out of scope, can layer later).
- `handler-bind` handlers dispatch is "call the handler; it decides" — we do not
  add per-clause condition-type matching in the special form (the handler body
  does its own `cond`). A `handler-bind` macro sugar may wrap typed clauses.

## Consequences

- Two new IR ops + bytecode opcodes (`PUSH_RESTART`, `POP_RESTARTS`); one new
  internal error (`RestartInvoked`); `HandlerFrame.kind` + `restart_depth`.
- `error`/`raise` route through `vm.signal`; existing unwinding-handler
  behavior is preserved as the fallback, so `guard`/`with-exception-handler`
  and all current tests are unaffected.
- New surface: `handler-bind`, `restart-case`, `invoke-restart`,
  `compute-restarts`, `find-restart`, `restart-report`.

## Alternatives considered

- **Restarts on the existing unwinding handlers (no handler-bind).** Rejected:
  the handler runs after the stack is unwound, so a restart-case inside the
  protected body is already gone; `invoke-restart` from a handler has no live
  target. Fails the bead's acceptance example. Would only support invoking a
  restart from *within* the restart-case extent, which is not the useful case.
- **Make `with-exception-handler` itself non-unwinding.** Rejected: changes the
  semantics of existing code and the `guard` macro; `guard`/`handler-case`
  unwinding is correct and expected. Keep both kinds.
