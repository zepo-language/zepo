# Code Understanding Tool — Upgrades Design

Date: 2026-05-25

## Context

The original goal of the `lib/orch/*` work is a **code understanding tool**:
`examples/explain-file.lisp` — one command to explain any file in a repo,
grounded in retrieved code with citations. Pipeline: chunk → embed → vector
store → plan (LLM) → execute (retrieve_code → llm_code) → grounded answer.

Today it is **single-file** and **one-shot** (plans once, answers once). This
design upgrades it along three axes, in dependency order. The write-capable
agent (`agent-edit.lisp`, `orch/agent`, `orch/tools`, `orch/approval`) is
separate and stays untouched; the read-only loop is *reused* by piece #2.

## Pieces (build in this order)

1. **Cross-file indexing** — index a configurable *set* of files, with a
   cached embedding index. Foundation: multi-hop needs more than one file to
   hop to. Delivers value standalone (explain over a dir/repo).
2. **Multi-hop retrieval** — wrap the read-only tools in the ReAct loop
   (`orch/agent`) so the system can retrieve → read → retrieve again → answer,
   chasing cross-references the first query missed. No write tools, no
   approval gate needed.
3. **Retrieval quality** — chunk boundaries, reranking, k tuning. Last, so it
   can be tuned against real multi-hop behavior.

---

## Piece 1: Cross-file indexing (approved)

**New module `orch/corpus`**, two jobs:

### `resolve-sources spec` → list of absolute paths
Auto-detects mode from the arg:
- a file → just that file
- a directory → recurse, keep source/markdown extensions
- a glob (`lib/**/*.lisp`) → expand
- `:repo` / root flag → whole tree
- *follow-imports → deferred to its own later step (needs per-language parsing)*

### `build-index sources` → a vector store, via a per-file embedding cache
- For each file, compute a key: **content hash** (fall back to mtime+size if no
  hash primitive exists).
- Key matches cache → reuse that file's chunks + embeddings (no nomic call).
- Miss/stale → chunk (`chunker`) + embed (`embed`) + write to cache.
- Assemble the query's store from the union of the resolved files' cached
  entries.
- The cache is **per-file** (a file's chunks/embeddings don't depend on what
  else is indexed), so it is shared across every query/spec over the repo.

**Cache layout:** `<root>/.zepo-index/` — a manifest (`path → {hash, chunk-ids}`)
plus persisted vectors (reuse `vector_store` `store-save`/`store-load`).
Gitignore-able.

**Data flow:**
`spec → resolve → [paths] → (per file: reuse | chunk+embed+cache) → merged
store → existing retrieve/plan/answer`.

**Dependency to verify:** chunk IDs must be unique *across* files (today they
may be per-file). Key them by `path#n` so the store does not collide — a small
`chunker` change.

**Testing:** `resolve-sources` (file/dir/glob/repo over a temp tree) and the
cache staleness logic (changed→re-embed, unchanged→reuse) are offline via an
**injected embed fn**; the real nomic round-trip stays Ollama-gated.

---

## Piece 2: Multi-hop retrieval (sketch — own spec later)

Reuse `orch/agent`'s `run-agent` with **read-only tools only**
(`retrieve_code`, `read_chunk`/`llm_code`) over the cross-file store. The loop
retrieves, inspects, decides whether it needs more, retrieves again, then
finishes with a grounded answer. No mutating tools, so no approval gate.
Termination via `finish` + max-iters (already built). Planner uses a
"research" next-step prompt.

## Piece 3: Retrieval quality (sketch — own spec later)

Candidate levers, to be chosen against measured behavior: smarter chunk
boundaries (respect definition/heading boundaries), a rerank pass over the
top-k, k tuning, and dedup of near-identical chunks. Tuned last.

---

## Out of scope / non-goals
- No changes to the write-capable agent (`agent-edit.lisp` and friends).
- Follow-imports source mode is deferred (per-language parsing).
- No new vector backend; brute-force `vector_store` stays for now (the cache,
  not the index structure, is what makes repo-scale usable).
