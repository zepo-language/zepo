# Zepo

A Scheme-flavored Lisp implemented in Zig. Bytecode-compiled, garbage-collected, with a module system and a standalone CLI.

## Features

- Bytecode compiler + register-based VM
- Generational garbage collector
- Lexical scope with closures
- Tail-call optimization
- Module system with encapsulation
- Macros (`defmacro` + quasiquote/unquote/unquote-splicing)
- Compile programs to standalone native binaries (`zepo build`)
- First-class hash tables with `equal?` key semantics
- JSON parse/stringify (backed by `std.json`)
- Foreign Function Interface: wrap Zig libraries at compile time
- Interactive REPL with history and tab completion
- LSP server for editor integration (`textDocument/publishDiagnostics`)
- POSIX ERE regex (`re-match`, `re-find-all`, `re-replace`)
- Built-in standard library

## Build & Install

```sh
zig build                  # debug build → zig-out/bin/zepo
zig build test             # full test suite
zig build install-global   # release build → ~/.local/bin/zepo + ~/.local/lib/zepo/
```

Requires Zig 0.15.

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

The stdlib is compiled into the binary — no imports needed. Available everywhere:

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

The `build` command performs module discovery, embeds all imports as data, generates a Zig wrapper, and compiles to native code. The resulting binary requires no runtime or `.lisp` files.

```sh
./myprogram
# runs standalone, no zepo needed
```

## Module System

Modules live in `modules/` inside a project, in `lib/` for installed packages,
or anywhere on `ZEPO_PATH`. The search order is: project paths (from
`project.lisp`), then `~/.local/lib/zepo/`, then `ZEPO_PATH`:

```sh
export ZEPO_PATH=~/.zepo/lib:./modules
```

A module file declares what it exports:

```lisp
; modules/mymod.lisp
(module mymod
  (export greet)

  (define (helper s) (string-append "Hello, " s "!"))  ; private

  (define (greet name) (helper name)))                  ; exported
```

Import it on demand — full import brings all exports into scope:

```lisp
(import mymod)
(display (greet "world"))
```

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
  (import math/core)
  (sqrt 16))

(use-math)    ; => 4
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
- `math/core` — math primitives, constants, predicates (sin, cos, sqrt, etc.)
- `math/linear` — vector and matrix operations
- `math/numeric/fit` — curve fitting (linear and quadratic regression)
- `math/numeric/integrate` — numerical integration
- `math/numeric/roots` — root finding (bisection, Newton, secant)

```lisp
(import math/core)
(sqrt 16)     ; => 4

(import math/numeric/fit)
(fit-linear xs ys)  ; linear regression
```

---

`lib/clap.lisp` — a full command-line argument parser with flags, options,
positionals, subcommands, type coercion, and typo suggestions.

```lisp
(import clap)

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

Communicates over stdin/stdout using JSON-RPC 2.0 with Content-Length framing (standard LSP protocol). Supports `textDocument/didOpen` and `textDocument/didChange`, publishing syntax diagnostics back via `textDocument/publishDiagnostics`.

Configure in VS Code (with a generic LSP client extension):

```json
{
  "command": "zepo",
  "args": ["lsp"],
  "filetypes": ["lisp"]
}
```

## Regex

POSIX Extended Regular Expressions via the system regex library:

```lisp
(import regex)

(re-match "^hello" "hello world")      ; => #t
(re-find-all "[0-9]+" "abc 123 def 456") ; => ("123" "456")
(re-replace "o+" "f_o_o" "0")           ; => "f_0_0"
```

## Documentation

See [`docs/reference.md`](docs/reference.md) for the complete language reference.
