# ADR 0007 — LSP performance audit: debounce & incremental parsing

- Status: Accepted
- Date: 2026-06-02
- Bead: zepo-aj7a (audit/redesign); blocks epic zepo-893h
- Supersedes the original scope of: zepo-krtr (didChange debounce), zepo-cw21
  (true incremental parsing)

## Context

Two LSP-roadmap beads — `krtr` (didChange debounce + diagnostics coalescing)
and `cw21` (true incremental parsing) — were filed when the analyzer only did
hover/definition/completion. The analyzer is now richer (hybrid real+scanner,
ScopeRange, EntryMeta, semantic tokens) and per-document Analysis is cached per
URI/version (zepo-wwh7). Both beads predate that cache. aj7a required an audit
before any code lands.

## Audit

Measured in-process on the three representative library files, ReleaseFast,
50 iterations each (clock: `clock_gettime`). `reader_check` is the diagnostics
reparse run on every `didChange`; `analyze` is the scanner pass behind the wwh7
cache (runs once per version, reused by hover/completion/definition).

| File              | bytes | reader_check (per-keystroke) | analyze (cached) |
|-------------------|------:|-----------------------------:|-----------------:|
| math/tensor.lisp  | 14589 |  1.31 ms                     |   7.57 ms        |
| clap.lisp         | 45766 |  2.33 ms                     |  40.05 ms        |
| testing.lisp      | 57653 |  2.48 ms                     |  51.54 ms        |

Two clear results:

1. **Full reparse is cheap.** `reader_check` (reader + AST build over the whole
   document, fresh GC included) is **1.3–2.5 ms** even on a 57 KB / 1300-line
   file. It scales roughly linearly with size.

2. **`analyze` scales superlinearly** — 7.6 → 40 → 51.5 ms for 15 → 46 → 58 KB.
   Root cause: `analysis.offsetToPosEnc` rescans the document from offset 0 on
   every call, and `analyze` calls it twice per symbol token (`Range.fromOffsets`
   in the first pass). That is O(symbols × offset) ≈ **O(n²)**. It is masked at
   the moment only because the wwh7 cache makes it run once per version, not per
   keystroke.

## Decisions

### cw21 (true incremental parsing) — CLOSE as wontfix

The bead was explicitly profile-gated: "if full reparse stays under 50 ms,
cw21 closes wontfix." It does — full reparse is 1.3–2.5 ms on the largest
representative file, ~20× under the threshold. True incremental parsing (a
reusable parse tree spliced on each edit) is substantial complexity for no
measurable benefit at realistic document sizes. Closed wontfix.

### krtr (didChange debounce + diagnostics coalescing) — CLOSE as wontfix

The debounce premise — "per-keystroke re-analysis is too expensive" — no longer
holds. The wwh7 cache already eliminates re-analysis for
hover/completion/definition (the handler borrows the cached Analysis), and the
only per-keystroke work left, `reader_check`, is ~2.5 ms. Debouncing a 2.5 ms
operation is not worth the added timer/coalescing machinery and its latency.
Closed wontfix. (If a future profile on a much larger file shows
`reader_check` climbing, a trivial "skip publish if a newer version already
arrived" coalesce can be added without a timer; noted, not scheduled.)

### The real finding → new bead

The audit surfaced an actual, measurable problem the two beads did not target:
`analyze`'s **O(n²)** offset→position conversion. At 51 ms on 58 KB and
growing superlinearly, a ~120 KB file would be ~200 ms — visible jank on the
first hover/completion after each edit. The fix is straightforward and O(n):
precompute line-start offsets once per analyze (or assign positions in the
single forward scan already happening) and binary-search / carry the running
position instead of rescanning. Filed as a separate, concrete bead.

## Consequences

- `krtr` and `cw21` are closed wontfix; the LSP roadmap epic (893h) no longer
  blocks on speculative incremental/debounce work.
- The audited reality is documented so future "the LSP feels slow" reports
  start from data, not the old assumptions.
- One concrete optimization (O(n²) → O(n) position conversion in `analyze`) is
  filed with its root cause and approach.
