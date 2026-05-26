# Structured Code & Data to Workers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Zepo workers receive structured code (as data forms compiled on arrival via a new `(eval form)` primitive) and portable maps (hashtables), instead of only raw source strings.

**Architecture:** Code bound for a worker travels as a (quasi)quoted s-expression — already a portable value (pairs/symbols/literals) — and is recompiled in the worker. Capture-by-value is done by the *author* with unquote (`,x`) at send time. The worker turns a received form into running code with a new `eval` prim that compiles the form and runs it through `vm.execFn` directly (re-entrant-safe; no nested scheduler; synchronous-only in v1). Hashtables become a portable type for JSON/maps. The compiler is not modified.

**Tech Stack:** Zig (zepo runtime/VM), Zepo Lisp. Tests: `zig build test` (aggregate Zig unit tests) and `.lisp` files run via `zig build run -- <file>`.

**Spec:** `docs/superpowers/specs/2026-05-26-portable-worker-code-design.md`

**Beads workflow (per project CLAUDE.md):** Each Phase gets one beads issue. Before touching code in a phase: create + claim the issue, branch named exactly after the issue id, do the phase's tasks as commits on that branch, run `zig build test`, merge to master, delete branch, close the issue. Tag each contiguous new code block with a `// <issue-id>` comment.

**Note on line numbers:** All `path:line` references were captured 2026-05-26. Re-confirm exact lines at execution with a quick grep before editing; the surrounding code quoted in each task is the anchor.

---

## Phase 1 — `eval` primitive

This is the keystone. Tasks 1.1→1.3. One beads issue for the phase; suggested title: "eval primitive: compile+run an s-expr form (sync, re-entrant-safe)".

### Task 1.1: Refactor — extract `compileFormToFnId` from `evalNonModuleForm`

Pure refactor: pull the compile pipeline out of `evalNonModuleForm` so both the top-level path (`vm.run`) and the new nested path (`vm.execFn`) share it. Behavior must not change.

**Files:**
- Modify: `src/runtime/eval.zig` (`evalNonModuleForm`, currently ends at `return ctx.vm.?.run(actual_fn_id, &.{});`)

- [ ] **Step 1: Confirm the current shape**

Run: `grep -n "pub fn evalNonModuleForm\|return ctx.vm.?.run" src/runtime/eval.zig`
Expected: `evalNonModuleForm` exists and its body ends with `return ctx.vm.?.run(actual_fn_id, &.{});`.

- [ ] **Step 2: Extract the compile pipeline into a private method**

Replace the body of `evalNonModuleForm` so everything from the `HandleScope` setup through the `actual_fn_id` computation and the `vm.compiled_fns`/`globals` update lives in a new private method `compileFormToFnId`, and `evalNonModuleForm` becomes a thin wrapper.

```zig
// Compile a single (already module/macro-dispatched) form into a top-level
// thunk and return its index in ctx.compiled. Performs the delicate
// no-GC/rooting dance and keeps ctx.vm.compiled_fns/globals in sync. The
// caller chooses how to execute the thunk (run vs execFn).
fn compileFormToFnId(ctx: *EvalContext, form: Value) !u32 {
    if (ctx.gc.trace.eval) {
        if (ctx.spans.get(form)) |span| {
            std.debug.print("[eval] {s}:{d}:{d}\n", .{ span.file, span.start.line, span.start.col });
        } else {
            std.debug.print("[eval] <unknown location>\n", .{});
        }
    }

    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    const qq_slot = scope.push(try expand_mod.expand(form, ctx.symbols, ctx.gc));
    const expanded_slot = scope.push(if (ctx.vm != null)
        try macros.macroExpand(ctx, qq_slot.*)
    else
        qq_slot.*);

    try ctx.gc.reserveNursery(16 * 1024);
    var no_gc = ctx.gc.noCollect();

    var builder = Builder.init(&ctx.arena, ctx.symbols, ctx.allocator);
    builder.span_table = &ctx.spans;
    const root_id = try builder.build(expanded_slot.*);

    var analyzer = sema_mod.CaptureAnalyzer.init(&ctx.arena, ctx.allocator);
    try analyzer.analyze(root_id);

    var compiler = Compiler.initWithGc(&ctx.arena, &ctx.program, ctx.symbols, ctx.gc, ctx.allocator);
    const fn_id = try compiler.compileExpr(root_id);

    const compiled_base = ctx.compiled.items.len;
    const emitted_base = ctx.emitter.emitted_count;
    try ctx.emitter.emitAppend(&ctx.program, &ctx.compiled);
    no_gc.release();

    if (ctx.vm) |*v| {
        v.compiled_fns = ctx.compiled.items;
        v.globals = ctx.currentEnv();
        if (ctx.current_module != null) {
            v.fallback_globals = ctx.globals;
        }
    } else {
        ctx.vm = try VM.init(ctx.gc, ctx.currentEnv(), ctx.symbols, ctx.compiled.items, ctx.allocator, ctx.vm_max_regs);
        if (ctx.current_module != null) {
            ctx.vm.?.fallback_globals = ctx.globals;
        }
        ctx.vm.?.do_import = vmImportCallback;
        ctx.vm.?.do_import_ctx = ctx;
        ctx.vm.?.installAsRoot();
    }

    const actual_fn_id: u32 = @intCast(compiled_base + (fn_id - emitted_base));
    if (ctx.toplevel_fn_ids) |log| {
        log.append(ctx.allocator, actual_fn_id) catch {};
    }
    return actual_fn_id;
}

pub fn evalNonModuleForm(ctx: *EvalContext, form: Value) !Value {
    const actual_fn_id = try ctx.compileFormToFnId(form);
    return ctx.vm.?.run(actual_fn_id, &.{});
}
```

- [ ] **Step 3: Run the full suite to confirm no behavior change**

Run: `zig build test`
Expected: PASS (same as before the refactor — this is a no-op restructure).

- [ ] **Step 4: Commit**

```bash
git add src/runtime/eval.zig
git commit -m "refactor(eval): extract compileFormToFnId from evalNonModuleForm

Shared compile pipeline so a nested execFn path can reuse it.
No behavior change."
```

---

### Task 1.2: Add `evalFormNested` (execFn path, sync-only)

**Files:**
- Modify: `src/runtime/eval.zig` (add method next to `evalNonModuleForm`)
- Test: add a `test` block in `src/runtime/eval.zig` (picked up by `runtime_tests`)

- [ ] **Step 1: Write the failing test**

Add at the end of `src/runtime/eval.zig`. It evaluates a form, then re-enters eval *from within* a running VM via a tiny synchronous form, proving execFn nesting works and a value comes back.

```zig
test "evalFormNested: compiles and runs a form via execFn" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var globals = try GlobalEnv.init(&gc, alloc);
    defer globals.deinit();
    try register_mod.registerAll(&gc, &globals, &syms);
    var ctx = try EvalContext.init(&gc, &syms, &globals, alloc);
    defer ctx.deinit();
    ctx.installRootVisitor();

    // Bootstrap a VM via the normal path.
    _ = try ctx.evalString("(+ 1 1)", "<test>");

    // Build the form (+ 40 2) as data and run it through the nested path.
    var parser = Parser.init(ctx.gc, ctx.symbols, &ctx.spans, "(+ 40 2)", "<form>", ctx.allocator);
    defer parser.deinit();
    const form = try parser.readOne();
    const result = try ctx.evalFormNested(form);
    try std.testing.expectEqual(value_mod.fixnum(42), result);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "evalFormNested"`
Expected: FAIL — `evalFormNested` is not defined (compile error).

- [ ] **Step 3: Implement `evalFormNested`**

Add next to `evalNonModuleForm` in `src/runtime/eval.zig`:

```zig
// Compile and run a form on the CURRENT call stack via execFn, so it is safe
// to call from inside a running dispatch loop (unlike `run`, which spins up a
// fresh Scheduler). v1 limitation: the form must run synchronously — if it
// yields or spawns a fiber, execFn returns error.FiberYielded which we surface
// as an error (there is no scheduler at this nested level to resume it).
pub fn evalFormNested(ctx: *EvalContext, form: Value) !Value {
    // Route module/macro declaration heads exactly like evalFormInner so
    // (eval '(import ...)) etc. behave consistently; everything else compiles.
    const inner = ctx.evalFormNestedInner(form);
    return inner catch |e| {
        if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(form);
        return e;
    };
}

fn evalFormNestedInner(ctx: *EvalContext, form: Value) !Value {
    if (isHeadSymbol(form, "module") or isHeadSymbol(form, "lib") or
        isHeadSymbol(form, "import") or isHeadSymbol(form, "export") or
        isHeadSymbol(form, "include") or isHeadSymbol(form, "load") or
        isHeadSymbol(form, "package") or isHeadSymbol(form, "defmacro") or
        isHeadSymbol(form, "define-syntax"))
    {
        // Declaration forms are compile-time; defer to the normal (non-nested)
        // dispatch which does not execute bytecode for them.
        return ctx.evalFormInner(form);
    }
    const actual_fn_id = try ctx.compileFormToFnId(form);
    return ctx.vm.?.execFn(&ctx.vm.?.compiled_fns[actual_fn_id], value_mod.NIL, &.{});
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -A3 "evalFormNested"`
Expected: PASS.

- [ ] **Step 5: Add the sync-only guard test**

A form that spawns/yields must error, not corrupt state. Append:

```zig
test "evalFormNested: yielding form errors rather than corrupting" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var globals = try GlobalEnv.init(&gc, alloc);
    defer globals.deinit();
    try register_mod.registerAll(&gc, &globals, &syms);
    var ctx = try EvalContext.init(&gc, &syms, &globals, alloc);
    defer ctx.deinit();
    ctx.installRootVisitor();
    _ = try ctx.evalString("(+ 1 1)", "<test>");

    // A bare (spawn ...) at the nested level has no scheduler to host the fiber.
    var parser = Parser.init(ctx.gc, ctx.symbols, &ctx.spans, "(spawn (lambda () 1))", "<form>", ctx.allocator);
    defer parser.deinit();
    const form = try parser.readOne();
    const res = ctx.evalFormNested(form);
    try std.testing.expectError(error.FiberYielded, res);
}
```

Run: `zig build test 2>&1 | grep -A3 "yielding form"`
Expected: PASS (a yielding form surfaces `error.FiberYielded`). If `spawn` does not yield synchronously in this build, replace the form with the smallest construct that yields and assert the error it produces; the invariant under test is "nested eval of a yielding form returns an error, not a wrong value."

- [ ] **Step 6: Commit**

```bash
git add src/runtime/eval.zig
git commit -m "feat(eval): evalFormNested runs a form via execFn (sync, re-entrant-safe)"
```

---

### Task 1.3: Add the `(eval form)` primitive and register it

**Files:**
- Create: `src/prims/eval_prim.zig`
- Modify: `src/prims/register.zig` (add import + `make("eval", 1, ...)`)
- Test: `tests/runtime/prims_test.zig` (Zig) and a new `.lisp` smoke

- [ ] **Step 1: Write the failing Lisp smoke**

Create `examples/eval-smoke.lisp`:

```scheme
;; Compiles a data form into a callable and invokes it.
(define n 5)
(define f (eval (list 'lambda (list 'x) (list '+ 'x n))))   ; (lambda (x) (+ x 5))
(display (f 10))   ; expect 15
(newline)
(display (eval 42)) ; self-evaluating form
(newline)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build run -- examples/eval-smoke.lisp`
Expected: FAIL — `eval` is an unbound variable (not yet registered).

- [ ] **Step 3: Implement the primitive**

Create `src/prims/eval_prim.zig`:

```zig
// <issue-id>
//! (eval form) — compile and run an s-expr Value in the current VM's
//! top-level global environment. Synchronous only (see evalFormNested).
const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const runtime = @import("../runtime/mod.zig");
const LispError = runtime.LispError;
const EvalContext = runtime.EvalContext;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

pub fn primEval(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    // The VM carries a back-pointer to its EvalContext as do_import_ctx
    // (set in eval.zig). Cast it back to reach the compile pipeline.
    const ctx_opaque = vm.do_import_ctx orelse return error.ContractViolation;
    const ctx: *EvalContext = @ptrCast(@alignCast(ctx_opaque));
    return ctx.evalFormNested(args[0]) catch |e| switch (e) {
        // Normalize the internal control-flow error into a user-facing one.
        error.FiberYielded => error.ContractViolation,
        else => e,
    };
}
```

Confirm `runtime.EvalContext` and `runtime.LispError` are exported from `src/runtime/mod.zig`:
Run: `grep -n "pub const EvalContext\|pub const LispError\|EvalContext =" src/runtime/mod.zig`
Expected: both are re-exported. If `EvalContext` is not re-exported, import it directly: `const EvalContext = @import("../runtime/eval.zig").EvalContext;`.

- [ ] **Step 4: Register the primitive**

In `src/prims/register.zig`, add the import near the other prim imports (around the `fiber_prims`/`hashtable_prims` lines):

```zig
const eval_prim = @import("eval_prim.zig");
```

And add the entry in the `make(...)` list (near the `apply`/`spawn` family):

```zig
    make("eval", 1, eval_prim.primEval),
```

- [ ] **Step 5: Run the Lisp smoke to verify it passes**

Run: `zig build run -- examples/eval-smoke.lisp`
Expected: prints `15` then `42`.

- [ ] **Step 6: Add a Zig regression test**

In `tests/runtime/prims_test.zig`, add a test mirroring the smoke using whatever VM-eval helper that file already uses for prim tests (search the file for an existing `evalString`-based helper and follow its pattern):

```zig
test "eval prim: data form -> callable -> result" {
    // Use this file's existing harness (e.g. evalToValue / runSource).
    const out = try evalToValue("(let ((n 5)) ((eval (list 'lambda '(x) (list '+ 'x n))) 10))");
    try std.testing.expectEqual(value_mod.fixnum(15), out);
}
```

Run: `zig build test 2>&1 | grep -A3 "eval prim"`
Expected: PASS. (If `prims_test.zig` has no reusable helper, write the smallest GC+VM bootstrap like the eval.zig tests above and call `ctx.evalString`.)

- [ ] **Step 7: Commit**

```bash
git add src/prims/eval_prim.zig src/prims/register.zig tests/runtime/prims_test.zig examples/eval-smoke.lisp
git commit -m "feat: add (eval form) primitive"
```

---

## Phase 2 — Portable hashtable

Tasks 2.1→2.3. One beads issue; suggested title: "portable hashtable: send maps (and JSON objects) across worker boundary".

### Task 2.1: vm-free `hashtable.putDistinct`

Deserialization rebuilds a table whose keys are already pairwise-distinct under `equal?` (the source table was deduped). So insertion needs no equality compare and no VM — only hash + linear probe to the first empty/tombstone slot. This avoids threading a VM into the portable copy/deserialize paths.

**Files:**
- Modify: `src/runtime/hashtable.zig`
- Test: `tests/runtime/hashtable_test.zig`

- [ ] **Step 1: Write the failing test**

In `tests/runtime/hashtable_test.zig` (follow its existing GC bootstrap pattern):

```zig
test "putDistinct: inserts distinct keys without a VM" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    const ht = try hashtable.make(&gc);
    const k1 = try runtime.makeString(&gc, "a");
    const k2 = try runtime.makeString(&gc, "b");
    try hashtable.putDistinct(&gc, ht, k1, value_mod.fixnum(1));
    try hashtable.putDistinct(&gc, ht, k2, value_mod.fixnum(2));
    try std.testing.expectEqual(@as(usize, 2), hashtable.size(ht));
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "putDistinct"`
Expected: FAIL — `putDistinct` not defined.

- [ ] **Step 3: Implement `putDistinct` + a vm-free distinct probe/rehash**

Add to `src/runtime/hashtable.zig` (alongside `set`):

```zig
// <issue-id>
// Linear-probe to the first NIL/TOMBSTONE slot. No equality compare — caller
// guarantees `key` is not already present. Returns the slot to write.
fn probeDistinct(back: Value, cap: usize, key_hash: u64) usize {
    var i: usize = @intCast(key_hash % @as(u64, @intCast(cap)));
    var steps: usize = 0;
    while (steps < cap) : (steps += 1) {
        const k = keyAt(back, i);
        if (k == value_mod.NIL or k == hash_mod.TOMBSTONE) return i;
        i = (i + 1) % cap;
    }
    return i; // full table — caller resizes before this can happen
}

fn rehashDistinct(gc: *GC, ht: Value, new_cap: usize) error{OutOfMemory}!void {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const ht_slot = scope.push(ht);
    const new_back = objects.makeVector(gc, new_cap * 2, value_mod.NIL) catch return error.OutOfMemory;
    const new_back_slot = scope.push(new_back);
    const old_back = backing(ht_slot.*);
    const old_cap = objects.vectorLen(old_back) / 2;
    var i: usize = 0;
    while (i < old_cap) : (i += 1) {
        const k = keyAt(old_back, i);
        if (k == value_mod.NIL or k == hash_mod.TOMBSTONE) continue;
        const v = valAt(old_back, i);
        const slot = probeDistinct(new_back_slot.*, new_cap, hash_mod.hashValue(k));
        setKeyAt(gc, new_back_slot.*, slot, k);
        setValAt(gc, new_back_slot.*, slot, v);
    }
    setBacking(gc, ht_slot.*, new_back_slot.*);
}

/// Insert a key known to be absent (e.g. when rebuilding a deduped table).
/// VM-free; never compares keys for equality.
pub fn putDistinct(gc: *GC, ht: Value, key: Value, val: Value) error{OutOfMemory}!void {
    if (key == value_mod.NIL) return; // NIL is the empty sentinel; skip defensively
    const cap_now = capacity(ht);
    const len_now = size(ht);
    if ((len_now + 1) * LOAD_DEN >= cap_now * LOAD_NUM) {
        try rehashDistinct(gc, ht, cap_now * 2);
    }
    const back = backing(ht);
    const slot = probeDistinct(back, capacity(ht), hash_mod.hashValue(key));
    setKeyAt(gc, back, slot, key);
    setValAt(gc, back, slot, val);
    setLen(ht, size(ht) + 1);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | grep -A3 "putDistinct"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/hashtable.zig tests/runtime/hashtable_test.zig
git commit -m "feat(hashtable): vm-free putDistinct for rebuilding deduped tables"
```

---

### Task 2.2: Make hashtables portable (check / copy / serialize / deserialize / free)

**Files:**
- Modify: `src/runtime/portable_value.zig`

- [ ] **Step 1: Write the failing roundtrip test**

Append to the test section of `src/runtime/portable_value.zig` (uses the same-GC `copyPortable` path; mirror the existing "roundtrip via self-copy" test's bootstrap):

```zig
test "portable: hashtable roundtrips with portable keys/values" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();

    const ht = try hashtable_mod.make(&gc);
    const k = try runtime.makeString(&gc, "limit");
    try hashtable_mod.putDistinct(&gc, ht, k, value_mod.fixnum(100));

    const copy = try copyPortable(ht, &gc, &syms, alloc);
    try std.testing.expect(copy != ht);                  // independent object
    try std.testing.expect(hashtable_mod.isHashTable(copy));
    try std.testing.expectEqual(@as(usize, 1), hashtable_mod.size(copy));
}

test "portable: hashtable with non-portable value is rejected" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    const ht = try hashtable_mod.make(&gc);
    const k = try runtime.makeString(&gc, "ch");
    // A foreign object (e.g. a channel) is non-portable.
    const foreign = try runtime.objects.makeForeign(&gc, undefined, null, 0xdead);
    try hashtable_mod.putDistinct(&gc, ht, k, foreign);
    try std.testing.expectError(error.NonPortableValue, checkPortable(ht, alloc));
}
```

Add the import at the top of the file if absent:
```zig
const hashtable_mod = @import("hashtable.zig");
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | grep -A3 "hashtable roundtrips\|hashtable with non-portable"`
Expected: FAIL — `checkPortable`/`copyValue` reject hashtables (hit the final `return error.NonPortableValue`).

- [ ] **Step 3: Add the `hash_table` variant to `ChannelValue`**

In the `ChannelValue` union (around `portable_value.zig:256`), add:

```zig
    hash_table: []Entry, // allocator-owned (key,value) pairs

    pub const Entry = struct { key: *ChannelValue, value: *ChannelValue };
```

- [ ] **Step 4: Extend `checkPortable`**

In the traversal loop in `checkPortable`, before the final `return error.NonPortableValue;`, add:

```zig
        if (runtime.isHashTable(cur)) {
            // Enqueue every key and value for portability checking.
            const Ctx = struct {
                stack: *std.ArrayListUnmanaged(Value),
                alloc: std.mem.Allocator,
                err: ?anyerror = null,
                fn visit(p: *anyopaque, k: Value, v: Value) void {
                    const s: *@This() = @ptrCast(@alignCast(p));
                    s.stack.append(s.alloc, k) catch |e| { s.err = e; };
                    s.stack.append(s.alloc, v) catch |e| { s.err = e; };
                }
            };
            var cb = Ctx{ .stack = &stack, .alloc = allocator };
            var cur_slot = cur;
            runtime.hashtableForEach(&cur_slot, &cb, Ctx.visit);
            if (cb.err) |e| return e;
            continue;
        }
```

Confirm `runtime.isHashTable` and a `runtime.hashtableForEach` are exported (the underlying functions are `hashtable.isHashTable` and `hashtable.forEach`). Add re-exports to `src/runtime/mod.zig` if missing:
```zig
pub const isHashTable = hashtable.isHashTable;
pub const hashtableForEach = hashtable.forEach;
```

- [ ] **Step 5: Extend `copyValue`**

Before the final `return error.NonPortableValue;` in `copyValue`:

```zig
    if (runtime.isHashTable(src)) {
        var scope = HandleScope{};
        dst_gc.roots.pushHandleScope(&scope);
        defer dst_gc.roots.popHandleScope();
        const dst_ht_slot = scope.push(try hashtable_mod.make(dst_gc));
        const Ctx = struct {
            dst_gc: *GC, dst_syms: *SymbolTable, ht_slot: *Value, err: ?anyerror = null,
            fn visit(p: *anyopaque, k: Value, v: Value) void {
                const s: *@This() = @ptrCast(@alignCast(p));
                if (s.err != null) return;
                const dk = copyValue(k, s.dst_gc, s.dst_syms) catch |e| { s.err = e; return; };
                const dv = copyValue(v, s.dst_gc, s.dst_syms) catch |e| { s.err = e; return; };
                hashtable_mod.putDistinct(s.dst_gc, s.ht_slot.*, dk, dv) catch |e| { s.err = e; };
            }
        };
        var cb = Ctx{ .dst_gc = dst_gc, .dst_syms = dst_syms, .ht_slot = dst_ht_slot };
        var src_slot = src;
        runtime.hashtableForEach(&src_slot, &cb, Ctx.visit);
        if (cb.err) |e| return e;
        return dst_ht_slot.*;
    }
```

- [ ] **Step 6: Extend `serializeToChannel`, `deserializeFromChannel`, `freeChannelValue`**

`serializeToChannel` — before the final `return error.NonPortableValue;`:

```zig
    if (runtime.isHashTable(val)) {
        var list = std.ArrayListUnmanaged(ChannelValue.Entry).empty;
        errdefer {
            for (list.items) |e| { freeChannelValue(e.key, alloc); freeChannelValue(e.value, alloc); }
            list.deinit(alloc);
        }
        const Ctx = struct {
            alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(ChannelValue.Entry), err: ?anyerror = null,
            fn visit(p: *anyopaque, k: Value, v: Value) void {
                const s: *@This() = @ptrCast(@alignCast(p));
                if (s.err != null) return;
                const ck = serializeToChannel(k, s.alloc) catch |e| { s.err = e; return; };
                const cvv = serializeToChannel(v, s.alloc) catch |e| { freeChannelValue(ck, s.alloc); s.err = e; return; };
                s.list.append(s.alloc, .{ .key = ck, .value = cvv }) catch |e| {
                    freeChannelValue(ck, s.alloc); freeChannelValue(cvv, s.alloc); s.err = e;
                };
            }
        };
        var cb = Ctx{ .alloc = alloc, .list = &list };
        var val_slot = val;
        runtime.hashtableForEach(&val_slot, &cb, Ctx.visit);
        if (cb.err) |e| { list.deinit(alloc); alloc.destroy(cv); return e; }
        cv.* = .{ .hash_table = try list.toOwnedSlice(alloc) };
        return cv;
    }
```

`deserializeFromChannel` — add a switch arm:

```zig
        .hash_table => |entries| blk: {
            var ht = try hashtable_mod.make(dst_gc);
            const prev_extra = dst_gc.roots.extra.items.len;
            try dst_gc.roots.extra.append(dst_gc.allocator, &ht);
            defer dst_gc.roots.extra.shrinkRetainingCapacity(prev_extra);
            for (entries) |e| {
                const k = try deserializeFromChannel(e.key, dst_gc, dst_syms);
                const v = try deserializeFromChannel(e.value, dst_gc, dst_syms);
                try hashtable_mod.putDistinct(dst_gc, ht, k, v);
            }
            break :blk ht;
        },
```

`freeChannelValue` — add a case mirroring `.vector`:

```zig
        .hash_table => |entries| {
            for (entries) |e| { freeChannelValue(e.key, alloc); freeChannelValue(e.value, alloc); }
            alloc.free(entries);
        },
```

- [ ] **Step 7: Run the tests**

Run: `zig build test 2>&1 | grep -A3 "hashtable roundtrips\|hashtable with non-portable"`
Expected: PASS for both.

- [ ] **Step 8: Run the whole suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/runtime/portable_value.zig src/runtime/mod.zig
git commit -m "feat(portable): hashtables are portable (JSON objects/maps cross workers)"
```

---

### Task 2.3: Lisp-level channel roundtrip for a hashtable

**Files:**
- Create: `examples/worker-hashtable-smoke.lisp`

- [ ] **Step 1: Write the smoke**

```scheme
;; Send a hashtable through a channel to a worker; worker reads a key.
(define ch (make-channel))
(define w
  (spawn-worker
    "(lambda (ch)
       (let ((cfg (channel-recv! ch)))
         (channel-send! ch (hash-get cfg \"limit\" 0))))"
    ch))
(define cfg (make-hash-table))
(hash-set! cfg "limit" 100)
(channel-send! ch cfg)
(display (channel-recv! ch))   ; expect 100
(newline)
```

- [ ] **Step 2: Run it**

Run: `zig build run -- examples/worker-hashtable-smoke.lisp`
Expected: prints `100`.

- [ ] **Step 3: Commit**

```bash
git add examples/worker-hashtable-smoke.lisp
git commit -m "test: hashtable crosses a worker channel boundary"
```

---

## Phase 3 — `spawn-worker` accepts a form

Tasks 3.1→3.2. One beads issue; suggested title: "spawn-worker accepts a portable form entry (keep string path)".

### Task 3.1: Form entry for `spawn-worker`

Today `spawn-worker` dupes a source string and the worker `evalString`s it. Add a parallel path: when arg 0 is not a string, serialize it as a portable form (c_allocator, cross-thread-safe), hand the `*ChannelValue` to the worker, which deserializes into its own heap and `evalForm`s it to the entry callable.

**Files:**
- Modify: `src/prims/worker_prims.zig` (`WorkerStart`, `primSpawnWorker`, `workerThread`)

- [ ] **Step 1: Add a serialized-form field to `WorkerStart`**

```zig
const WorkerStart = struct {
    code: ?[]const u8,                 // string entry (back-compat), or null
    form: ?*portable.ChannelValue,     // <issue-id> serialized form entry, or null
    channel_ptrs: []*Channel,
    n_channels: usize,
    allocator: std.mem.Allocator,
    worker: *WorkerState,
};
```

Add the import near the other imports:
```zig
const portable = @import("../runtime/portable_value.zig");
```

- [ ] **Step 2: Branch on the entry type in `primSpawnWorker`**

Replace the `code` setup in `primSpawnWorker` so a non-string arg 0 is serialized as a form (drop the early `if (!objects.isString(args[0])) return error.TypeError;`):

```zig
    var code: ?[]const u8 = null;
    var form: ?*portable.ChannelValue = null;
    if (objects.isString(args[0])) {
        code = alloc.dupe(u8, objects.stringBytes(args[0])) catch return error.OutOfMemory;
    } else {
        // <issue-id> portable form entry: serialize on the parent, rebuild
        // and compile in the worker. Closures are rejected here as elsewhere.
        form = portable.serializeToChannel(args[0], alloc) catch |e| switch (e) {
            error.NonPortableValue => return error.NonPortableValue,
            else => return error.OutOfMemory,
        };
    }
    errdefer { if (code) |c| alloc.free(c); if (form) |f| portable.freeChannelValue(f, alloc); }
```

Set both fields when building `start`:
```zig
    start.* = .{
        .code = code,
        .form = form,
        .channel_ptrs = channel_ptrs,
        .n_channels = n_channels,
        .allocator = alloc,
        .worker = ws,
    };
```

- [ ] **Step 3: Evaluate the right entry in `workerThread`**

Replace the `evalString` block with a branch that handles both. Keep the existing string path; add the form path:

```zig
    const fn_val = blk: {
        if (start_code) |c| {
            const v = ctx.evalString(c, "<worker>") catch { alloc.free(c); return; };
            alloc.free(c);
            break :blk v;
        } else if (start_form) |f| {
            defer portable.freeChannelValue(f, alloc);
            const entry_form = portable.deserializeFromChannel(f, ctx.vm.?.gc, ctx.vm.?.symbols) catch return;
            break :blk ctx.evalForm(entry_form) catch return;
        } else return;
    };
```

(`start_code`/`start_form` are the locals you already destructure from `start` at the top of `workerThread` — add `const start_form = start.form;` next to the existing `const code = start.code;`, renaming `code`→`start_code` consistently, or read `start.*` fields before `alloc.destroy(start)`.)

- [ ] **Step 4: Build the failing smoke**

Create `examples/worker-form-smoke.lisp`:

```scheme
;; spawn-worker with a FORM entry (built with quasiquote, value spliced in).
(define ch (make-channel))
(define base 1000)
(define w
  (spawn-worker
    `(lambda (ch) (channel-send! ch (+ ,base (channel-recv! ch))))
    ch))
(channel-send! ch 7)
(display (channel-recv! ch))   ; expect 1007
(newline)
```

- [ ] **Step 5: Run it (fails before Step 2–3 are in, passes after)**

Run: `zig build run -- examples/worker-form-smoke.lisp`
Expected: prints `1007`.

- [ ] **Step 6: Confirm the string path still works**

Run: `zig build run -- examples/worker-hashtable-smoke.lisp`
Expected: still prints `100` (back-compat intact).

- [ ] **Step 7: Run the full suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/prims/worker_prims.zig examples/worker-form-smoke.lisp
git commit -m "feat(worker): spawn-worker accepts a portable form entry"
```

---

### Task 3.2: Capture-by-value end-to-end example (documentation)

**Files:**
- Create: `examples/worker-closure-by-value.lisp`

- [ ] **Step 1: Write the example**

```scheme
;; Demonstrates passing "a closure by value" to a worker: author a form with
;; captured values spliced in via unquote, send it, worker compiles + runs it.
;; Note the quoting rule: a captured LIST must be quoted (',xs) so the worker
;; does not try to evaluate it as code.
(define ch (make-channel))
(define multiplier 3)
(define labels (list "a" "b" "c"))

(define w
  (spawn-worker
    `(lambda (ch)
       (let ((task (channel-recv! ch)))
         (channel-send! ch (eval task))))
    ch))

;; Build a task form with captured value (multiplier) and quoted list (labels).
(define task `(cons (* 14 ,multiplier) ',labels))   ; (cons (* 14 3) '("a" "b" "c"))
(channel-send! ch task)
(display (channel-recv! ch))   ; expect (42 "a" "b" "c")
(newline)
```

- [ ] **Step 2: Run it**

Run: `zig build run -- examples/worker-closure-by-value.lisp`
Expected: prints `(42 a b c)` (printed list form).

- [ ] **Step 3: Commit**

```bash
git add examples/worker-closure-by-value.lisp
git commit -m "docs: capture-by-value worker example via quasiquote + eval"
```

---

## Self-Review

**Spec coverage:**
- `(eval form)` primitive, sync-only, execFn path → Phase 1 (Tasks 1.1–1.3). ✓
- Re-entrancy via execFn / extracted compile helper → Task 1.1 + 1.2. ✓
- Portable hashtable (ChannelValue variant, check/copy/serialize/deserialize/free, default `equal?`, NIL-key) → Phase 2 (Tasks 2.1–2.2). ✓
- JSON objects → hashtables: covered transitively (JSON parser already yields hashtables; portability is the gap this closes). The existing `ffi/json.zig` is unchanged; no task needed. ✓
- `spawn-worker` accepts a form, string kept → Phase 3 (Task 3.1). ✓
- Error semantics (NonPortableValue for closures/foreign, FiberYielded normalized, NIL-key) → Tasks 1.3, 2.2, 3.1 tests. ✓
- Out-of-scope items (arbitrary live closures, custom hash/eq, eval-with-env, bytecode) → not implemented, by design. ✓

**Placeholder scan:** No TBD/TODO. Two spots intentionally say "follow this file's existing harness/bootstrap pattern" (prims_test.zig, hashtable_test.zig) because those test files' helpers must be matched, not invented — the asserted behavior and inputs are fully specified.

**Type consistency:** `compileFormToFnId` (Task 1.1) → used by `evalNonModuleForm` and `evalFormNested` (1.2); `evalFormNested` → called by `primEval` (1.3). `putDistinct` (2.1) → used by `copyValue`/`deserializeFromChannel`/serialize path (2.2). `ChannelValue.hash_table: []Entry` with `Entry{key,value}` is defined in 2.2 Step 3 and consumed consistently in serialize/deserialize/free. `WorkerStart.form: ?*portable.ChannelValue` (3.1) matches `serializeToChannel`/`deserializeFromChannel`/`freeChannelValue` signatures. Consistent.
