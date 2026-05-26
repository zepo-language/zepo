# Design: Structured Code & Data to Workers

**Date:** 2026-05-26
**Status:** Approved (design); pending implementation plan
**Author:** brainstormed with Leslie Russell

## Problem

Today the only way to give a worker code is `spawn-worker`, which takes a
**source string** that the worker compiles on the fly (`worker_prims.zig`,
`ctx.evalString(code, "<worker>")`). Data crosses worker boundaries through
channels as *portable values* (deep-copied; immutable; isolated heaps) per
`src/runtime/portable_value.zig`. The portable set is: nil, bool, fixnum,
char, EOF, float, string, symbol, bytevector, and pairs/vectors of portable
values.

We want a more structured, still memory-safe way to pass code and data:
lambdas/closures (by value) and JSON-shaped maps.

## Key constraint that shapes the design

A **compiled closure cannot cross an isolated-VM boundary**:

- `code_ptr` (`objects.zig:213`, closure body word 0) is an index into the
  *sending* VM's `CompiledFn` pool. The worker has its own pool with different
  ids; the number is meaningless there.
- `home_env` (closure body word 2) is a raw pointer to the sender's
  `GlobalEnv` — dead memory in the worker's heap.

Therefore serializing a closure by id/pointer is impossible. The only viable
path is to ship code as **data** and recompile it in the worker.

## Core principle

> Code bound for a worker is **data**, not a compiled closure. It is authored
> as a (quasi)quoted s-expression, travels as an ordinary portable value
> (pairs + symbols + quoted literals — already supported today), and is
> compiled by the **worker** on arrival. By-value capture is achieved by
> splicing real values into the form with `,` (unquote) at send time, which is
> memory-safe because the spliced values are portable snapshots.

The main program never compiles worker-bound code. The compiler is not
involved in any way — exactly because, until it reaches the worker, the code
is just data.

This deliberately drops the alternative "send an arbitrary existing compiled
closure value" capability. You can only send code you authored as a form. That
tradeoff was accepted: it removes all compiler changes, AST retention, and
gating machinery.

## What already works today (no change)

- Quasiquote / unquote / unquote-splicing are supported by the reader and
  macro expander (`reader/parse.zig:144`, `expand/macros.zig`).
- A quoted form like `(lambda (x) (+ x 5))` is just pairs + symbols + literals
  and is **already portable** — you can `channel-send!` it today.

The only missing pieces are (1) a way for the worker to turn a received form
back into running code, and (2) a portable map type for JSON objects.

## Components (entire new surface)

### 1. `(eval form)` primitive

- New first-class primitive. Thin wrapper over the existing internal
  `evalForm` (`src/runtime/eval.zig:239`).
- Compiles + runs an s-expr `Value` in the **current VM's top-level global
  environment** (v1: no environment argument).
- Returns the result. Parse/compile/runtime errors propagate as ordinary Lisp
  errors.
- **Security note:** `eval` is dynamic code execution available anywhere, not
  only in workers. This is an intentional, owned tradeoff — it is the
  orthogonal building block that makes the rest compose.
- **Reachability — RESOLVED (verified 2026-05-26):** a prim reaches the
  pipeline via the existing `VM.do_import_ctx: ?*anyopaque` back-pointer
  (`dispatch.zig:73`), set to the owning `EvalContext` at `eval.zig:426`.
  Cast it back (`@ptrCast(@alignCast(vm.do_import_ctx))` -> `*EvalContext`,
  same pattern as `vmImportCallback`, `eval.zig:441`) then call
  `ctx.evalForm(form)`. No new wiring strictly required; optionally add a
  typed `eval_context: ?*EvalContext` field on `VM` for clarity.
- **Spans — RESOLVED:** a runtime-constructed form has no span entry;
  `SpanTable.get` returns `null` for unknown forms (`source.zig:38`), handled
  gracefully -> degraded error messages, not a crash.
- **Re-entrancy — RESOLVED (verified 2026-05-26):** `vm.run` (`dispatch.zig:371`)
  spins up a *fresh `Scheduler`* per call, so calling it re-entrantly (which
  `(eval form)` does — eval runs from inside a live dispatch loop, especially
  in a worker) would nest a scheduler on a VM that already has an active
  scheduler/fiber context — corruption. `vm.execFn` (`dispatch.zig:386`) is
  re-entrant-safe: it pushes frames at `base = regs.len` and unwinds on
  `.value`. `runMain` itself enters a top-level thunk via
  `vm.execFn(func, NIL, args)` (`sched.zig:280`) with a NIL closure (globals
  resolve through `vm.globals`/`fallback_globals`). **Approach:**
  - Extract a private `compileFormToFnId(ctx, form) !u32` from
    `evalNonModuleForm` (`eval.zig`): everything from the `HandleScope` through
    the `actual_fn_id` computation and the `vm.compiled_fns`/`globals` update —
    the delicate `no_gc`/rooting logic stays in one place (DRY).
  - `evalNonModuleForm` becomes `compileFormToFnId` + `vm.run` (unchanged
    top-level behavior).
  - New `evalFormNested(ctx, form) !Value` = `compileFormToFnId` +
    `vm.execFn(&vm.compiled_fns[id], NIL, &.{})`. The `eval` prim calls this.
- **`eval` is synchronous-only in v1 (accepted limitation):** because the
  nested execution path has no scheduler, a form passed to `(eval ...)` that
  yields or spawns a fiber returns `error.FiberYielded` with nothing to handle
  it, so `eval` raises an error. Eval'd forms must compute and return.
  Concurrency belongs in the worker's spawn entry, which runs under the real
  scheduler via `runMain` and is unaffected.

### 2. Portable hashtable

- Add a `hash_table` variant to `ChannelValue` (`portable_value.zig:256`).
- **Serialize:** iterate entries via `hashtable.forEach`
  (`runtime/hashtable.zig:218`, GC-safe re-read), producing a list of
  (key, value) channel values. Keys and values recurse through the existing
  portable path (must themselves be portable).
- **Deserialize:** `hashtable.make(gc)` then `set()` each key/value pair into
  the receiving heap.
- **Equality:** default `equal?` semantics only (`hashtable.zig:108`,
  `structurallyEqual`). No user-supplied hash/eq closures — the current
  implementation does not support them, so there is nothing extra to carry.
- **NIL key:** already rejected by the table (NIL is the empty-slot sentinel);
  that invariant holds across the boundary.
- Teach `checkPortable` (`portable_value.zig:40`) to accept hashtables by
  recursing into keys + values.
- JSON objects deserialize to real hashtables; this also unlocks sending any
  portable map, not just JSON.

### 3. `spawn-worker` accepts a form

- `spawn-worker` accepts **either** a source string (unchanged, back-compat)
  **or** a portable form.
- Form path reuses the same serialize/deserialize used for channels: the form
  is serialized in the sender, reconstructed in the worker's heap, then
  `evalForm`-ed to a callable, which is invoked with the pre-shared channels —
  the same callable/arity contract as the string path today.
- Enables building the worker entry with quasiquote (splice config/values into
  the entry form).

## What is explicitly NOT touched

- **No compiler changes.** No AST retention on closures, no free-variable
  bookkeeping at runtime, no gating flag. (Earlier brainstorm directions that
  required compile-then-decompile of live closures were rejected for exactly
  this reason.)
- **No `closure` wire type.** Compiled closures remain non-portable and are
  still rejected with `NonPortableValue`. Forms cross because they are already
  ordinary portable values.

## Data flow — capture by value

```scheme
(define n 5)
(define cfg (make-hash-table))            ; portable map, also sendable
(hash-table-set! cfg "limit" 100)

(channel-send! ch `(lambda (x) (+ x ,n)))  ; sends data: (lambda (x) (+ x 5))
(channel-send! ch cfg)                     ; sends a portable hashtable

;; in the worker:
(define f (eval (channel-recv! ch)))       ; compiled in the worker's own VM/heap
(define c (channel-recv! ch))              ; an independent hashtable copy
(f 10)                                     ; => 15
```

## Error semantics

- Sending a real compiled closure -> `NonPortableValue` (unchanged; you send
  forms, not closures).
- `,`-splicing a non-portable value into a form -> caught at send time by the
  existing `checkPortable` traversal.
- Splicing a non-self-evaluating captured value (list/vector) into *code*
  position would make the worker try to evaluate it as code. The author quotes
  it instead: `` `(cons x ',xs) `` -> `(cons x '(1 2 3))`. Documented gotcha.
- `eval` of a malformed form or a form with unbound free symbols -> normal Lisp
  error raised in the worker.
- Cyclic structure anywhere in a sent value -> `CyclicStructure` (unchanged).

## Testing strategy

- **`eval` primitive:** self-evaluating literals; arithmetic forms;
  lambda-producing forms invoked after eval; error propagation for malformed /
  unbound-symbol forms.
- **Round-trip (two VMs):** build a quasiquoted lambda with spliced fixnum,
  string, and quoted nested-list captures -> serialize -> deserialize in a
  second VM -> `eval` -> invoke -> assert result.
- **Hashtable portability:** send/recv a table with portable keys+values and
  assert structural equality; assert a table containing a port/closure value is
  rejected with `NonPortableValue`; assert NIL-key rejection still holds.
- **Worker end-to-end:** `spawn-worker` with a *form* entry that takes a
  channel; separately, send a lambda-form to a running worker over a channel
  and have it `eval` + invoke it.

## Out of scope

- Sending arbitrary pre-existing compiled closures (deliberately dropped).
- User-supplied hash/eq closures on portable hashtables.
- `eval` with an explicit environment argument (current VM globals only in v1).
- Bytecode serialization / cross-VM code linking.
