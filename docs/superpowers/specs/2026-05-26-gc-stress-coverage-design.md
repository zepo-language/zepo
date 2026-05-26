# Comprehensive GC Stress + Invariant Coverage

**Date:** 2026-05-26
**Status:** Approved design, pending implementation
**Goal:** Stop GC bugs from sneaking up by asserting GC invariants continuously
under heavy, randomized heap pressure — not by measuring line coverage.

## Problem

Three generational-GC remembered-set bugs shipped this month (zepo-jus,
zepo-gol ×2) despite ~25 existing tests in `tests/gc/`. Root cause of the
coverage gap: the tests *churn* the heap but nothing *asserts the invariant
the bugs broke*. `src/gc/verifier.zig` was meant to be that assertion, but its
old→young remembered-set check is an unimplemented comment (lines ~50-53).

Line coverage is the wrong target: the spanning-card bug's "mark card" line
executed fine — the defect was a missing *iteration*, which a coverage % can't
see. The right target is **behavioral coverage** (every GC scenario) gated by
**invariant assertions** after every collection.

## Non-goals

- Line/branch coverage measurement (kcov). Rejected: weak against
  missing-iteration / missing-edge bugs, and not installed.
- Changing GC behavior. This is test + verifier work only — except for fixing
  any real bug the strengthened verifier surfaces (tracked as separate beads).

## Architecture

Three parts, built in order. Part 1 is the linchpin; Parts 2-3 drive the heap
into the states Part 1 inspects.

### Part 1 — Strengthen `src/gc/verifier.zig`

`Verifier.verify(gc)` already walks roots for dangling/forwarded pointers. Add
three invariants. Each is asserted at the point where it is *guaranteed to
hold*: immediately after a `minor()` collection, when the card table holds the
precise post-collection remembered set (the zepo-jus invariant).

1. **Remembered-set completeness.** Walk every live old-gen object
   (`og.walk`, skipping free nodes). For each `Value` slot (via
   `layoutForKind`) that points into the nursery (`nursery.contains`), assert
   the card covering *that slot's address* is dirty
   (`cards.isCardDirty(cardIndexFor(slot_addr))`).
   *Catches:* zepo-jus (collector-created edge whose card was wrongly cleared);
   spanning-card (a later-card edge the minor collector could not reach).

2. **Heap walkability.** Walk old-gen base→bump; each block's `sizeWords`
   advances the cursor by a positive amount and the walk lands *exactly* on
   `bump`. Every live block has a valid `Kind`.
   *Catches:* header corruption, wrong promotion sizes.

3. **card_starts coverage.** For every dirty card index, `card_starts[idx]` is
   non-null, points inside old-gen, and the object it names actually spans that
   card (`start ≤ cardStart(idx) < start + block_bytes`).
   *Catches:* the spanning-card root cause directly (recordCardStart not
   covering every spanned card).

New `VerifyError` variants: `UnmarkedOldYoungEdge`, `HeapNotWalkable`,
`CardStartMissing`. `verify` keeps its existing signature and the existing
root-scan checks; the new checks need `gc.nursery`, `gc.old_gen`, `gc.cards`,
all already reachable through `gc`.

**Expectation:** these checks may fail on current code. That is the intended
outcome — each failure is a real bug to root-cause and fix. See Workflow below.

### Part 2 — `tests/gc/stress.zig` (fast, in `gc_test`, target <5s)

An object-type factory plus a scenario matrix. The factory builds a valid
object of each layout shape the VM uses, with correct body layout per
`src/abi/layout.zig`:

| Builder | Kind | Tracing shape |
|---------|------|---------------|
| `makePair` | pair | fixed value_offsets {0,1} |
| `makeVector(n, fill)` | vector | variable, all_slots_are_values, value_slots_start=1, body[0]=len |
| `makeString(bytes)` | string | raw tail, no Value slots (leaf) |
| `makeHashTable(backing)` | hash_table | body[0]=len raw, body[1]=backing vector Value |
| `makeClosure(captures)` | closure | variable, value_slots_start=3, captures are Values |
| `makeBox(v)` / `makeSymbol(name)` | box / symbol | single Value at offset 0 |
| `makeFloat(f)` | float | raw f64 (leaf) — stands in for the nonexistent "bignum" leaf case |
| `makeForeign` | foreign | raw payload + finalizer (uses `gc.allocForeign`) |

(No `bignum` Kind exists; `float`/`box`/`string` cover the leaf and
single-Value cases the question grouped under it.)

Scenario matrix — each object type is driven through:
- **nursery-only churn**: allocate many, root none → force repeated minors
- **aged promotion**: root one, run `PROMOTE_AGE+1` minors → lands in old-gen
- **major sweep**: allocate in old-gen, drop roots → `major()` reclaims
- **multi-card spanning**: a large vector whose body spans ≥2 cards, with a
  *pointer slot located in its 2nd+ card* referencing a young object → after
  `minor()` the young target must survive and its edge sit on a dirty card
- **old→young edges built both ways**:
  (a) via write barrier (store young into a rooted old object), and
  (b) via promotion (promote an object that points at young survivors)

After every collection: `Verifier.verify(&gc)` + value-integrity assertions
(rooted objects retain their exact contents).

### Part 3 — `tests/gc/soak.zig` + `zig build gc_soak` (heavy, opt-in)

Seeded `std.Random` drives a randomized object graph:
- maintain a bounded rooted population (an `extra`-roots array of slots)
- each iteration randomly: allocate a random object type / mutate an edge
  (always through `gc.writeBarrier`) / drop a random root / trigger `minor()`
  or `major()`
- `Verifier.verify(&gc)` after every collection; on failure, print the seed.

Seed and iteration count come from env so failures are deterministically
reproducible and the run is tunable for nightly:
- `ZEPO_GC_SOAK_SEED` (default: fixed constant, e.g. 0x5EED)
- `ZEPO_GC_SOAK_ITERS` (default: a few hundred k — sized to stay reasonable)

A failing seed drops straight into a focused regression test.

### Build wiring (`build.zig`)

- Add `tests/gc/stress.zig` as a module and make `gc_test_step` depend on it
  (runs in CI alongside the existing GC tests).
- Add a new top-level `gc_soak` step wrapping `tests/gc/soak.zig`, *not*
  depended on by `gc_test` (opt-in / nightly only).

## Workflow (bead structure)

ZERO code without a bead. Epic + 4 children, TDD throughout:

- **Epic**: comprehensive GC stress + invariant coverage.
- **Bead 1 — verifier strengthening.** TDD: first write a test that constructs
  an old→young edge *without* marking its card and asserts `verify` returns
  `UnmarkedOldYoungEdge` (RED on today's no-op verifier), then implement the
  three checks (GREEN). Same RED→GREEN for the walkability and card_starts
  checks via deliberately corrupted fixtures.
- **Bead 2 — stress matrix** (`tests/gc/stress.zig`) + factory.
- **Bead 3 — seeded soak** (`tests/gc/soak.zig`) + `gc_soak` build step.
- **Bead 4 — triage**: each real bug Part 1/2/3 surfaces gets root-caused
  (systematic-debugging), a minimal deterministic repro, and a fix under its
  own bead. **On any verifier failure against current code: stop, root-cause,
  report the finding, fix under a dedicated bead** — do not batch silently.

## Testing

The verifier and harness *are* the tests. Validation that the suite works:
its RED fixtures (deliberately broken edges/headers) must make `verify` fail,
proving the checks have teeth — not just that they pass on a clean heap.
