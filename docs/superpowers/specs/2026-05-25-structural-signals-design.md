# Structural-Signals Layer for the Code-Understanding Tool

Date: 2026-05-25

## Context

Our code-understanding tool (`orch/corpus` + `orch/research`, entries
`index-repo.lisp` / `explain.lisp`) retrieves with semantic embeddings + exact
`grep_code`. Investigating `code-spider` (a pure structural indexer: git
churn/co-change, symbol defs/refs, hotspot, zones — no embeddings, no LLM)
showed that structural signals are: (a) better for *navigation* questions
("where is X defined / what calls X / what changed with X"), and (b)
deterministic + instant (no model). This adds a code-spider-style structural
layer on top of our semantic base.

Adopted decisions:
- Refs use **lexical whole-identifier** matching for v1 (no scope resolution).
- Build as **4 pieces** in dependency order.

## Pieces

### Piece 1 — Symbol index `orch/symbols` (foundation)
Extract definitions from corpus source files:
- `(define (NAME …) …)`, `(define NAME …)`, and `(export NAME …)` →
  `name -> [(file, line)]`.
- Identifier-aware: Zepo identifiers include `- ! ? * + < > = /`, so matching
  is on whole identifiers, not substrings.

API:
- `build-symbol-index sources` → defs map (name → def sites).
- `find-def name index` → definition sites.
- `find-refs name sources` → whole-identifier occurrences across files
  (definition-aware; a real "uses of X", unlike grep substring).

Defs are persisted at index time (`.zepo-index/symbols.json`); refs are
computed on demand by an identifier-boundary scan. Pure extraction →
offline-testable over fixture files.

### Piece 2 — Symbol-nav tools in the research loop (depends on 1)
Add `find_def {name}` and `find_refs {name}` tools to `orch/research`. This is
what makes multi-hop *real*: retrieve → spot symbol `X` → `find_def`/`find_refs`
→ gather the actual definition and its callers, instead of grep-guessing.
`grep_code` stays for arbitrary text.

### Piece 3 — Git signals `orch/gitsignals`
From `git log` (read-only, via shell/process-spawn):
- **co-change pairs**: files changed together, `weight = #commits together`.
- **hotspot**: `0.6·(churn/maxChurn) + 0.4·(loc/maxLoc)` (code-spider's formula).

Built at index time, persisted (`.zepo-index/gitsignals.json`). The PARSING
(log text → pairs/churn) is offline-testable by feeding sample log text; the
live `git log` call is integration-tested.

### Piece 4 — Structural rerank (depends on 1 + 3)
Revive `orch/rerank` with structural signals (replacing the parked word-only
lexical boost, which hurt MRR):
`final = semantic + w1·cochange + w2·hotspot + w3·symbol-overlap`. Weights
tuned against `examples/orch-retrieval-eval.lisp` (recall@k + MRR). Keep only
the signals that measurably improve the metric (YAGNI).

## Build order & testing
`1 → (2 ∥ 3) → 4`. Each piece is offline-testable (extraction/parsing/blending
are pure; git parsing is fed sample log text). End-to-end via `index-repo` +
`explain` + the eval harness.

## Non-goals (v1)
- Scope-aware ref resolution (lexical whole-identifier only).
- Cross-language symbol extraction (Zepo `.lisp` only; the chunker already
  handles other extensions for embedding, but symbols are Lisp-specific).
- Zones/flows/investigations from code-spider (navigation niche, low ROI here).
- The hybrid query router (route nav vs conceptual) — a possible later step
  once the structural tools + rerank exist.
