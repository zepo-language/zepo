# Zepo

A Scheme-flavored Lisp implemented in Zig. Bytecode-compiled, garbage-collected, with a module system and a standalone CLI.

## Why Zepo?

- Scheme-flavored Lisp with a batteries-included toolchain
- Compile to small standalone native binaries with no runtime dependency
- Opinionated project layout with modules, libs, and packages
- Built-in formatter, linter, test runner, REPL, and LSP server
- Implemented in Zig with a register-based VM and generational GC

### Language flavor & stability

Zepo is a Scheme-style Lisp with:

- Mostly R7RS-style core forms and exceptions
- `defmacro` (unhygienic, Common Lisp style) and `define-syntax` / `syntax-rules` (hygienic, R7RS style)
- A fixed, opinionated standard library compiled into the binary

The language is evolving; minor breaking changes are still possible while it's pre-1.0.

### Concurrency

Zepo has two concurrency layers:

- **Fibers** — cooperative green threads sharing one OS thread. Yield at `(sleep ...)`, `(yield)`, and blocking I/O. Scheduled by a `poll(2)` event loop; no busy-waiting.
- **Workers** — OS threads, each with a fully isolated VM (own GC, symbol table, globals). Communicate through `Channel` objects. Only portable values (numbers, strings, symbols, lists, vectors, hash tables) can cross thread boundaries — including code passed as a quoted form and compiled in the worker with `eval`.

## Features

- **Runtime & execution**
  - Bytecode compiler + register-based VM
  - Generational garbage collector
  - Lexical scope with closures and tail-call optimization

- **Concurrency**
  - Cooperative fibers with `poll(2)` scheduler (`spawn`, `yield`, `sleep`, `fiber-join`)
  - OS-thread workers with isolated VMs (`spawn-worker`, `worker-stop`, `worker-stopping?`)
  - Thread-safe channels for fiber and cross-worker communication (`make-channel`, `channel-send!`, `channel-recv!`)

- **Tooling**
  - Module system with encapsulation
  - Interactive REPL with history and tab completion
  - LSP server for editor integration (`textDocument/publishDiagnostics`)
  - Built-in standard library, formatter, linter, and test runner

- **Interop & deployment**
  - Compile programs to standalone native binaries (`zepo build`)
  - Foreign Function Interface: wrap Zig libraries at compile time
  - JSON parse/stringify (backed by `std.json`)
  - POSIX ERE regex (`re-match`, `re-find-all`, `re-replace`) via system libc
  - First-class hash tables with `equal?` key semantics

## Build & Install

```sh
zig build                  # debug build → zig-out/bin/zepo
zig build test             # full test suite
zig build install-global   # release build → ~/.local/bin/zepo + ~/.local/lib/zepo/
```

Requires Zig 0.16.

## Usage

```
zepo              # show help
zepo --help       # show help
zepo init         # scaffold a new project in the current directory
zepo new <type> [name]  # generate a component inside a project (module|lib|test)
zepo run [file]   # run a file or the project entry point
zepo test [file]  # run a test file or discover tests/**/*_test.lisp
zepo fmt [file...] [--check] [--stdout]  # format source files in place
zepo lint [file...]  # run diagnostics on source files
zepo --repl       # start the interactive REPL
zepo file.lisp    # evaluate a script
zepo --max-regs=N file.lisp  # set VM register pool ceiling (default 4M slots, ~660K recursion levels)
zepo build [file.lisp] [-o name]  # compile to a standalone native binary
zepo lsp          # start the LSP server (stdio JSON-RPC)
```

## Quick Start

```sh
zepo init myapp   # scaffold a new project
cd myapp
zepo run          # run src/main.lisp (the default entry point)
```

Or run a single file:

## Typical workflow

From an empty directory to a native binary:

```sh
zepo init myapp
cd myapp
zepo run              # iterate in dev
zepo test             # run tests in tests/
zepo fmt              # format your code
zepo build            # produce a standalone native binary
./myapp               # run it without zepo installed
```

Open `zepo --repl` alongside this loop for interactive exploration and macro development.

```lisp
; hello.lisp
(define (main)
  (display "Hello, world!")
  (newline))

(main)
```

```sh
zepo hello.lisp
# Hello, world!
```

## Project Layout

`zepo init` creates:

```
myapp/
  project.lisp     ; project manifest  (name, version, paths, test-dir)
  src/
    main.lisp      ; entry point
  modules/         ; importable modules  (import name) resolves here
  lib/             ; reusable packages   (lib/<name>/package.lisp + mod.lisp)
  tests/           ; test files (*_test.lisp)
```

Generate new components inside an existing project:

```sh
zepo new module utils     # modules/utils.lisp
zepo new lib parser       # lib/parser/ package + tests/parser_test.lisp
zepo new test integration # tests/integration_test.lisp
```

## Running & Testing

```sh
zepo run              # runs entry from project.lisp
zepo run src/foo.lisp # runs a specific file

zepo test                      # discovers and runs tests/**/*_test.lisp
zepo test tests/foo_test.lisp  # runs one test file
```

Test files use the built-in `test` form:

```lisp
(import test)

(test "addition"
  (assert-equal 4 (+ 2 2)))
```

## REPL

```sh
zepo --repl
```

Features:
- **Multi-line input** — waits until parentheses balance before evaluating
- **Command history** — up/down arrows; persisted to `~/.zepo_history`
- **Tab completion** — completes symbol names from the active environment
- **Line editing** — Ctrl-A/E (home/end), Ctrl-K (kill to EOL), Ctrl-L (clear)
- **Ctrl-C** cancels the current input; **Ctrl-D** on an empty line exits

```
> (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
#<procedure>
> (fact 10)
3628800
> .quit
Bye.
```

## Standard Library

These are always available without explicit imports; they are compiled into the runtime.

| Category | Examples |
|----------|---------|
| Lists | `map`, `filter`, `fold-left`, `append`, `reverse`, `sort`, `length` |
| Higher-order | `for-each`, `any`, `every`, `find`, `count`, `zip` |
| Strings | `string-split`, `string-join`, `string-trim`, `string-contains` |
| Numbers | `even?`, `odd?`, `gcd`, `lcm`, `expt`, `min`, `max` |
| Vectors | `make-vector`, `vector-ref`, `vector-set!`, `vector-map` |
| Alists/Plists | `alist-get`, `alist-set`, `plist-get`, `plist-set` |

## Macros

Zepo supports compile-time code transformation via `defmacro` and quasiquote.

### Macro hygiene

Zepo has two macro systems:

**`defmacro`** is *unhygienic* in the Common Lisp sense: a macro is a function from unevaluated forms to a new form, and any identifiers it introduces are plain symbols. Macro-introduced bindings can accidentally capture names at the call site. Use `gensym` when you need a safe temporary name.

**`define-syntax` / `syntax-rules`** is *hygienic*: binding-site identifiers introduced by the macro template (in `let`, `lambda`, `define`, etc.) are automatically renamed to fresh symbols, so they can never capture — or be captured by — variables at the call site.

### Quasiquote syntax

The backtick (`` ` ``) starts a quoted template. Inside it, use `,` to unquote a value and `,@` to splice a list:

```lisp
(define name "world")
(define nums (list 1 2 3))

`(hello ,name)        ; => (hello world)
`(start ,@nums end)   ; => (start 1 2 3 end)
```

Quasiquote templates are expanded at read time to calls to `quasiquote`, `unquote`, and `unquote-splicing`.

### defmacro — define a macro

A macro is a function that receives unevaluated code as arguments and returns code to be evaluated in the caller's environment:

```lisp
(defmacro my-when (test . body)
  `(if ,test (begin ,@body)))

(my-when #t
  (display "condition true")
  (newline))
```

Macros can have rest parameters and can call other macros. The macro system supports arbitrary nesting and recursive macros.

Example: a macro that swaps two variables:

```lisp
(defmacro swap! (a b)
  `(let ((tmp ,a))
     (set! ,a ,b)
     (set! ,b tmp)))

(define x 1)
(define y 2)
(swap! x y)
(display x)  ; => 2
```

### define-syntax / syntax-rules — hygienic pattern macros

`define-syntax` binds a pattern-based transformer. Patterns are tried in order;
the first match expands to the corresponding template. Ellipsis (`...`) matches
zero or more sub-forms.

```lisp
(define-syntax when
  (syntax-rules ()
    ((_ test body ...)
     (if test (begin body ...)))))

(define-syntax and
  (syntax-rules ()
    ((_)        #t)
    ((_ e)      e)
    ((_ e1 e2 ...)
     (if e1 (and e2 ...) #f))))

; Hygiene: 't' inside the template is renamed fresh — safe even if caller has a 't'
(define-syntax or
  (syntax-rules ()
    ((_ e1 e2)
     (let ((t e1))
       (if t t e2)))))

(define t 99)
(or #f t)   ; => 99  (not #f)
```

See the [reference](docs/reference.md) for full pattern syntax, literals, and examples.

## Exceptions

Zepo uses R7RS-style structured exceptions:

```lisp
; raise any value as an exception
(raise 42)

; error creates a condition object with message + irritants
(error "something went wrong" irritant1 irritant2)

; with-exception-handler — low-level catch
(with-exception-handler
  (lambda (e)
    (if (error-object? e)
      (display (error-object-message e))
      (display "unknown error")))
  (lambda () (error "oops" 1 2)))

; guard — structured catch with clauses
(guard (exn
  ((error-object? exn)
   (string-append "Error: " (error-object-message exn)))
  (else "unknown"))
  (error "something failed"))
```

| Procedure | Description |
|-----------|-------------|
| `(error msg irritant ...)` | Raise an error condition |
| `(raise val)` | Raise any value as an exception |
| `(with-exception-handler h thunk)` | Call thunk; pass condition to h on error |
| `(guard (var clause...) body...)` | Structured exception handling |
| `(error-object? val)` | True if val is an error condition |
| `(error-object-message cond)` | Extract message string |
| `(error-object-irritants cond)` | Extract irritants list |

## Compile to Binary

Compile any Lisp program to a standalone native executable with `zepo build`:

```sh
zepo build                       # reads project.lisp, builds with project name
zepo build myprogram.lisp        # produces ./myprogram
zepo build myprogram.lisp -o bin # produces ./bin
```

With no arguments, `build` reads `project.lisp` from the current directory,
uses its `entry` field as the source file, and its `name` field as the output
binary name. With an explicit file argument it works as before.

The `build` command performs module discovery, embeds all imports as data, generates a Zig wrapper, and compiles to native code. The resulting binary requires no runtime or `.lisp` files. `zepo` is not needed on the target machine; the binary is fully self-contained.

```sh
./myprogram
# runs standalone, no zepo needed
```

## Module System

Zepo has three container forms:

| Form | Purpose |
|------|---------|
| `(module ...)` | In-project namespace with `export` list |
| `(lib ...)` | Single-file distributable library |
| `(package ...)` | Multi-file distributable — entry at `src/main.lisp` |

A module file declares what it exports:

```lisp
; modules/mymod.lisp
(module mymod
  (export greet)

  (define (helper s) (string-append "Hello, " s "!"))  ; private

  (define (greet name) (helper name)))                  ; exported
```

**Importing — keyword tier dispatch (preferred):**

```lisp
(import :modules  (mymod utils))      ; project-local files
(import :libs     (parser json))      ; installed single-file libs
(import :packages (myapp framework))  ; installed multi-module packages

; Mix tiers in one form:
(import :modules (mymod) :libs (json))
```

**Legacy bare form** (still supported — searches all project paths). A bare
`(import mymod)` binds **all of `mymod`'s exported names** into the current scope
— a convenient catch-all for quick prototyping. (It also binds the namespace
alias `mymod.name` for qualified access, and never exposes non-exported
internals unqualified.)

```lisp
(import mymod)                ; binds every export of mymod
(display (greet "world"))
```

For anything beyond throwaway scripts prefer a **selective** import — it
documents exactly what you depend on and avoids name clashes between modules
(two bare imports that export the same name will conflict):

```lisp
(import mymod (only greet))   ; or: (import mymod (greet))
(display (greet "world"))
```

### Import resolution rules

- `:modules` only searches the project's `modules/` directory.
- `:libs` only searches installed single-file libraries under `lib/`.
- `:packages` only searches installed multi-file packages.
- The legacy bare `(import name)` form searches all configured project paths and is kept for convenience; new code should prefer the keyword-tier form.

For `zepo build`, all imports are resolved at compile time and embedded into the resulting binary.

Selective import — only specified names:

```lisp
(import mymod (only greet))
```

Aliased import — creates a namespace:

```lisp
(import math/core as mc)
(mc.sin 0)    ; => 0
```

Import can also appear inside function bodies, executing at runtime:

```lisp
(define (use-math)
  (import math/core (only clamp))
  (clamp 42 0 10))   ; clamp is provided by math/core

(use-math)    ; => 10
```

A runtime import auto-loads the module from the search path on first execution,
just like a top-level import — so conditional/lazy imports work:

```lisp
(define (maybe-square x)
  (if x
      (begin (import math/core (only square)) (square x))
      0))
```

> One caveat: a module whose **top-level body spawns a fiber** can't be loaded
> from inside a running function (there's no scheduler at that nested level) —
> it raises `ContractViolation`. Import such modules at the top level.

Scaffold new components with `zepo new`:

```sh
zepo new module utils    ; modules/utils.lisp  — (module ...) skeleton
zepo new lib parser      ; parser/parser.lisp  — (lib ...) skeleton
zepo new package myapp   ; myapp/src/main.lisp — (package ...) skeleton
```

Only exported names are visible. Private helpers stay hidden inside the module.

## Bundled Libraries

`lib/format.lisp` — Scheme-style string formatting:

```lisp
(import format)

(format "hello ~a!" "world")       ; => "hello world!"
(format "~s" "quoted")             ; => "\"quoted\""
(format "~a + ~a = ~a" 1 2 3)     ; => "1 + 2 = 3"
(format "line1~%line2")            ; => "line1\nline2"
(format "tilde: ~~")               ; => "tilde: ~"
```

Directives: `~a` (display), `~s` (write/quoted), `~%` (newline), `~~` (literal tilde).

---

`lib/math/` — mathematics modules:
- `math/core` — constants (`pi`, `e`, `tau`, `phi`, `inf`...) and derived helpers (`clamp`, `square`, `deg->rad`, `log-base`, `lerp`...). Note: the math primitives like `sqrt`, `sin`, `cos`, `pow`, `ln`, and the predicates `zero?`/`even?`/`odd?` are **built-in globals** — they work with no import. `math/core` only adds the constants and helpers on top.
- `math/linear` — vector and matrix operations
- `math/numeric/fit` — curve fitting (linear and quadratic regression)
- `math/numeric/integrate` — numerical integration
- `math/numeric/roots` — root finding (bisection, Newton, secant)

```lisp
(sqrt 16)     ; => 4   — sqrt is a built-in primitive, no import needed

; math/core re-exports the builtin predicates (zero?, even?...), which already
; exist as globals, so a BARE (import math/core) raises an import-name conflict.
; Import it aliased, or selectively pull the names you want:
(import math/core as m)
m.pi          ; => 3.141592653589793   — constant, needs the import
(m.square 8)  ; => 64                  — derived helper, needs the import

(import math/core (only pi clamp square))   ; unqualified, no conflict
(clamp 42 0 10)   ; => 10

(import math/numeric/fit)
(fit-linear xs ys)  ; linear regression
```

---

`lib/introspect.lisp` — runtime introspection helpers. Exports
`(describe sym)` which prints the docstring attached to a binding via
`:documentation`:

```lisp
(import introspect (describe))

(define foo :documentation "adds one to x" (lambda (x) (+ x 1)))
(describe 'foo)
; foo
;   adds one to x
```

The underlying primitive `(documentation sym)` is registered globally and
returns the docstring string (or `#f`) without needing the import.

---

`lib/clap.lisp` — a full command-line argument parser with flags, options,
positionals, subcommands, type coercion, and typo suggestions.

```lisp
(import clap (make-program make-command make-option opt-set cmd-add-option run))

(define cmd
  (cmd-add-option
    (make-command "mytool" "Does things")
    (opt-set (opt-set (make-option 'verbose "Enable verbose output")
                      'long "verbose")
             'short "v")))

(define prog (make-program "mytool" "My tool" "" "1.0" cmd))
(run prog)
```

## Formatting

`zepo fmt` reformats `.lisp` source files in place:

```sh
zepo fmt                   # format all .lisp files under src/ and modules/
zepo fmt src/main.lisp     # format a specific file
zepo fmt --check           # exit 1 if any file would change (CI mode)
zepo fmt --stdout file.lisp  # print result to stdout, don't write
```

## Linting

`zepo lint` runs the same diagnostic pass as the LSP server and prints results:

```sh
zepo lint                  # check all .lisp files under src/ and modules/
zepo lint src/main.lisp    # check a specific file
```

Exits 1 if any diagnostics are found. Catches syntax errors, malformed special
forms (`(module)`, `(import)`, etc.), and AST-level structural issues.

## LSP Integration

Start the language server:

```sh
zepo lsp
```

Communicates over stdin/stdout using JSON-RPC 2.0 with Content-Length framing (standard LSP protocol). Supported methods:

| Capability | Method | Notes |
|---|---|---|
| Diagnostics | `textDocument/publishDiagnostics` | Reader/parser errors + linter rules (see below) |
| Hover | `textDocument/hover` | Shows binding kind (primitive/macro/local/captured/global) + `:documentation` docstring |
| Goto-def | `textDocument/definition` | Same-file + cross-file via module resolver |
| Completion | `textDocument/completion` | Triggered after `.` for qualified-name completion |
| Find-references | `textDocument/references` | Scope-aware — locals limited to enclosing lambda, globals scan the workspace |
| Rename | `textDocument/rename` + `prepareRename` | Refuses primitives; produces WorkspaceEdit across all matching sites |
| Document symbols | `textDocument/documentSymbol` | Per-file outline |
| Workspace symbols | `workspace/symbol` | Substring search across workspace `.lisp` files |
| Semantic tokens | `textDocument/semanticTokens/full` | function/macro/variable/parameter/namespace |
| Formatting | `textDocument/formatting` | Format-on-save using the same engine as `zepo fmt` |

Linter rules (warnings/hints in diagnostics output):

- `redefinition` — same top-level name defined twice in a file.
- `unused-define` — top-level define that's never referenced in the same file.
- `unused-import` — selective import name (or `:as` alias) that's never referenced.
- `dead-export` — name in `(export ...)` with no matching `(define ...)`.
- `shadowing` — inner local that re-binds a name from an enclosing scope.

Configure in VS Code (with a generic LSP client extension):

```json
{
  "command": "zepo",
  "args": ["lsp"],
  "filetypes": ["lisp"]
}
```

### Neovim (lazy.nvim)

Zepo is not in `nvim-lspconfig`'s registry, so register the client yourself.
On Neovim 0.11+ the smallest working setup uses `vim.lsp.start` — drop this in a
file under your lazy plugins directory (e.g. `~/.config/nvim/lua/plugins/zepo.lua`):

```lua
return {
  "neovim/nvim-lspconfig", -- only needed for its filetype plumbing; the start call is plain core LSP
  ft = "lisp",
  config = function()
    vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
      pattern = "*.lisp",
      callback = function(args)
        vim.lsp.start({
          name = "zepo",
          cmd = { "zepo", "lsp" }, -- must be on PATH; or an absolute path like vim.fn.expand("~/.local/bin/zepo")
          root_dir = vim.fs.root(args.buf, { "project.lisp", ".git" }),
        })
      end,
    })
  end,
}
```

`vim.lsp.start` deduplicates by `{name, root_dir, cmd}`, so reopening buffers in
the same project reuses the one server. Verify the binary works first with
`echo '' | zepo lsp` — it should block waiting on stdin (Ctrl-C to exit).

Notes:

- **PATH** — `cmd` runs `zepo lsp`. If `zepo` isn't on Neovim's PATH, use an
  absolute path: `cmd = { vim.fn.expand("~/.local/bin/zepo"), "lsp" }`.
- **Filetype collision** — Zepo sources use the `.lisp` extension, which Neovim
  also detects as builtin `lisp`/`commonlisp`. The config above is safe because
  it gates on the `*.lisp` pattern directly. To give Zepo its own filetype
  instead, add `vim.filetype.add({ extension = { lisp = "zepo" } })` and change
  both `ft` and `pattern` to `"zepo"`.
- **Keymaps** — wire `gd`, `K`, etc. on `LspAttach`:

  ```lua
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(ev)
      local opts = { buffer = ev.buf }
      vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
      vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
      vim.keymap.set("n", "grn", vim.lsp.buf.rename, opts)
      vim.keymap.set("n", "grr", vim.lsp.buf.references, opts)
    end,
  })
  ```

All capabilities in the table above (diagnostics, hover, goto-def, completion,
references, rename, document/workspace symbols, semantic tokens, format-on-save)
are served over this one stdio connection.

## Regex

POSIX Extended Regular Expressions delegating to the system libc `regcomp`/`regexec` implementation:

```lisp
(import regex (regex-match? regex-find-all regex-replace regex-replace-all))

(regex-match? "^hello" "hello world")            ; => #t
(regex-find-all "[0-9]+" "abc 123 def 456")      ; => list of match alists:
                                                 ;    (((match . "123") (start . 4) (end . 7) (groups))
                                                 ;     ((match . "456") (start . 12) (end . 15) (groups)))
(regex-replace     "o" "f_o_o" "0")              ; => "f_0_o"  (first match only)
(regex-replace-all "o" "f_o_o" "0")              ; => "f_0_0"  (every match)
```

The module also exports `regex-find` and `regex-split`. A bare `(import regex)`
binds all of these names at once (handy for prototyping); the selective import
above is the tidier form for real code, and `(import regex as rx)` exposes them
under a namespace as `(rx.regex-match? …)`.

## Documentation

See [`docs/reference.md`](docs/reference.md) for the complete language reference.
