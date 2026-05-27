# One Command, Three Models: Explaining Any File in Your Codebase

This post is about a demo: taking a single command and using it to have a local LLM read, retrieve, and **explain any file in your repo** in a grounded way.

The whole pipeline lives behind one CLI entry point:

```bash
zepo examples/explain-file.lisp -- <file-path> "<your question>"
```

You point it at a file and ask a question in plain language. Under the hood, it:

- Chunks the file (and optionally nearby docs) into retrieval units  
- Embeds and indexes those chunks  
- Calls a planner model to produce a tool-based plan  
- Executes that plan with a code‑aware model  
- Streams back a grounded answer with code citations  

This post walks through what happens on each run, and then through a set of live demos that show the system’s behavior on real files.

I’ll assume you care about the **demo and behavior**, not the origin story of the language/runtime it’s written in.

## Setup: one orchestrator, three local models

The system runs entirely on your machine, using local models hosted by Ollama:

- **Embedding model:** `nomic-embed-text`  
- **Planner model:** `llama3.1:8b`  
- **Answer model:** `qwen2.5-coder:7b`  

The only dependencies you need running ahead of time:

- Ollama listening on `localhost:11434`
- Those three models pulled and available

With that, every demo in this post is just a variation on:

```bash
zepo examples/explain-file.lisp -- <file-path> "<your question>"
```

The orchestrator handles everything else.

## What happens during a run

Each run prints out high-level stages as it goes, so you can see exactly what is happening:

```text
── chunking            (chunker.lisp at work)
── embedding           (nomic-embed-text round-trips)
── planning            (llama3.1:8b emits a JSON plan)
  plan: (sequence (tool-call r1 retrieve_code ...)
                  (tool-call a1 llm_code ...)
                  (final-answer a1))
── executing           (exec.lisp dispatches, threads retrieve_code → llm_code via input_id)
── answer              (qwen2.5-coder:7b's grounded reply)
── elapsed: NNNNN ms
```

Let’s unpack what each of those stages does.

### 1. Chunking: turn files into retrieval units

Given a file path, the system first chunks it into small, labeled pieces:

- **Source files** (e.g., `*.lisp`, `*.zig`) are chunked as `source` chunks with:
  - Stable IDs (used as keys in the store)
  - Absolute line ranges (so the answer can reference “where” in the file things happen)
- **Markdown files** (e.g., `README.md`) are chunked by **headings** instead of naïve paragraphs, so retrieval pulls in semantically meaningful sections rather than arbitrary text fragments.

The chunker does just enough work to ensure:

- IDs are stable across runs, so embeddings and caches can be reused.  
- Line numbers are monotonic across chunks, so you can map an answer back to where it came from.

### 2. Embedding: give chunks a vector representation

Once chunks are created, the orchestrator calls `nomic-embed-text` to turn each chunk’s text into a vector, then stores that vector plus metadata in a lightweight vector store.

Outcome:

- The system has a searchable index keyed by chunk ID.
- That index is specific to the file(s) you care about for that run.

For small files, this is basically free. For larger files (or combinations of files + docs), this becomes where most of the “data movement” happens.

### 3. Planning: ask an LLM to design a tool-based workflow

Next, the orchestrator calls a **planner** model (`llama3.1:8b`) with:

- A system prompt describing the available tools, including a machine-readable catalog with input schemas  
- The user’s question (`"how does shutdown work?"`, etc.)

The planner is not asked to answer the question directly. Instead, it is asked to produce a **plan** in a small, explicit language. A typical successful plan looks like:

```lisp
(sequence
  (tool-call r1 retrieve_code
             ((query . "shutdown in worker-pool.lisp")))
  (tool-call a1 llm_code
             ((input_id . "r1")
              (question . "how does shutdown work?")))
  (final-answer a1))
```

Key points:

- The planner chooses specific tools (here, `retrieve_code` and `llm_code`).
- It provides arguments using the documented schema (`query`, `question`, etc.), not hallucinated field names.
- It uses `input_id` to say “feed the output of step `r1` into the next tool as context.”

A separate validator checks that the plan:

- Is structurally well-formed  
- Uses only known tools  
- Passes arguments with correct keys  

If the plan passes, we move on to execution.

### 4. Executing: run the tools and thread results

The **executor** walks the plan and runs each step:

1. Runs `retrieve_code` with the suggested query.  
   - Under the hood, this uses the vector store to pull the most relevant chunks from the file (and possibly related files or docs, depending on configuration).
2. Resolves `{"input_id": "r1"}` by grabbing the output of step `r1` and inserting it into `llm_code`’s `context` argument.
3. Calls `llm_code` (powered by `qwen2.5-coder:7b`) with:
   - The retrieved code context
   - The original question

When `llm_code` completes, the executor marks that step’s output as `a1`. The final step `(final-answer a1)` tells the orchestrator to print the answer from that step as the user-visible result.

### 5. Answer: a grounded explanation, not a hallucination

Because the answer model sees **actual code chunks** as context, the output tends to be:

- Specific: referencing exact functions, loops, and lines  
- Grounded: describing real behavior instead of guessing  
- Citable: often echoing or paraphrasing code snippets it was shown

The entire run finishes with an `elapsed` time. On the core smoke test, the system consistently comes in under 30 seconds (around 22s in recent runs), including chunking, embedding, planning, and execution.

## Demo 1: The canonical smoke (~22s)

The first demo is the one that closed Phase 1: explaining shutdown in a worker pool example.

```bash
zepo examples/explain-file.lisp -- \
  examples/worker-pool.lisp \
  "how does shutdown work?"
```

What it demonstrates:

- **Small, concrete file**  
  The worker pool is short enough that you can check the answer by reading the code yourself.
- **End-to-end orchestration**  
  You see all stages: chunking, embedding, planning, executing, answer.
- **A very clear question**  
  “How does shutdown work?” forces the system to reason about:
  - how workers receive jobs,
  - how they know when to exit,
  - how the main thread waits for them.

Typical behavior:

- The planner picks `retrieve_code` scoped to `worker-pool.lisp` and `llm_code` with the question.
- The executor retrieves the section where the code sends a sentinel job (e.g., `#f`) to each worker and then loops to wait for them to finish.
- The answer describes the sentinel-based shutdown pattern and points at the exact loops that send `#f` and poll `worker-alive?`.

Why it’s a good first demo:

- It proves the architecture actually works under time constraints.  
- It’s easy to validate the explanation against the code in a live setting.

## Demo 2: A larger file with real retrieval

Next, you can show the orchestrator working on a more complex, larger code file: the executor itself.

```bash
zepo examples/explain-file.lisp -- \
  lib/orch/exec.lisp \
  "what happens when a parallel step's child errors?"
```

What this tests:

- **Non-trivial retrieval**  
  `exec.lisp` is larger and contains multiple concerns (plan walking, parallelism, error handling). Chunking produces many chunks, and the embedding + retrieval step has to find the right subset.
- **Focused behavior**  
  The question zooms in on a specific aspect: error handling in parallel steps.

A strong run will:

- Retrieve chunks describing:
  - How parallel steps spawn child tasks
  - How errors are captured or propagated
  - Any retry or cancellation logic
- Answer with a description like:
  - Whether the executor short-circuits on the first error
  - How it aggregates errors from children
  - What data structures it uses to pass error information back up

Why it matters:

- It proves the tool can handle “find the right behavior in a noisy, larger file” instead of just answering questions about toy examples.

## Demo 3: Markdown with heading-based chunking

Code is only half the story. This demo shows the system explaining documentation.

```bash
zepo examples/explain-file.lisp -- \
  README.md \
  "what is a module and how do I create one?"
```

What’s interesting here:

- **Heading-based chunking**  
  The README is split by headings into doc chunks (e.g., “Running Zepo”, “Container forms”, “The import form”, etc.), not by arbitrary length.
- **Multi-section retrieval**  
  A good answer to this question likely needs to pull:
  - the conceptual description of “module”, and
  - the section that explains how to create modules via CLI commands.

Behavior to highlight:

- In the **chunking** stage, you can mention that the strategy differs from source files.  
- In the **answer**, you can check whether the model mentions both:
  - the definition of a module (as a named namespace with exports), and
  - concrete steps like `zepo new module …` or relevant scaffolding commands.

This demo shows:

- The orchestrator is not tied to code only; it treats docs as first-class retrieval sources.
- Chunking strategy is context-aware (source vs docs).

## Demo 4: Cross-file synthesis in the planner

Finally, you can ask a higher-level, cross-cutting question about the planner itself.

```bash
zepo examples/explain-file.lisp -- \
  lib/orch/planner.lisp \
  "how does the retry loop work and what error info does it feed back?"
```

What this stresses:

- **Deep understanding of one subsystem**  
  The planner code often interacts with other components (validation, execution, external models), so the behavior may be influenced by multiple files.
- **Multi-chunk, possibly cross-file reasoning**  
  Even if you only index `planner.lisp` for the demo, the model needs to:
  - find where retries are implemented,
  - understand what data structures they use,
  - see what error details are captured and returned.

A good answer should:

- Identify the loop or mechanism that retries failed planner calls.  
- Describe:
  - what triggers a retry (e.g., invalid JSON, schema mismatch),
  - what maximum number of retries or backoff exists, and
  - what error payload or metadata gets passed back to the caller when retries are exhausted.

This demo is a great way to end, because:

- It confirms the orchestration is genuinely useful for understanding non-trivial control flow.  
- It shows that the system is comfortable explaining its own planning logic.

## Why this demo structure works

There are three reasons this demo resonates with engineers:

1. **One command, multiple behaviors**  
   The interface never changes. Swapping in different files and questions, you go from a tiny worker example, to a large executor, to documentation, to the planner’s own logic.

2. **Transparent stages**  
   The printed stages—chunking, embedding, planning, executing, answer—make the system legible. People can see where time goes and where each model is involved.

3. **Grounded answers**  
   Every example is framed so you can validate correctness by looking at the actual file. You’re not asking “What is functional programming?”; you’re asking “How does this specific shutdown mechanism work?” or “How is this retry loop wired?”

The point of the demo isn’t to show off “AI magic.” It’s to show a clear, reproducible **recipe** for using LLMs to interact with real code and docs:

- Chunk what matters  
- Embed it locally  
- Let a planner choose tools instead of trying to answer everything in one shot  
- Let a code-aware model explain things with the right context  

All behind a single, boring command line.
# The whole pipeline is one command:

  zepo examples/explain-file.lisp -- <file-path> "<your question>"
  zepo examples/explain-file.lisp -- <file-path> "<your question>"

  Prereqs (you already have these):
  - Ollama running on localhost:11434
  - Models pulled: nomic-embed-text, llama3.1:8b, qwen2.5-coder:7b

  Demos worth showing live:

  # The canonical one (the smoke; ~22s)
  zepo examples/explain-file.lisp -- examples/worker-pool.lisp "how does shutdown work?"

  # A larger file — exercises real retrieval over many chunks
  zepo examples/explain-file.lisp -- lib/orch/exec.lisp "what happens when a parallel step's child errors?"

  # Markdown gets chunked by heading instead of paragraph
  zepo examples/explain-file.lisp -- README.md "what is a module and how do I create one?"

  # Cross-file question that forces the model to synthesize from retrieved chunks
  zepo examples/explain-file.lisp -- lib/orch/planner.lisp "how does the retry loop work and what error info does it feed back?"

  Each run prints the live stages so the audience can see what's happening:

  ── chunking            (chunker.lisp at work)
  ── embedding           (nomic-embed-text round-trips)
  ── planning            (llama3.1:8b emits a JSON plan)
    plan: (sequence (tool-call r1 retrieve_code ...) (tool-call a1 llm_code ...) (final-answer a1))
  ── executing           (exec.lisp dispatches, threads retrieve_code → llm_code via input_id)
  ── answer              (qwen2.5-coder:7b's grounded reply)
  ── elapsed: NNNNN ms
