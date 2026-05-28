# ADR 0001: Qualified-access separator is `.`

- **Status:** Accepted
- **Date:** 2026-05-28
- **Bead:** zepo-x9w

## Context

After zepo-zc0 made imports non-transitive, the next step toward "real
namespacing" is letting two modules legitimately expose the same name —
the importer disambiguates at the call site via a qualified reference
like `<alias>SEP<name>`. The full feature lives in [[zepo-aqm]];
`zepo-x9w` is just the one-way design call: **pick the separator
character**, because every other piece of the namespace work — reader,
parser, sema, error messages, docs — bakes that choice in.

`/` is taken by module paths (`math/tensor`). Anything else has to
either be currently unused as a symbol character or have an
unambiguous parse rule.

## Decision

The separator is **`.`** (period).

## Rationale

- **Already deployed.** Zepo's existing `:as` import form binds
  `alias.name` as flat top-level symbols today (see `module_loader.zig`
  in the `(import M as A)` branch — `std.fmt.allocPrint("{s}.{s}", …)`).
  Code that wants qualified access already writes `t.transpose`. ADRs
  ratify reality where reasonable; this is one of those cases.
- **Lexer-friendly.** `.` is a symbol-continuation character but not a
  symbol-start character. Floats start with a digit, identifiers start
  with a letter, so `1.5` and `t.transpose` can never be confused.
  No reader change is required to *lex* the existing convention.
- **Survey of the codebase:** no .lisp file uses `foo.bar`-style names
  outside of string literals and comments. The convention is safe to
  promote.
- **Familiarity.** `t.transpose` reads as field/member access in Python,
  JS, Rust struct fields, ML records, etc. Less alien than `t::transpose`
  or `t:transpose` for the language's expected audience.

## Alternatives considered

- **`:`** — Common Lisp / Clojure tradition. Rejected: `:` is already
  reserved for keyword syntax (`:as`, `:version`). Mid-symbol `:` would
  require a lexer rule like "split unless leading," which is murkier
  than `.`'s clean digit-vs-letter rule.
- **`::`** — Rust/C++. Rejected: visually heavy; `:` is also keyword
  marker (see above); no payoff over `.`.
- **`/`** — overload of module-path syntax. Rejected: `math/tensor` is
  a *path to a module file*; `t.transpose` is a *member of a bound
  namespace value*. Reusing `/` for both blurs that distinction and
  makes error messages ambiguous ("not found" — is it a missing module
  or a missing member?).

## Consequences

- The reader does **not** change as part of this ADR. `t.transpose` already
  lexes as a single symbol and that's locked in by `reader-x9w-dot-as-separator`
  tests.
- Real namespace semantics — `alias` as a binding holding a namespace
  *object*, with `.member` as a structural lookup rather than a string
  prefix — is the job of [[zepo-aqm]]. zepo-aqm may grow the AST with a
  compound `ns_ref` node and rewrite the lowering; existing `alias.name`
  flat-symbol code keeps working through the transition.
- Mid-`.` symbols outside of qualified access (none exist in the repo
  today) become forbidden once aqm lands. Anyone introducing one
  between now and then should know they're stepping on the separator.
