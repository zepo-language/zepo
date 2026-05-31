# ADR 0003: LSP Unified-Analysis Strategy

**Status**: Accepted
**Date**: 2026-05-31
**Bead**: zepo-hamy
**Supersedes**: —
**Superseded by**: —

## Context

The LSP's `src/lsp/analysis.zig` is a hand-rolled, scanner-based parser
(~670 lines) that re-implements identifier scanning, define detection,
import-form parsing, and now (post zepo-ab3s) docstring extraction. It
runs independently of the real Zepo pipeline: `reader` → `ast/build`
→ `sema/resolve`.

This duplication has a cost:

- Every new LSP feature must teach the scanner what the real parser
  already knows. The recent `:documentation` hover (zepo-ab3s) is a
  case in point — the AST builder peels the keyword in 12 lines, then
  the LSP scanner re-peels it in 20 more.
- Resolver-aware features (find-references, rename, binding-kind hover,
  unused-variable lints, shadowing warnings) are simply not reachable
  from a scanner — they need full lexical binding analysis.

But the real pipeline has its own constraint: **the reader is not
error-recovering**. `reader.Parser.readAll` aborts on the first
malformed token (UnbalancedParen, UnexpectedEof, …). LSP, by contrast,
must analyze syntactically broken files at every keystroke — most edits
land mid-token. The scanner is error-tolerant by design.

The roadmap (zepo-893h) gates Phase 3 (unified analysis) and everything
downstream on this decision.

## Options Considered

### Option A: Keep the scanner forever

Accept the duplication; every LSP feature continues to be implemented
twice. Scanner stays the source of truth for the LSP.

Pros:
- Zero migration cost.
- The scanner is already error-tolerant.
- No reader changes needed.

Cons:
- Every Phase 3+ feature has a parallel implementation tax.
- Binding-kind aware features (rename, find-references, shadowing
  lints, primitive-vs-macro hover) are effectively blocked. They can
  be approximated by the scanner but not done correctly.
- The LSP and the runtime drift apart over time. Bugs found in one
  may not surface in the other.

### Option B: Full migration to real reader+ast+sema

Replace the scanner entirely. LSP analysis becomes a thin wrapper
around the real pipeline.

Pros:
- One source of truth for what Zepo source means.
- Every new language feature gets LSP support for free.
- Resolver-backed features become trivial.

Cons:
- **Requires adding error recovery to the reader.** This is the bulk
  of the work — and it's a runtime change with much larger blast
  radius than an LSP change. The reader has no resume points, no
  skip-to-synchronization-token machinery, no partial-AST mode.
- During edit storms (every keystroke between balanced parens), the
  LSP would emit no diagnostics at all because the parser aborts on
  the first failure.
- Migration is comparable in size to the scanner itself.

### Option C: Hybrid — opportunistic real pipeline, scanner as fallback

When the document parses cleanly, run the full reader→ast→resolver and
use the rich result. When it doesn't, fall back to the scanner-based
Analysis (same shape as today).

Pros:
- Most of the time the document IS parse-clean (the moments
  between edits dominate hover/completion/definition requests).
  During those moments, every Phase 3+ feature works correctly.
- During edit storms, the LSP degrades to today's behavior — exactly
  what users already accept.
- No reader changes required. Error recovery can be added later if
  P5's lint diagnostics demand it.
- Pay-as-you-go: each Phase 3+ feature reads from the real pipeline
  when available and may either degrade or be unavailable when it
  isn't. Scanner only learns the features it must.

Cons:
- Two analysis paths to maintain. The cost is borne in the
  fallback-degradation policy per feature.
- Some features (rename, find-references) refuse to operate on
  parse-broken documents. Users learn to fix syntax errors before
  refactoring — already the norm in other LSPs.

## Decision

**Adopt Option C (hybrid).**

The hybrid is the only option that makes Phase 3+ features actually
work in their happy path without requiring the reader to grow error
recovery. It honors both constraints: the LSP must be tolerant of
broken text, and the LSP should not parallel-implement language
semantics.

## Consequences

### Immediate (this ADR only)

- No code lands in this bead.
- The Phase 3 bead (zepo-wh3e) is reshaped per Option C: build the
  hybrid analyzer, do NOT excise the scanner.

### Phase 3 (zepo-wh3e) shape under this decision

- Add a `Analysis.real: ?RealAnalysis` field that holds reader+ast+
  resolver output when the document parses cleanly. Existing scanner
  fields stay for the broken-document path.
- Add a `parseFull(text)` helper that drives reader → ast → resolver
  and either returns a `RealAnalysis` or returns null if any stage
  errored.
- Hover, definition, completion check `analysis.real` first; if
  present, route through binding-kind-aware lookups. Otherwise fall
  back to the scanner path used today.
- Future per-feature policy: features that REQUIRE binding-kind
  awareness (rename, find-references, dead-export lints) refuse to
  operate when `analysis.real` is null and surface a user-readable
  reason ("can't rename: file has syntax errors").

### Downstream beads

- **P3 (zepo-wh3e):** description updated to reflect hybrid build,
  not full migration.
- **P4 (zepo-41a2):** find-references and rename gated on
  `analysis.real` being non-null. UI must refuse gracefully.
- **P5 (zepo-rzjw):** linter rules that need the resolver are
  enabled only on parse-clean documents. Tokens-based features
  (semantic tokens for primitives vs macros) can degrade gracefully.

### Features explicitly NOT pursued under Option C

- Reader-level error recovery. If a future LSP feature requires
  rich diagnostics on broken text, file a separate bead with its own
  ADR. Don't smuggle reader changes into LSP work.

### Risk and mitigation

- **Risk:** the two paths drift apart and a feature's degraded mode
  is buggier than its happy path. **Mitigation:** every Phase 3+
  feature ships with at least one LSP test exercising the broken-text
  fallback path. Without that test, the feature isn't done.
- **Risk:** users hit the "syntax error so I can't rename" path
  often. **Mitigation:** the LSP debounce from P1 (zepo-wwh7) already
  pushes analysis to quiet moments — most hover/completion requests
  arrive when the file is briefly parse-clean.

## Follow-ups

- Update zepo-wh3e's bead description with the hybrid shape.
- When P3 lands, write a short companion ADR that locks in the policy
  for "which features may degrade silently vs refuse loudly."
