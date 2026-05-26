# GC Stress + Invariant Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catch generational-GC remembered-set bugs automatically by completing the GC invariant verifier and driving it with stress + seeded-soak harnesses.

**Architecture:** Finish `src/gc/verifier.zig` so it asserts three invariants (old→young remembered-set completeness, heap walkability, card_starts coverage) right after a `minor()` collection. Then build `tests/gc/stress.zig` (fast, CI) and `tests/gc/soak.zig` (heavy, opt-in) that churn every object layout shape through every GC phase, calling the verifier after each collection.

**Tech Stack:** Zig 0.16, `zig build` test steps. Binary built to `~/.local/bin/zepo` (not needed for these Zig-level tests).

---

## Reference: confirmed API surface (use these exact names)

**`zepo.gc` (`src/gc/mod.zig`) re-exports:** `GC`, `Nursery`, `OldGen`, `CardTable`, `RootSet`, `HandleScope`, `Verifier`, `MarkPhase`, and submodules `collector`, `nursery`, `oldgen`, `cards`, `roots`, `verifier`.

**`abi.value` (alias `value_mod`):**
- `pub const NIL: Value = 0x03;`
- `inline fn isPtr(v: Value) bool`
- `inline fn fixnum(n: i63) Value` / `fixnumVal(v) i63`
- `inline fn char(cp: u21) Value` / `charVal(v) u21`
- `inline fn ptrVal(v: Value) *ObjHeader` / `fromPtr(p: *ObjHeader) Value`

**`abi.header.ObjHeader` methods:** `init(k: Kind, sp: Space, layout_id: u16, sz_words: u35)`, `kind() Kind`, `space() Space`, `age() u4`, `marked() bool`, `setMark()`, `clearMark()`, `isForward() bool`, `sizeWords() u35`, `layoutDescId() u16`. Constants: `KIND_MASK`.

**`abi.Kind` (enum(u4)):** `pair=1, string=2, symbol=3, closure=4, prim=5, vector=6, box=7, float=8, env_frame=9, foreign=10, hash_table=11, bytevector=12`.

**`abi.layout`:** `layoutForKind(k) LayoutDesc`; `LayoutDesc { value_offsets: []const u16, value_slots_start: u16, all_slots_are_values: bool, ... }`.

**`GC` methods:** `init(alloc) !GC`, `deinit()`, `alloc(kind, body_words) !*ObjHeader`, `allocForeign(payload, deinit_fn, type_tag) !*ObjHeader`, `minor() !void`, `major() !void`, `markBegin() !void`, `markStep(budget) bool`, `sweepAndFinish()`, `writeBarrier(obj, field_ptr, new_val)`. Fields: `gc.nursery`, `gc.old_gen`, `gc.cards`, `gc.roots`.

**`OldGen`:** `alloc(body_words) ?*ObjHeader`, `allocWithCap(body_words) ?AllocResult` where `AllocResult{ hdr: *ObjHeader, actual_words: usize }`, `contains(ptr) bool`, `baseAddr() usize`, `walk(ctx, cb)`, fields `base`, `bump`, `card_starts: []?*ObjHeader`, `free_lists`.

**`CardTable`:** `cardIndexFor(addr) usize`, `markCard(addr)`, `isCardDirty(idx) bool`, `cardStart(idx) usize`, fields `table: []u8`, `heap_base`, `heap_size`.

**`nursery` module:** `NURSERY_SIZE`, `PROMOTE_AGE: u4 = 3`, `WORD: usize = 8`, `objectSizeBytes(h) usize`, `bodyPtr(h) [*]u64`, `Nursery.contains(ptr) bool`.

**`CARD_SIZE` (`cards.zig`):** `4096`. So a card holds 512 words.

**Body pointer pattern:** `const body: [*]Value = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + 8));`

**Test harness pattern (from `tests/gc/basic.zig`):** `const alloc = std.testing.allocator; var gc = try gcmod.GC.init(alloc); defer gc.deinit();` then `var scope = gcmod.HandleScope{}; gc.roots.pushHandleScope(&scope); defer gc.roots.popHandleScope();` Root a value with `const slot = scope.push(v);`.

---

## Task 0: Create the epic and child beads

**Files:** none (issue tracker only).

- [ ] **Step 1: Create the epic**

```bash
bd create --title="Comprehensive GC stress + invariant coverage" \
  --description="Finish verifier.zig (old->young remembered-set, heap walkability, card_starts coverage) and drive it with a fast stress matrix + seeded soak. Per docs/superpowers/specs/2026-05-26-gc-stress-coverage-design.md." \
  --type=epic --priority=1
```

- [ ] **Step 2: Create the four child beads (capture each printed ID)**

```bash
bd create --title="Strengthen GC verifier: 3 invariant checks" --description="Implement remembered-set completeness, heap walkability, card_starts coverage in src/gc/verifier.zig. TDD with deliberately-broken fixtures." --type=feature --priority=1
bd create --title="GC stress matrix tests/gc/stress.zig" --description="Object-type factory x scenario matrix (nursery churn, promotion, major sweep, spanning, old->young both ways). Verify after every collection. Wire into gc_test step." --type=feature --priority=2
bd create --title="GC seeded soak tests/gc/soak.zig + gc_soak step" --description="Randomized object graph driven by seeded std.Random; ZEPO_GC_SOAK_SEED/ITERS env. New opt-in gc_soak build step." --type=feature --priority=2
bd create --title="Triage GC bugs surfaced by strengthened verifier" --description="Each verifier failure against real code: root-cause (systematic-debugging), minimal repro, fix under its own bead. Stop-and-report each." --type=task --priority=1
```

- [ ] **Step 3: Wire dependencies (stress + soak depend on verifier; triage depends on stress + soak)**

```bash
# Replace <verifier> <stress> <soak> <triage> <epic> with the IDs printed above.
bd dep add <stress> <verifier>
bd dep add <soak> <verifier>
bd dep add <triage> <stress>
bd dep add <triage> <soak>
```

Note for later tasks: each contiguous block of new code gets a single `// <bead-id>` comment using the relevant child bead ID.

---

## Task 1: Verifier — old→young remembered-set completeness check

**Files:**
- Test: `tests/gc/verifier_test.zig` (create)
- Modify: `src/gc/verifier.zig`
- Modify: `build.zig` (register the new test module)

- [ ] **Step 1: Claim the bead and branch**

```bash
bd update <verifier> --claim
git checkout -b <verifier>
```

- [ ] **Step 2: Write the failing test**

Create `tests/gc/verifier_test.zig`:

```zig
//! Tests that the GC invariant verifier actually rejects broken heaps.
//! Each test deliberately constructs an invariant violation and asserts the
//! verifier returns the matching error — proving the checks have teeth.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;

const WORD: usize = 8;

fn body(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

test "verifier rejects old->young edge on a clean card" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    // Old-gen pair, slots NIL for now.
    const old_h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    old_h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const ob = body(old_h);
    ob[0] = value_mod.NIL;
    ob[1] = value_mod.NIL;

    // Young pair in the nursery.
    const young_h = try gc.alloc(.pair, 2);
    const yb = body(young_h);
    yb[0] = value_mod.fixnum(7);
    yb[1] = value_mod.NIL;

    // Store the young pointer into the old object WITHOUT the write barrier,
    // so the card stays clean — exactly the corruption zepo-jus produced.
    ob[1] = value_mod.fromPtr(young_h);

    try std.testing.expectError(
        gcmod.verifier.VerifyError.UnmarkedOldYoungEdge,
        gcmod.Verifier.verify(&gc),
    );
}

test "verifier passes when the old->young edge's card is dirty" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    const old_h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    old_h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const ob = body(old_h);
    ob[0] = value_mod.NIL;
    ob[1] = value_mod.NIL;

    const young_h = try gc.alloc(.pair, 2);
    const yb = body(young_h);
    yb[0] = value_mod.fixnum(7);
    yb[1] = value_mod.NIL;

    const young_val = value_mod.fromPtr(young_h);
    gc.writeBarrier(old_h, &ob[1], young_val); // marks the card
    ob[1] = young_val;

    try gcmod.Verifier.verify(&gc); // must NOT error
}
```

- [ ] **Step 3: Register the test module in `build.zig`**

In `build.zig`, after the existing GC test modules (search for `gc_wb_mod` / the block ending around line 87), add:

```zig
    const gc_verifier_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/verifier_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gc_verifier_mod.addImport("zepo", mod);
    const gc_verifier_tests = b.addTest(.{ .root_module = gc_verifier_mod });
    const run_gc_verifier_tests = b.addRunArtifact(gc_verifier_tests);
    gc_test_step.dependOn(&run_gc_verifier_tests.step);
```

(Match the exact `.createModule`/`addImport` shape used by the adjacent `gc_wb_mod` block — copy its options if they differ from the above.)

- [ ] **Step 4: Run the test to verify it fails**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: FAIL — first test errors because `VerifyError.UnmarkedOldYoungEdge` does not exist yet (compile error) or, once the enum is added, because `verify` does not return it.

- [ ] **Step 5: Implement the check in `src/gc/verifier.zig`**

Add the new error variants to `VerifyError`:

```zig
pub const VerifyError = error{
    DanglingPointer,
    ReachableFromSpaceObject,
    UnmarkedOldYoungEdge,
    HeapNotWalkable,
    CardStartMissing,
};
```

Add a `WORD` const near the imports:

```zig
const WORD: usize = 8;
```

Replace the body of `Verifier.verify` so it runs the existing root scan AND the new old-gen walk:

```zig
pub const Verifier = struct {
    pub fn verify(gc: *GC) !void {
        var ctx = Ctx{ .gc = gc };
        gc.roots.visitAll(@ptrCast(&ctx), visitSlot);
        if (ctx.err) |e| return e;

        // Walk every live old-gen block. For each Value slot that points into
        // the nursery, the card covering THAT SLOT must be dirty — otherwise
        // the next minor GC cannot find the edge (zepo-jus / spanning-card).
        try verifyOldGen(gc);
    }

    fn verifyOldGen(gc: *GC) !void {
        const og = &gc.old_gen;
        var p: [*]u8 = og.base;
        while (@intFromPtr(p) < @intFromPtr(og.bump)) {
            const h: *ObjHeader = @ptrCast(@alignCast(p));
            const body_words: usize = @intCast(h.sizeWords());
            if (body_words == 0) return VerifyError.HeapNotWalkable;
            const block_bytes = WORD + body_words * WORD;
            const is_free = @intFromEnum(h.kind()) == 0;
            if (!is_free) {
                try checkSlots(gc, h, body_words);
            }
            p = @ptrFromInt(@intFromPtr(p) + block_bytes);
        }
        // Walk must land exactly on bump, or a sizeWords was wrong.
        if (@intFromPtr(p) != @intFromPtr(og.bump)) return VerifyError.HeapNotWalkable;
    }

    fn checkSlots(gc: *GC, h: *ObjHeader, body_words: usize) !void {
        const desc = layout_mod.layoutForKind(h.kind());
        const body: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
        for (desc.value_offsets) |off| {
            if (off < body_words) try checkSlot(gc, &body[off]);
        }
        if (desc.all_slots_are_values) {
            var i: usize = desc.value_slots_start;
            while (i < body_words) : (i += 1) try checkSlot(gc, &body[i]);
        }
    }

    fn checkSlot(gc: *GC, slot: *u64) !void {
        const v: Value = @bitCast(slot.*);
        if (!value_mod.isPtr(v)) return;
        const tgt = value_mod.ptrVal(v);
        if (!gc.nursery.contains(tgt)) return; // old->old edge: not our concern
        const slot_addr = @intFromPtr(slot);
        const idx = gc.cards.cardIndexFor(slot_addr);
        if (!gc.cards.isCardDirty(idx)) return VerifyError.UnmarkedOldYoungEdge;
    }
};
```

Add the needed imports at the top of `verifier.zig` if missing: `const layout_mod = abi.layout;` and `const value_mod = abi.value;` (the file already imports `abi`).

- [ ] **Step 6: Run the test to verify it passes**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: PASS — both verifier_test cases pass, and the pre-existing GC tests still pass.

- [ ] **Step 7: Commit**

```bash
git add tests/gc/verifier_test.zig src/gc/verifier.zig build.zig
git commit -m "feat(<verifier>): verifier checks old->young remembered-set completeness

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Verifier — heap walkability fixture

**Files:**
- Modify: `tests/gc/verifier_test.zig`

The walkability check (`HeapNotWalkable`) was implemented in Task 1; this task proves it has teeth with a dedicated fixture.

- [ ] **Step 1: Write the failing test**

Append to `tests/gc/verifier_test.zig`:

```zig
test "verifier rejects a corrupted (zero-size) old-gen header" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    const h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const b = body(h);
    b[0] = value_mod.NIL;
    b[1] = value_mod.NIL;

    // Corrupt the size field to 0 — the heap walker would stall here.
    h.word = (h.word & ~abi.header.ObjHeader.SIZE_MASK);

    try std.testing.expectError(
        gcmod.verifier.VerifyError.HeapNotWalkable,
        gcmod.Verifier.verify(&gc),
    );
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: PASS (the check from Task 1 catches the zero-size header).

If it does NOT pass, confirm `SIZE_MASK` is `pub` in `src/abi/header.zig` (it is, line ~55) and that `body_words == 0` is checked before computing `block_bytes` in `verifyOldGen`.

- [ ] **Step 3: Commit**

```bash
git add tests/gc/verifier_test.zig
git commit -m "test(<verifier>): heap-walkability fixture rejects zero-size header

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Verifier — card_starts coverage check

**Files:**
- Modify: `src/gc/verifier.zig`
- Modify: `tests/gc/verifier_test.zig`

- [ ] **Step 1: Write the failing test**

Append to `tests/gc/verifier_test.zig`:

```zig
test "verifier rejects a dirty card with no card_starts entry" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    // Allocate one old-gen object so the heap is non-empty and walkable.
    const h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    const b = body(h);
    b[0] = value_mod.NIL;
    b[1] = value_mod.NIL;

    // Dirty a far-away card that no object covers, and ensure its card_starts
    // entry is null — exactly the spanning-card gap (zepo-gol).
    const far_idx: usize = 3; // a card past the single small object
    gc.cards.table[far_idx] = 1;
    gc.old_gen.card_starts[far_idx] = null;

    try std.testing.expectError(
        gcmod.verifier.VerifyError.CardStartMissing,
        gcmod.Verifier.verify(&gc),
    );
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: FAIL — `verify` does not yet return `CardStartMissing` (it returns void / passes).

- [ ] **Step 3: Implement the card_starts coverage check**

In `src/gc/verifier.zig`, extend `verify` to call a new `verifyCardStarts` after `verifyOldGen`:

```zig
    pub fn verify(gc: *GC) !void {
        var ctx = Ctx{ .gc = gc };
        gc.roots.visitAll(@ptrCast(&ctx), visitSlot);
        if (ctx.err) |e| return e;
        try verifyOldGen(gc);
        try verifyCardStarts(gc);
    }

    // Every dirty card must name a covering object in card_starts, and that
    // object must actually span the card's start address. A dirty card with a
    // null start means a minor GC would skip the card and lose its edges.
    fn verifyCardStarts(gc: *GC) !void {
        const og = &gc.old_gen;
        var idx: usize = 0;
        while (idx < gc.cards.table.len) : (idx += 1) {
            if (!gc.cards.isCardDirty(idx)) continue;
            const start = og.card_starts[idx] orelse return VerifyError.CardStartMissing;
            if (!og.contains(start)) return VerifyError.CardStartMissing;
            const sw: usize = @intCast(start.sizeWords());
            if (sw == 0) return VerifyError.CardStartMissing;
            const block_end = @intFromPtr(start) + WORD + sw * WORD;
            const card_begin = gc.cards.cardStart(idx);
            // The covering object must start at or before the card and extend
            // into it.
            if (@intFromPtr(start) > card_begin or block_end <= card_begin)
                return VerifyError.CardStartMissing;
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: PASS — all four verifier_test cases pass, all pre-existing GC tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/gc/verifier.zig tests/gc/verifier_test.zig
git commit -m "feat(<verifier>): verifier checks dirty cards have a covering card_starts entry

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Merge the verifier bead**

```bash
zig build gc_test 2>&1 | tail -5     # confirm green
git checkout master && git merge --no-ff <verifier> -m "merge <verifier>: strengthened GC verifier"
git branch -d <verifier>
bd close <verifier> --reason="verifier now asserts remembered-set completeness, heap walkability, card_starts coverage; all three proven by RED fixtures"
```

---

## Task 4: stress.zig — object factory + pair/vector scenarios

**Files:**
- Test: `tests/gc/stress.zig` (create)
- Modify: `build.zig`

- [ ] **Step 1: Claim the bead and branch**

```bash
bd update <stress> --claim
git checkout -b <stress>
```

- [ ] **Step 2: Write the factory + first scenarios (this IS the test file)**

Create `tests/gc/stress.zig`:

```zig
//! GC stress matrix: every object layout shape x every GC phase, with the
//! invariant verifier asserted after every collection. Fast enough for CI.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;
const WORD: usize = 8;

fn bodyP(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

// ── factory: one builder per layout shape ──────────────────────────────────

fn makePair(gc: *gcmod.GC, car: Value, cdr: Value) !Value {
    const h = try gc.alloc(.pair, 2);
    const b = bodyP(h);
    b[0] = car;
    b[1] = cdr;
    return value_mod.fromPtr(h);
}

// Vector: body[0] = length (raw), body[1..1+len] = Value slots.
fn makeVector(gc: *gcmod.GC, len: usize, fill: Value) !Value {
    const h = try gc.alloc(.vector, 1 + len);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = @as(u64, len);
    var i: usize = 0;
    while (i < len) : (i += 1) bodyP(h)[1 + i] = fill;
    return value_mod.fromPtr(h);
}

fn vecRef(v: Value, i: usize) Value {
    return bodyP(value_mod.ptrVal(v))[1 + i];
}

test "stress: pair nursery churn — verify after each minor" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const keep = scope.push(try makePair(&gc, value_mod.fixnum(1), value_mod.fixnum(2)));

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var i: i63 = 0;
        while (i < 2000) : (i += 1) {
            _ = try makePair(&gc, value_mod.fixnum(i), value_mod.NIL);
        }
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    // Rooted pair intact.
    const b = bodyP(value_mod.ptrVal(keep.*));
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(b[0]));
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(b[1]));
}

test "stress: vector of rooted pairs survives minor + major" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Vector with 8 NIL slots, rooted.
    const vec = scope.push(try makeVector(&gc, 8, value_mod.NIL));

    // Fill each slot with a fresh pair (young), via write barrier in case the
    // vector promoted. Re-fetch the header each time (it may have moved).
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const p = try makePair(&gc, value_mod.fixnum(@intCast(i)), value_mod.NIL);
        const vh = value_mod.ptrVal(vec.*);
        gc.writeBarrier(vh, &bodyP(vh)[1 + i], p);
        bodyP(vh)[1 + i] = p;
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    try gc.major();
    try gcmod.Verifier.verify(&gc);

    // Every slot still references a pair with the right car.
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const e = vecRef(vec.*, k);
        try std.testing.expect(value_mod.isPtr(e));
        try std.testing.expectEqual(@as(i63, @intCast(k)), value_mod.fixnumVal(bodyP(value_mod.ptrVal(e))[0]));
    }
}
```

- [ ] **Step 3: Register `tests/gc/stress.zig` in `build.zig`**

After the `gc_verifier_mod` block from Task 1, add:

```zig
    const gc_stress_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/stress.zig"),
        .target = target,
        .optimize = optimize,
    });
    gc_stress_mod.addImport("zepo", mod);
    const gc_stress_tests = b.addTest(.{ .root_module = gc_stress_mod });
    const run_gc_stress_tests = b.addRunArtifact(gc_stress_tests);
    gc_test_step.dependOn(&run_gc_stress_tests.step);
```

- [ ] **Step 4: Run the tests**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: PASS. **If the verifier fires here, STOP** — it has found a real bug. Follow Task 8's triage gate before continuing.

- [ ] **Step 5: Commit**

```bash
git add tests/gc/stress.zig build.zig
git commit -m "test(<stress>): GC stress factory + pair/vector churn scenarios

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: stress.zig — remaining layout shapes

**Files:**
- Modify: `tests/gc/stress.zig`

- [ ] **Step 1: Add builders for the remaining shapes**

Append these builders to the factory section of `tests/gc/stress.zig`:

```zig
// String: body[0] = byte length (raw), raw byte tail. Leaf (no Value slots).
fn makeString(gc: *gcmod.GC, bytes: []const u8) !Value {
    const tail_words = (bytes.len + WORD - 1) / WORD;
    const h = try gc.alloc(.string, 1 + tail_words);
    const raw: [*]u8 = @as([*]u8, @ptrCast(h)) + WORD;
    const lenp: *u64 = @ptrCast(@alignCast(raw));
    lenp.* = @as(u64, bytes.len);
    if (bytes.len > 0) @memcpy((raw + WORD)[0..bytes.len], bytes);
    return value_mod.fromPtr(h);
}

// Box: single Value at body[0].
fn makeBox(gc: *gcmod.GC, v: Value) !Value {
    const h = try gc.alloc(.box, 1);
    bodyP(h)[0] = v;
    return value_mod.fromPtr(h);
}

// Closure: body[0..3] raw header words, captures (Values) from body[3].
fn makeClosure(gc: *gcmod.GC, captures: []const Value) !Value {
    const h = try gc.alloc(.closure, 3 + captures.len);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = 0; // code_ptr (raw, unused in test)
    raw[1] = 0; // arity (raw)
    raw[2] = 0; // home_env_ptr (raw)
    var i: usize = 0;
    while (i < captures.len) : (i += 1) bodyP(h)[3 + i] = captures[i];
    return value_mod.fromPtr(h);
}

// Hash table: body[0] = len (raw), body[1] = backing vector (Value).
fn makeHashTable(gc: *gcmod.GC, backing: Value) !Value {
    const h = try gc.alloc(.hash_table, 2);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = 0; // len (raw)
    bodyP(h)[1] = backing;
    return value_mod.fromPtr(h);
}

// Float: body[0] = raw f64. Leaf.
fn makeFloat(gc: *gcmod.GC, f: f64) !Value {
    const h = try gc.alloc(.float, 1);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = @as(u64, @bitCast(f));
    return value_mod.fromPtr(h);
}

const FreeCount = struct {
    var n: usize = 0;
    fn deinit(_: ?*anyopaque) callconv(.c) void {
        n += 1;
    }
};
```

- [ ] **Step 2: Add the scenario test covering all shapes**

Append to `tests/gc/stress.zig`:

```zig
test "stress: every layout shape survives promotion + major" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // Build one of each shape, all rooted. A hash table needs a backing
    // vector; build that first and root it too.
    const backing = scope.push(try makeVector(&gc, 4, value_mod.fixnum(0)));
    _ = scope.push(try makePair(&gc, value_mod.fixnum(10), value_mod.fixnum(20)));
    _ = scope.push(try makeString(&gc, "hello generational world"));
    _ = scope.push(try makeBox(&gc, value_mod.fixnum(99)));
    _ = scope.push(try makeClosure(&gc, &.{ value_mod.fixnum(1), value_mod.fixnum(2) }));
    _ = scope.push(try makeHashTable(&gc, backing.*));
    _ = scope.push(try makeFloat(&gc, 3.14159));
    _ = scope.push(try gc.allocForeignValue());

    // Age them past PROMOTE_AGE so they all promote to old-gen.
    var n: usize = 0;
    while (n < gcmod.nursery.PROMOTE_AGE + 1) : (n += 1) {
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    try gc.major();
    try gcmod.Verifier.verify(&gc);

    // String content intact after promotion (sanity that raw tails copy).
    // The string is the 3rd handle pushed (index 2).
    const sv = scope.handles[2];
    const raw: [*]u8 = @as([*]u8, @ptrCast(value_mod.ptrVal(sv))) + WORD;
    const lenp: *u64 = @ptrCast(@alignCast(raw));
    try std.testing.expectEqual(@as(u64, 24), lenp.*); // "hello generational world" = 24 bytes
}
```

Note: `gc.allocForeignValue()` does not exist — replace that line with a foreign allocation that returns a `Value`. Add this helper to the factory section:

```zig
// Foreign handle wrapped as a Value, with a counting finalizer.
fn makeForeign(gc: *gcmod.GC) !Value {
    const h = try gc.allocForeign(null, FreeCount.deinit, 0xF00D);
    return value_mod.fromPtr(h);
}
```

and replace `try gc.allocForeignValue()` with `try makeForeign(&gc)`.

- [ ] **Step 3: Run the tests**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: PASS. **If the verifier fires, STOP and run Task 8's triage gate.**

- [ ] **Step 4: Commit**

```bash
git add tests/gc/stress.zig
git commit -m "test(<stress>): cover string/box/closure/hashtable/float/foreign shapes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: stress.zig — multi-card spanning + old→young both ways

**Files:**
- Modify: `tests/gc/stress.zig`

- [ ] **Step 1: Write the spanning + edge tests**

Append to `tests/gc/stress.zig`:

```zig
test "stress: large old-gen vector spanning >1 card keeps a young edge in a later card" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // A 1000-slot vector body = 1 (len) + 1000 = 1001 words = ~8 KB, spanning
    // at least 2 cards (card = 512 words). Allocate it directly in old-gen via
    // the large-object path so recordCardStart's spanning logic is exercised.
    const len: usize = 1000;
    const r = gc.old_gen.allocWithCap(1 + len) orelse return error.TestUnexpected;
    const vh = r.hdr;
    vh.* = ObjHeader.init(.vector, .old_gen, @intFromEnum(Kind.vector), @intCast(r.actual_words));
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(vh)) + WORD));
    raw[0] = @as(u64, len);
    var i: usize = 0;
    while (i < len) : (i += 1) bodyP(vh)[1 + i] = value_mod.NIL;
    _ = scope.push(value_mod.fromPtr(vh));

    // Slot index 700 lives at byte offset 8 + 700*8 = 5608 — past the first
    // 4096-byte card, i.e. in card 1+. Store a YOUNG pair there via the write
    // barrier. The young pair is NOT otherwise rooted: only this edge keeps it.
    const young = try makePair(&gc, value_mod.fixnum(4242), value_mod.NIL);
    const slot_idx: usize = 700;
    gc.writeBarrier(vh, &bodyP(vh)[1 + slot_idx], young);
    bodyP(vh)[1 + slot_idx] = young;

    // The slot's card must be dirty (sanity for the test itself).
    const slot_addr = @intFromPtr(&bodyP(vh)[1 + slot_idx]);
    try std.testing.expect(gc.cards.isCardDirty(gc.cards.cardIndexFor(slot_addr)));

    // Minor GC: the young pair must survive via the spanning remembered set.
    try gc.minor();
    try gcmod.Verifier.verify(&gc);

    const e = bodyP(vh)[1 + slot_idx];
    try std.testing.expect(value_mod.isPtr(e));
    try std.testing.expectEqual(@as(i63, 4242), value_mod.fixnumVal(bodyP(value_mod.ptrVal(e))[0]));
}

test "stress: old->young edge created by PROMOTION survives the same collection" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    // A = (1 . NIL), rooted, aged to PROMOTE_AGE so the NEXT minor promotes it.
    const a = scope.push(try makePair(&gc, value_mod.fixnum(1), value_mod.NIL));
    var n: usize = 0;
    while (n < gcmod.nursery.PROMOTE_AGE) : (n += 1) {
        try gc.minor();
        try gcmod.Verifier.verify(&gc);
    }

    // Build young B = (2 . NIL) and attach A.cdr = B. A is still young here, so
    // no write barrier needed. On the next minor, A promotes to old-gen while B
    // stays young — the COLLECTOR creates the old->young edge (zepo-jus).
    const b = try makePair(&gc, value_mod.fixnum(2), value_mod.NIL);
    bodyP(value_mod.ptrVal(a.*))[1] = b;

    try gc.minor();
    try gcmod.Verifier.verify(&gc);

    // A is old, B reachable from A with car=2.
    try std.testing.expect(gc.old_gen.contains(value_mod.ptrVal(a.*)));
    const b_from_a = bodyP(value_mod.ptrVal(a.*))[1];
    try std.testing.expect(value_mod.isPtr(b_from_a));
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(bodyP(value_mod.ptrVal(b_from_a))[0]));
}
```

- [ ] **Step 2: Run the tests**

Run: `zig build gc_test 2>&1 | tail -30`
Expected: PASS. These two reproduce the exact zepo-gol (spanning) and zepo-jus (promotion edge) scenarios; if either fails, the strengthened verifier or the fix regressed — STOP and run Task 8's triage gate.

- [ ] **Step 3: Commit and merge the stress bead**

```bash
git add tests/gc/stress.zig
git commit -m "test(<stress>): multi-card spanning + old->young via write-barrier and promotion

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
zig build gc_test 2>&1 | tail -5     # confirm green
git checkout master && git merge --no-ff <stress> -m "merge <stress>: GC stress matrix"
git branch -d <stress>
bd close <stress> --reason="stress matrix covers all layout shapes x {nursery,promote,major,spanning,old->young both ways}, verifier-checked"
```

---

## Task 7: soak.zig — seeded randomized soak + gc_soak build step

**Files:**
- Test: `tests/gc/soak.zig` (create)
- Modify: `build.zig`

- [ ] **Step 1: Claim the bead and branch**

```bash
bd update <soak> --claim
git checkout -b <soak>
```

- [ ] **Step 2: Write the soak**

Create `tests/gc/soak.zig`:

```zig
//! Seeded randomized GC soak. Drives a randomized object graph through random
//! allocation / mutation / root-drop / collection, asserting the invariant
//! verifier after every collection. Reproducible: a failure prints its seed.
//!
//! Tunables (env):
//!   ZEPO_GC_SOAK_SEED   default 0x5EED
//!   ZEPO_GC_SOAK_ITERS  default 200_000
//!
//! Run: zig build gc_soak

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;
const WORD: usize = 8;

fn bodyP(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

fn envU64(name: []const u8, default: u64) u64 {
    const v = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u64, v, 0) catch default;
}

const POP = 256; // rooted population size

test "soak: randomized graph stays invariant-clean" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    const seed = envU64("ZEPO_GC_SOAK_SEED", 0x5EED);
    const iters = envU64("ZEPO_GC_SOAK_ITERS", 200_000);
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    // Rooted population: a vector of POP slots, each holding an object (or NIL).
    // The vector itself is rooted via a handle, so all slots are reachable.
    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const pop_h = try gc.alloc(.vector, 1 + POP);
    {
        const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(pop_h)) + WORD));
        raw[0] = @as(u64, POP);
        var i: usize = 0;
        while (i < POP) : (i += 1) bodyP(pop_h)[1 + i] = value_mod.NIL;
    }
    const pop = scope.push(value_mod.fromPtr(pop_h));

    var it: u64 = 0;
    while (it < iters) : (it += 1) {
        const slot_idx = rng.uintLessThan(usize, POP);
        const action = rng.uintLessThan(u8, 10);

        // The population vector may have promoted; re-fetch its header each
        // iteration and use the write barrier for every store into it.
        const vh = value_mod.ptrVal(pop.*);

        switch (action) {
            0, 1, 2, 3 => {
                // Allocate a fresh small object and store it into a slot.
                const k = rng.uintLessThan(u8, 3);
                const nv = switch (k) {
                    0 => try makePair(&gc, value_mod.fixnum(@intCast(it & 0xffff)), value_mod.NIL),
                    1 => try makeVecSmall(&gc, rng),
                    else => try makeBox(&gc, value_mod.fixnum(@intCast(slot_idx))),
                };
                const vh2 = value_mod.ptrVal(pop.*); // alloc may have collected/moved
                gc.writeBarrier(vh2, &bodyP(vh2)[1 + slot_idx], nv);
                bodyP(vh2)[1 + slot_idx] = nv;
            },
            4 => {
                // Drop a root.
                gc.writeBarrier(vh, &bodyP(vh)[1 + slot_idx], value_mod.NIL);
                bodyP(vh)[1 + slot_idx] = value_mod.NIL;
            },
            5, 6, 7 => {
                // Mutate: point one slot's pair.cdr at another slot's object.
                const e = bodyP(vh)[1 + slot_idx];
                if (value_mod.isPtr(e) and value_mod.ptrVal(e).kind() == .pair) {
                    const other = bodyP(vh)[1 + rng.uintLessThan(usize, POP)];
                    const eh = value_mod.ptrVal(e);
                    gc.writeBarrier(eh, &bodyP(eh)[1], other);
                    bodyP(eh)[1] = other;
                }
            },
            8 => {
                try gc.minor();
                try gcmod.Verifier.verify(&gc);
            },
            else => {
                try gc.major();
                try gcmod.Verifier.verify(&gc);
            },
        }
    }

    // Final collection + verify.
    try gc.major();
    gcmod.Verifier.verify(&gc) catch |e| {
        std.debug.print("\nSOAK FAILED with seed=0x{x} iters={d}: {s}\n", .{ seed, iters, @errorName(e) });
        return e;
    };
}

fn makePair(gc: *gcmod.GC, car: Value, cdr: Value) !Value {
    const h = try gc.alloc(.pair, 2);
    bodyP(h)[0] = car;
    bodyP(h)[1] = cdr;
    return value_mod.fromPtr(h);
}

fn makeBox(gc: *gcmod.GC, v: Value) !Value {
    const h = try gc.alloc(.box, 1);
    bodyP(h)[0] = v;
    return value_mod.fromPtr(h);
}

fn makeVecSmall(gc: *gcmod.GC, rng: std.Random) !Value {
    const len = 1 + rng.uintLessThan(usize, 8);
    const h = try gc.alloc(.vector, 1 + len);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = @as(u64, len);
    var i: usize = 0;
    while (i < len) : (i += 1) bodyP(h)[1 + i] = value_mod.NIL;
    return value_mod.fromPtr(h);
}
```

Note: if `Verifier.verify` is asserted inside the loop on every action 8/9 and that proves too slow at 200k iters, the seed-printing wrapper on the final verify still catches accumulated corruption; the per-collection verify is the primary signal and should stay.

- [ ] **Step 3: Add the `gc_soak` build step in `build.zig`**

After the GC test wiring, add a NEW top-level step that does NOT hook into `gc_test`:

```zig
    const gc_soak_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/soak.zig"),
        .target = target,
        .optimize = optimize,
    });
    gc_soak_mod.addImport("zepo", mod);
    const gc_soak_tests = b.addTest(.{ .root_module = gc_soak_mod });
    const run_gc_soak_tests = b.addRunArtifact(gc_soak_tests);
    const gc_soak_step = b.step("gc_soak", "Run the heavy randomized GC soak (opt-in)");
    gc_soak_step.dependOn(&run_gc_soak_tests.step);
```

- [ ] **Step 4: Run a short soak to verify it builds and passes**

Run: `ZEPO_GC_SOAK_ITERS=5000 zig build gc_soak 2>&1 | tail -30`
Expected: PASS, no verifier failure. **If it fails, it prints a seed — STOP and run Task 8's triage gate using that seed.**

- [ ] **Step 5: Run the full default soak**

Run: `zig build gc_soak 2>&1 | tail -30`
Expected: PASS. (If slow, it is opt-in and not in CI; that is acceptable.)

- [ ] **Step 6: Commit and merge the soak bead**

```bash
git add tests/gc/soak.zig build.zig
git commit -m "test(<soak>): seeded randomized GC soak + gc_soak build step

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git checkout master && git merge --no-ff <soak> -m "merge <soak>: GC soak"
git branch -d <soak>
bd close <soak> --reason="seeded randomized soak driving alloc/mutate/drop/collect with per-collection verify; reproducible via ZEPO_GC_SOAK_SEED"
```

---

## Task 8: Triage gate — handle any real bug the verifier surfaces

**This task runs whenever Task 4, 5, 6, or 7 reports a verifier failure against real code.** It is not a normal sequential task; it is the protocol for the "stop and report each" decision.

**Files:** depends on the bug.

- [ ] **Step 1: STOP. Do not continue the failing task.**

The verifier returned `UnmarkedOldYoungEdge`, `HeapNotWalkable`, or `CardStartMissing` against real GC behavior (not a deliberate fixture). This is a genuine bug — the whole point of the exercise.

- [ ] **Step 2: Capture a deterministic repro**

For a soak failure, record the printed seed and reproduce with:

```bash
ZEPO_GC_SOAK_SEED=<printed-seed> ZEPO_GC_SOAK_ITERS=<value> zig build gc_soak 2>&1 | tail -40
```

For a stress failure, the failing test name is already deterministic.

- [ ] **Step 3: Create a bug bead and branch**

```bash
bd create --title="GC bug: <error> in <scenario>" --description="Verifier <error> reproduced by <test/seed>. Root-cause per systematic-debugging." --type=bug --priority=0
bd update <bug> --claim
git checkout -b <bug>
```

- [ ] **Step 4: Root-cause using superpowers:systematic-debugging**

Do NOT guess-fix. Read the error, trace the data flow backward (which slot, which card, which collection phase), find the working-vs-broken difference, form ONE hypothesis, test it minimally.

- [ ] **Step 5: Report the finding to the user before fixing**

Per the approved "stop and report each" decision: summarize the bug (what invariant broke, the root cause, the minimal repro) to the user, then fix under the bug bead with a focused regression test added to `tests/gc/` (ideally a tiny deterministic test, not the whole soak).

- [ ] **Step 6: Fix, verify, merge, close**

```bash
zig build gc_test 2>&1 | tail -5      # green, including the new regression test
git add -A && git commit -m "fix(<bug>): <root cause one-liner>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git checkout master && git merge --no-ff <bug> -m "merge <bug>: <root cause>"
git branch -d <bug>
bd close <bug> --reason="<root cause + fix>"
```

- [ ] **Step 7: Resume the interrupted task** from its failing step.

---

## Session close

After the last bead merges:

```bash
git status                 # clean working tree (besides pre-existing untracked main.rs, examples/orch-readme.md)
zig build gc_test 2>&1 | tail -5    # all GC tests green
bd list --status=open      # the epic + triage may remain; close the epic when satisfied
git push
bd close <epic> --reason="verifier strengthened + stress matrix + soak in place; <N> real bugs found and fixed"
```
