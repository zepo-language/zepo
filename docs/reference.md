# Zepo Language Reference

## Overview

Zepo is a Scheme-flavored Lisp implemented in Zig. It features a generational
garbage collector, a bytecode compiler, a register-based VM, a module system, a
macro system with quasiquote, first-class hash tables, a JSON binding, and an
FFI for wrapping Zig libraries. The runtime is embeddable as a Zig library
(`zepo`) and ships a standalone CLI that can also compile programs to
standalone native binaries.

Key properties:

- Dynamically typed, immutable symbols, mutable pairs and vectors
- Lexical scope; closures capture their environment
- Tail-call optimization in the VM
- Only `#f` and `()` (nil) are falsy; everything else — including `0` — is truthy
- Source files are UTF-8; identifiers may contain `-`, `?`, `!`, `+`, `*`, `/`, `<`, `>`, `=`

---

## Running Zepo

```
Usage: zepo [options] [file]
       zepo init
       zepo new <type> [name]
       zepo install <path>
       zepo run [file.lisp]
       zepo test [file.lisp]
       zepo build [file.lisp] [-o outname]

Options:
  --repl             Start an interactive REPL
  -e <expr>          Evaluate <expr> and exit
  --max-regs=N       Set VM register pool ceiling (default: 4194304, ~660K recursion levels)
  --max-heap=SIZE    Set GC heap cap for nursery AND old-gen (default: 4M).
                     SIZE accepts bytes or suffixes: 16M, 32MiB, 2G, 64K. Also via ZEPO_MAX_HEAP.
  --help             Show this help message

Commands:
  fmt [file...]        Format source files in place (--check for CI)
  init                 Scaffold a new project in the current directory
  lint [file...]       Run diagnostics on source files
  new <type> [name]    Generate a component (module, lib, test, package)
  run [file.lisp]      Run a file or the project entry point
  test [file.lisp]     Run a test file or discover tests/**/*_test.lisp
  install <path>       Copy package to ~/.local/lib/zepo/ and compile .lisp → .zbc
  build [file.lisp]    Compile to a standalone native binary
    -o <name>          Output binary name (default: input stem or project name)

Arguments:
  file          Path to a .lisp file to evaluate
```

### File mode

```sh
zepo program.lisp
```

The file is read, compiled, and evaluated. The final expression value is
discarded (use `display`/`println` for output).

### REPL

```sh
zepo --repl
```

Starts an interactive session. Multi-line expressions are accepted; the REPL
waits until parentheses balance before evaluating. Each result is printed
automatically.

```
> (+ 1 2)
3
> .quit          ; exit the REPL
```

Press **Ctrl-D** or type `.quit` to exit.

### Container forms

Zepo has three explicit container forms — `module`, `lib`, and `package` —
each with optional `:keyword` metadata. All containers register in the module
registry so they can be imported.

**Metadata keywords** (all optional, all containers):

| Keyword | Type | Meaning |
|---------|------|---------|
| `:version` | string | Semantic version, e.g. `"1.0.0"` |
| `:docstring` | string | Human-readable description (alias: `:documentation`) |
| `:author` | string | Author name |
| `:license` | string | License identifier, e.g. `"MIT"` |
| `:depends` | list | Dependency names: `(foo bar)` |

**`(module name ...)`** — a named namespace inside a project. Declares
exported names, then evaluates body forms in the module's private environment.

```lisp
(module math
  :version "1.0.0"
  :docstring "Core arithmetic helpers"
  (export square cube)

  (define square (lambda (x) (* x x)))
  (define cube   (lambda (x) (* x x x))))
```

**`(lib name ...)`** — a single-file distributable library. Same evaluation
semantics as `module`; the `lib` keyword signals it is compiled and installed
as a standalone artifact rather than living inside a project.

```lisp
(lib mylib
  :version "0.1.0"
  :docstring "A reusable library"
  (export greet)

  (define greet (lambda (name) (string-append "hello " name))))
```

**`(package name ...)`** — a multi-module distribution container. Declares
metadata and (optionally) bootstraps sub-modules via `(import :modules ...)`.
Body forms are evaluated in the package's environment.

```lisp
(package myapp
  :version "1.0.0"
  :docstring "My application package"
  :depends (math mylib))
```

### The `import` form

```lisp
; Keyword form — explicit tier dispatch (preferred):
(import :modules  (utils math))      ; project-local .lisp/.zbc files
(import :libs     (parser json))     ; installed single-file libraries
(import :packages (myapp framework)) ; installed multi-module packages

; Mixed in one form:
(import :modules (utils) :libs (json) :packages (framework))

; Legacy bare form (still supported):
(import math)
(import math as m)             ; all exports prefixed as m.square, m.cube
(import math (only square))    ; selective import
```

Each tier searches a different path:

| Tier | Paths searched |
|------|---------------|
| `:modules` | Project-local paths (project.lisp, `ZEPO_PATH`) |
| `:libs` | `~/.local/lib/zepo/<pkg>/` — installed lib dirs |
| `:packages` | `~/.local/lib/zepo/` — package roots; loads `<name>/src/main.lisp` |

### Scaffolding with `zepo new`

Generate boilerplate. `module` and `test` require a project (`project.lisp`);
`lib` and `package` are standalone.

| Type | What it creates | Requires project? |
|------|-----------------|-------------------|
| `module` | `modules/<name>.lisp` — `(module ...)` skeleton | yes |
| `test` | `tests/<name>_test.lisp` | yes |
| `lib` | `<name>/<name>.lisp` — `(lib ...)` skeleton | no |
| `package` | `<name>/src/main.lisp` — `(package ...)` container | no |

```sh
# Inside a project:
zepo new module utils
zepo new test utils

# Anywhere — standalone distributable artifacts:
zepo new lib parser
zepo new package myapp
```

`zepo new lib <name>` creates:

```
parser/
  parser.lisp    ← (lib parser :version "0.1.0" :docstring "" (export))
```

`zepo new package <name>` creates:

```
myapp/
  src/
    main.lisp    ← (package myapp :version "0.1.0" :docstring "")
```

Add sub-modules in `src/` and import them from `main.lisp`:

```lisp
(import :modules (myapp.core myapp.utils))
```

### Installing libs and packages

```sh
zepo install <path>
```

Copies the directory to `~/.local/lib/zepo/<name>/` and pre-compiles `.lisp`
files to `.zbc` bytecode. The install command detects the structure:

- **Package** (`src/main.lisp` present) — compiles `src/` subtree only
- **Lib** (`<name>.lisp` at root) — compiles root `.lisp` files

```sh
zepo install ./parser    # lib:     compiles parser/parser.lisp → parser.zbc
zepo install ./myapp     # package: compiles myapp/src/*.lisp → *.zbc
```

Output on success:

```
installed lib 'parser' → /Users/you/.local/lib/zepo/parser
  1 file(s) compiled, 0 skipped

installed package 'myapp' → /Users/you/.local/lib/zepo/myapp
  3 file(s) compiled, 0 skipped
```

**Compiled vs. source loading.** When a `.zbc` file exists alongside a
`.lisp` file, `import` loads the bytecode directly — skipping parsing,
macro expansion, and code generation. This makes installed libraries
significantly faster to load than source files.

### Startup and module search path

On startup the runtime evaluates the built-in **stdlib** (`lib/stdlib.lisp` —
embedded at compile time). No other files are auto-loaded.

`EvalContext` maintains three separate path tiers populated at startup:

| Field | Contents |
|-------|----------|
| `module_path` | Project-local dirs (project.lisp, `ZEPO_PATH`) |
| `lib_path` | `~/.local/lib/zepo/<pkg>/` per installed lib |
| `package_path` | `~/.local/lib/zepo/` root |

The `:modules`/`:libs`/`:packages` import tiers search the matching field.
The legacy bare `(import name)` searches `module_path` (the combined path).

```sh
ZEPO_PATH=~/.zepo/lib zepo myscript.lisp
```

### Debugging / ZEPO_TRACE

Set the `ZEPO_TRACE` environment variable to a comma-separated list of
subsystem names to enable structured runtime tracing. Trace output is written
to stderr.

| Subsystem | What it traces |
|-----------|----------------|
| `gc` | GC collections — nursery/major, bytes promoted, objects freed |
| `module` | Module load events — which file was found and loaded |
| `eval` | Per-expression source location during dispatch |
| `opcodes` | Every opcode executed, shown as `funcname:pc  OPCODE` |

```sh
ZEPO_TRACE=gc,opcodes zepo myscript.lisp
ZEPO_TRACE=gc,module,eval,opcodes zepo myscript.lisp
```

### Recursion depth

The VM uses a register pool with a default ceiling of **4,194,304 slots** (~660,000 non-tail recursion levels). Exhausting the pool raises a `StackOverflow` error, reported as:

```
error: stack overflow (recursion too deep)
```

with a call-stack trace showing the innermost 20 frames.

Use `--max-regs=N` to raise the ceiling for deeply recursive programs or lower it in memory-constrained environments:

```sh
zepo --max-regs=8388608 deep_recursion.lisp   # 8M slots, ~1.3M levels
zepo --max-regs=65536   shallow.lisp          # 64K slots, low-memory env
```

Tail calls (`define`/`let` loops using TCO) do not consume register slots and are unaffected by this limit.

### GC heap cap

The GC nursery and old generation are each capped at **4 MiB** by default. Bump both with `--max-heap=SIZE` or the `ZEPO_MAX_HEAP` env var; CLI wins when both are set. Sizes accept bare bytes or SI-ish suffixes (`64K`, `16M`, `32MiB`, `2G`).

```sh
zepo --max-heap=16M big_sort.lisp
ZEPO_MAX_HEAP=32M zepo run                    # honored unless CLI overrides
zepo --max-heap=4M --max-heap=… not supported # one flag only
```

The same value is used for both generations; a finer-grained split may land later.

### Script convention

Scripts use an explicit entry point — no magic:

```scheme
(define (main)
  (println "hello"))

(main)
```

### Compiling to a native binary

The `build` subcommand compiles a Lisp program to a standalone native executable.

```sh
zepo build                      # reads project.lisp → entry + project name
zepo build program.lisp         # produces ./program
zepo build program.lisp -o name # produces ./name
```

**How it works:**

1. Scans the program for imports and recursively discovers all module dependencies
2. Reads and embeds each module as static data
3. Generates a Zig source file containing the embedded modules
4. Compiles the Zig file to a native binary via `zig build`

The resulting executable requires no Zig, no Zepo runtime, and no `.lisp` files.
It can be distributed as a single portable binary.

**Example:**

```sh
zepo build examples/macros.lisp -o demo
./demo   ; runs standalone
```

When called with no arguments, `build` reads `project.lisp` from the current
directory, uses its `entry` field as the source file, and uses the project
`name` field as the output binary name. When called with an explicit file,
the output filename defaults to that file's stem (e.g., `program.lisp` →
`program`). Use `-o` to override in either mode.

---

## Comments

```scheme
; single-line comment — extends to end of line

#| block comment
   spans multiple lines |#
```

Both forms are valid anywhere whitespace is allowed. Block comments do not nest.

---

## Data Types

| Type | Literal example | Notes |
|------|----------------|-------|
| **fixnum** | `42`, `-7` | 63-bit signed integer |
| **float** | `3.14`, `-0.5` | 64-bit IEEE 754, heap-allocated |
| **boolean** | `#t`, `#f` | Only `#f` and `()` are falsy |
| **character** | `#\a`, `#\space`, `#\newline` | Unicode codepoint |
| **string** | `"hello"` | Immutable UTF-8 sequence |
| **symbol** | `foo`, `my-var?` | Interned; identity compared with `eq?` |
| **keyword** | `:key`, `:long` | A symbol whose name starts with `:` — used as plist keys by convention |
| **nil** | `()`, `'()` | The empty list; also `#f`-like in boolean context |
| **pair** | `(cons 1 2)` | Mutable; `(1 . 2)` dot notation in output |
| **vector** | `(make-vector 3 0)` | Mutable, zero-indexed |
| **procedure** | `(lambda (x) x)` | Closure or primitive |

### Character literals

```scheme
#\a          ; letter a
#\A          ; letter A
#\0          ; digit zero
#\space      ; space (U+0020)
#\newline    ; newline (U+000A)
#\tab        ; tab (U+0009)
```

### Quote shorthand

```scheme
'foo         ; => (quote foo)
'(1 2 3)     ; => (quote (1 2 3))
```

---

## Special Forms

Special forms are recognized by the compiler and are not first-class values.

### `define`

Bind a name in the current environment, or define a function.

```scheme
(define x 42)
(define (square n) (* n n))
(square 5)   ; => 25

; Variadic function
(define (sum . args)
  (fold-left + 0 args))
(sum 1 2 3)  ; => 6
```

#### Docstrings

`define`, `lambda`, `define-syntax`, and `module` all accept an optional
`:documentation "..."` keyword. The docstring is stored on the binding's
metadata and is readable via `(documentation 'name)` and from LSP hover.

```scheme
(define foo
  :documentation "adds one to x"
  (lambda (x) (+ x 1)))

(define (bar x)
  :documentation "doubles x"
  (* 2 x))

(define-syntax my-when
  :documentation "evaluates body when cond is true"
  (syntax-rules ()
    ((_ c b ...) (if c (begin b ...) '()))))

(documentation 'foo)   ; => "adds one to x"
(documentation 'bar)   ; => "doubles x"
```

The `introspect` module exports `(describe sym)` which prints the name and
docstring (or "(no documentation)") in REPL-friendly form.

### `lambda`

Create a closure.

```scheme
(lambda (x) (* x x))
((lambda (x y) (+ x y)) 3 4)   ; => 7

; Rest argument
(lambda (first . rest) rest)

; Keyword arguments
(lambda (x #:verbose v) ...)
```

### Keyword arguments

A keyword parameter is written `:name DEFAULT` in the parameter list, where
DEFAULT is a literal (string/number/boolean/`'()`). Inside the body the
parameter is referred to by the bare `name`. At a call, pass `:name value`.

```scheme
(define (greet name :greeting "Hello")
  (string-append greeting ", " name "!"))

(greet "Alice")                            ; => "Hello, Alice!"   (default)
(greet "Alice" :greeting "Hi")             ; => "Hi, Alice!"

(define (configure port :host "localhost" :debug #f)
  (list host port debug))
(configure 8080 :host "example.com")       ; => ("example.com" 8080 #f)
```

By default an **unknown** keyword is an error:

```scheme
(greet "Alice" :loud #t)                    ; error: unknown keyword
```

**Keyword tolerance / forwarding.** Add a rest parameter after the keyword
params and the *unrecognized* keyword pairs are collected into it as a flat
plist — so a function can handle some keys and forward the rest:

```scheme
(define (open-window x :title "" . rest)
  (set-title! x title)
  (apply make-widget x rest))              ; forward the keys it didn't handle

(define (f x :a 0 . rest) (list x a rest))
(f 1 :a 2 :zzz 9)                          ; => (1 2 (:zzz 9))   :a bound, :zzz forwarded
```

Without a rest parameter, unknown keywords still error — the tolerance is
opt-in by declaring `. rest`.

### `if`

Conditional expression. The else branch is optional (returns `()` when omitted
and the test is false).

```scheme
(if (> x 0) "positive" "non-positive")
(if condition then-expr)
```

### `cond`

Multi-branch conditional. Use `#t` as the catch-all clause.

```scheme
(cond ((< n 0) "negative")
      ((= n 0) "zero")
      (#t       "positive"))
```

### `let`

Bind variables in parallel (bindings do not see each other).

```scheme
(let ((x 1)
      (y 2))
  (+ x y))   ; => 3

; Named let — creates a local recursive function
(let loop ((i 0) (acc 0))
  (if (= i 5)
      acc
      (loop (+ i 1) (+ acc i))))   ; => 10
```

### `let*`

Bind variables sequentially (each binding sees the previous ones).

```scheme
(let* ((x 2)
       (y (* x 3)))
  y)   ; => 6
```

### `letrec`

Bind mutually recursive definitions.

```scheme
(letrec ((even? (lambda (n) (if (= n 0) #t (odd?  (- n 1)))))
         (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
  (even? 10))   ; => #t
```

### `begin`

Evaluate a sequence of expressions; return the last value.

```scheme
(begin
  (display "hello")
  (newline)
  42)   ; => 42
```

### `quote`

Return a datum unevaluated.

```scheme
(quote foo)       ; => foo
(quote (1 2 3))   ; => (1 2 3)
'(a b c)          ; shorthand
```

### `set!`

Mutate an existing binding.

```scheme
(define x 0)
(set! x 99)
x   ; => 99
```

### `and`

Short-circuit conjunction. Returns the last truthy value, or `#f` on first
falsy value.

```scheme
(and 1 2 3)      ; => 3
(and 1 #f 3)     ; => #f
(and)            ; => #t
```

### `or`

Short-circuit disjunction. Returns the first truthy value, or `#f`.

```scheme
(or #f #f 42)    ; => 42
(or #f #f)       ; => #f
(or)             ; => #f
```

### `when`

Execute body only when condition is truthy.

```scheme
(when (> x 0)
  (display "positive")
  (newline))
```

### `unless`

Execute body only when condition is falsy.

```scheme
(unless done?
  (do-more-work))
```

### `parameterize`

Dynamically bind one or more parameter objects (see
[`make-parameter`](#make-parameter)) for the dynamic extent of the body, then
restore the previous values on exit — including exit via `raise`.

```scheme
(define p (make-parameter 10))
(p)                              ; => 10  (default)
(parameterize ((p 20)) (p))      ; => 20
(p)                              ; => 10  (restored)

; multiple bindings
(define a (make-parameter 1))
(define b (make-parameter 2))
(parameterize ((a 10) (b 20)) (+ (a) (b)))   ; => 30
```

Bindings are **fiber-local**: a value parameterized in one fiber is invisible
to others. Value expressions are evaluated in the outer dynamic environment
*before* the new bindings are installed (R7RS order). A non-local exit out of
the body (e.g. `raise` caught by an enclosing `guard`) unwinds the bindings,
so the handler sees the restored values.

### `defstruct` and generic functions

Single-dispatch generic functions dispatch on the **type of the first argument**
(R7RS/CLOS-lite; `:primary` methods only — no multiple dispatch or method
combination yet). User types come from `defstruct`.

```scheme
(defstruct circle radius)        ; → make-circle, circle?, circle-radius
(defstruct rect w h)             ; → make-rect, rect?, rect-w, rect-h

(defgeneric area (shape))
(defmethod area ((s circle)) (* 3.14159 (circle-radius s) (circle-radius s)))
(defmethod area ((s rect))   (* (rect-w s) (rect-h s)))

(area (make-circle 10))          ; => 314.159
(area (make-rect 3 4))           ; => 12
```

- `(defstruct NAME field...)` defines a record type: constructor `(make-NAME …)`,
  predicate `(NAME? x)`, and an accessor `(NAME-field x)` per field. A struct
  value is a tagged vector; `(type-of v)` returns its type symbol.
- `(type-of x)` → a symbol naming x's type: `integer`, `float`, `boolean`,
  `char`, `null`, `pair`, `string`, `symbol`, `vector`, `procedure`,
  `hash-table`, `bytevector`, `parameter`, `fiber`, `foreign`, or a struct's
  type. Numbers report the *specific* type (`integer`/`float`), not `number`.
- `(defgeneric NAME (args...))` declares a generic. `(defmethod NAME ((arg
  TYPE) more...) body...)` adds a method specialized on TYPE (any `type-of`
  result, including primitives like `string`). Calling a generic with no
  applicable method raises a clear error naming the generic and the type.

Dispatch is `type-of` + one hash-table lookup + `apply` — comparable to a
hand-rolled hash-table-of-procedures. There is no subtype/`is-a` hierarchy:
`type-of` is exact, so a method on `circle` does not apply to other types. See
ADR 0006.

### `unwind-protect` and the with-X resource convention

The canonical resource pattern is **acquire → use → release-no-matter-what**,
built on `unwind-protect`:

```scheme
(let ((r (open-thing)))
  (unwind-protect
    (use r)          ; protected body — its value is returned
    (close r)))      ; cleanup — runs on normal return AND on error
```

`(unwind-protect BODY CLEANUP...)` returns BODY's value; CLEANUP runs whether
BODY returns normally or raises (the condition is re-raised after cleanup). It
is a macro over `guard`. **Limitation:** Zepo has no continuations and no
VM-level unwind hook, so a restart that transfers control *out* of BODY (see
[`restart-case`](#handler-bind-and-restart-case)) bypasses CLEANUP. For ordinary
control flow this is exactly right.

Wrap recurring acquire/release pairs in a `with-X` macro so callers can't forget
the release. The convention: `(with-X (binding) body...)` binds the resource,
runs `body`, and releases on the way out. Two are in the stdlib as models:

| Macro | Description |
|-------|-------------|
| `(with-output-string (p) body...)` | Bind `p` to a fresh string output port; write with `port-display`/`port-write`; returns the accumulated string. |
| `(with-temp-file (path) body...)` | Create a unique temp file, bind `path`, delete it afterward (even on error). |

```scheme
(with-output-string (p)
  (port-display p "x = ") (port-write p 42))   ; => "x = 42"

(with-temp-file (path)
  (file-write-string path "hi")
  (file-read-string path))                     ; => "hi"  (file then deleted)
```

A `with-X` macro for your own resource is a few lines:

```scheme
(defmacro with-thing (binding . body)
  (let ((r (car binding)))
    `(let ((,r (open-thing)))
       (unwind-protect (begin ,@body) (close-thing ,r)))))
```

### `handler-bind` and `restart-case`

Restarts are named recovery points (Common-Lisp style). Unlike `guard` /
`with-exception-handler` — which *unwind* the stack before the handler runs —
`handler-bind` installs a **non-unwinding** handler that runs at the signal
site, with the signaling context still live. That is what lets a handler choose
a restart established *inside* the protected code.

```scheme
(restart-case
  (handler-bind (lambda (cond) (invoke-restart 'use-default 0))
    (error "no value"))
  (use-default (v) :report "supply a default" v))
; => 0
```

- `(restart-case BODY (NAME (param...) [:report STR] clause-body...) ...)`
  evaluates BODY with the named restarts available. If BODY completes normally,
  its value is returned and the clauses are ignored. If a handler calls
  `(invoke-restart 'NAME arg...)`, control transfers into the matching clause
  (bound to the args); `restart-case` then evaluates to the clause's value.
- `(handler-bind HANDLER body...)` runs HANDLER `(HANDLER condition)` in place
  when a condition is signaled in `body`. The handler either transfers
  (`invoke-restart`, or lets an outer unwinding handler catch) or **declines**
  by returning normally — then the condition propagates to the next handler.
- `(invoke-restart 'NAME arg...)` transfers to the most-recent restart NAME.
- `(compute-restarts)` → list of active restart names, most-recent first.
  `(find-restart 'NAME)` → the name or `#f`. `(restart-report 'NAME)` → its
  `:report` string or `#f`.

Restarts are fiber-local and survive `(yield)` within the body. Use
`guard`/`with-exception-handler` when you just want to catch-and-recover; reach
for `handler-bind` + `restart-case` when the recovery decision belongs to an
outer caller. The REPL surfaces active restarts interactively on an otherwise
unhandled condition. (No `dynamic-wind`/cleanup runs during a restart transfer
— Zepo has no `unwind-protect` yet; see ADR 0005.)

### `defmacro`

Define a macro — a compile-time code transformer.

A macro receives unevaluated arguments and returns code that is evaluated in the
caller's environment. Macros can call other macros and be recursive.

```scheme
(defmacro my-when (test . body)
  `(if ,test (begin ,@body)))

(my-when #t
  (display "true")
  (newline))
```

Syntax: `(defmacro name (params...) body...)` or with rest: `(defmacro name (first . rest) body...)`.

The macro body is evaluated in the definition environment. Use quasiquote to construct
the returned code template. The macro result is then compiled and evaluated in the caller's scope.

### Quasiquote, unquote, and unquote-splicing

Quasiquote (`` ` ``) creates a template with holes that are filled with unquoted expressions.

**Reader syntax:**

```scheme
`expr         ; => (quasiquote expr)
,expr         ; inside a quasiquote: (unquote expr)
,@expr        ; inside a quasiquote: (unquote-splicing expr)
```

**Quasiquote** — creates a template where sub-expressions are quoted (not evaluated):

```scheme
`(list 1 2 3)   ; => (list 1 2 3)
```

**Unquote** — evaluates a sub-expression and inserts its value into the template:

```scheme
(define x 5)
`(x is ,x)      ; => (x is 5)
```

**Unquote-splicing** — evaluates a sub-expression (which should return a list) and
splices its elements into the surrounding list:

```scheme
(define nums '(1 2 3))
`(start ,@nums end)   ; => (start 1 2 3 end)
```

**Nesting:** Nested quasiquotes require nested unquotes. Unquoting is scoped to the
innermost quasiquote that contains it:

```scheme
`(a ,(+ 1 2))           ; => (a 3)
`(a `(b ,,x))           ; Template containing a nested template
```

**Macros and quasiquote:** Quasiquote is most useful in macro definitions, where it
builds code templates:

```scheme
(defmacro swap! (a b)
  `(let ((tmp ,a))
     (set! ,a ,b)
     (set! ,b tmp)))

(define x 1)
(define y 2)
(swap! x y)
; x is now 2, y is now 1
```

**Macro examples:**

```scheme
; Conditional with side effects
(defmacro my-unless (test . body)
  `(if ,test #f (begin ,@body)))

; Iteration macro
(defmacro dotimes (binding . body)
  (let ((var (car binding))
        (n   (cadr binding)))
    `(let loop ((,var 0))
       (when (< ,var ,n)
         ,@body
         (loop (+ ,var 1))))))

(dotimes (i 5)
  (display i)
  (display " "))  ; prints: 0 1 2 3 4
```

Macros can call macros, including themselves. The macro system fully supports
lexical scope and closures, allowing sophisticated meta-programming.

### `define-syntax` and `syntax-rules`

`define-syntax` binds a name to a pattern-based transformer. Unlike `defmacro`,
it is **hygienic**: names introduced by the macro body cannot capture variables
from the call site, and call-site variables cannot be shadowed by the macro's
internal bindings.

```scheme
(define-syntax name
  (syntax-rules (literal ...)
    ((pattern) template)
    ...))
```

`syntax-rules` takes a list of **literals** and one or more **clauses**, each a
`(pattern template)` pair. When the macro is used, patterns are tried in order;
the first match expands to the corresponding template.

**Pattern syntax:**

| Pattern element | Meaning |
|-----------------|---------|
| `_` | Matches anything, binds nothing |
| `name` | Pattern variable — matches anything, binds the matched form |
| `literal` | Matches only that exact symbol (must appear in the literals list) |
| `(p1 p2 ...)` | Matches a list |
| `(p ... rest)` | `p ...` matches zero or more forms; `rest` matches the remainder |

**Template syntax:**

| Template element | Meaning |
|------------------|---------|
| `name` | Substituted with the form bound to the pattern variable |
| `(t ...)` | Expands `t` once per element matched by the preceding `...` pattern variable |
| Any other symbol | Inserted literally (renamed for hygiene if it is a binding site) |

**Basic example — `when`:**

```scheme
(define-syntax when
  (syntax-rules ()
    ((_ test body ...)
     (if test (begin body ...)))))

(when (> x 0)
  (display x)
  (newline))
```

**Ellipsis — `and`:**

Ellipsis (`...`) matches zero or more sub-forms and expands them in the template:

```scheme
(define-syntax and
  (syntax-rules ()
    ((_)        #t)
    ((_ e)      e)
    ((_ e1 e2 ...)
     (if e1 (and e2 ...) #f))))

(and #t #t #t)   ; => #t
(and #t #f #t)   ; => #f
(and)            ; => #t
```

**Literals — matching specific keywords:**

Symbols listed in the literals list match only themselves, not arbitrary forms:

```scheme
(define-syntax my-case-lambda
  (syntax-rules (=>)
    ((_ (=> result)) result)))

(my-case-lambda (=> 42))   ; => 42
```

**Hygiene — `or`:**

Macro-introduced bindings are automatically renamed so they never capture
call-site variables:

```scheme
(define-syntax or
  (syntax-rules ()
    ((_ e1 e2)
     (let ((t e1))       ; 't' is renamed fresh — cannot shadow user's 't'
       (if t t e2)))))

(define t 99)
(or #f t)   ; => 99  (not #f — user's 't' is safe)
```

**`swap!` with hygiene:**

```scheme
(define-syntax swap!
  (syntax-rules ()
    ((_ a b)
     (let ((tmp a))
       (set! a b)
       (set! b tmp)))))

(define x 1)
(define y 2)
(swap! x y)
; x => 2, y => 1
```

**`defmacro` vs `define-syntax`:**

| | `defmacro` | `define-syntax` |
|-|-----------|-----------------|
| Style | Procedural — write Scheme code that returns code | Declarative — pattern / template rules |
| Hygiene | Manual (use `gensym` when needed) | Automatic |
| Ellipsis | Manual recursion | Built-in `...` |
| Best for | Complex transformations, computed templates | Most everyday macros |

---

## Primitives

Arity `-1` means variadic (zero or more arguments).

### Arithmetic

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `+` | -1 | Sum; `(+)` → `0` |
| `-` | -1 | Subtract; `(- x)` negates |
| `*` | -1 | Product; `(*)` → `1` |
| `/` | -1 | Divide; `(/ x)` inverts |
| `modulo` | 2 | Modulo (result sign matches divisor) |
| `remainder` | 2 | Remainder (result sign matches dividend) |
| `quotient` | 2 | Integer quotient (truncates toward zero) |
| `floor` | 1 | Round toward -∞ |
| `ceiling` | 1 | Round toward +∞ |
| `round` | 1 | Round to nearest even |
| `truncate` | 1 | Round toward zero |
| `exact->inexact` | 1 | Convert integer to float |
| `inexact->exact` | 1 | Convert float to integer (truncates) |

```scheme
(+ 1 2 3)         ; => 6
(- 10 3)          ; => 7
(- 5)             ; => -5
(* 2 3 4)         ; => 24
(/ 10 2)          ; => 5
(modulo 10 3)     ; => 1
(remainder -7 3)  ; => -1
(quotient 7 2)    ; => 3
(floor 3.7)       ; => 3.0
(ceiling 3.2)     ; => 4.0
(exact->inexact 5); => 5.0
(inexact->exact 3.9) ; => 3
```

> **Specialization note:** the compiler emits dedicated bytecode opcodes for
> 2-arg calls to `+`, `-`, `*`, `=`, `<`, `>`, `eq?`, `cons`, `car`, `cdr`,
> `null?`, `pair?`, and `modulo`. These take an inline fixnum fast path and
> only fall back to the prim on non-fixnum operands. Consequence: rebinding
> these names at runtime via `define` or `set!` will not take effect inside
> already-compiled call sites. Same trade-off as Chez/Racket.

### Bitwise

Bitwise primitives operate on integers. Float arguments are truncated to i64
before the operation; the result is always an exact integer.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `bitwise-and` | -1 | Bitwise AND; `(bitwise-and)` → `-1` (all bits set) |
| `bitwise-or` | -1 | Bitwise OR; `(bitwise-or)` → `0` |
| `bitwise-xor` | -1 | Bitwise XOR; `(bitwise-xor)` → `0` |
| `bitwise-not` | 1 | Bitwise complement (one's complement) |
| `arithmetic-shift` | 2 | Shift `n` left by `shift` bits; negative `shift` shifts right (arithmetic, sign-extending) |
| `bit-count` | 1 | Population count — number of 1-bits in the binary representation |

```scheme
(bitwise-and 12 10)         ; => 8    ; 1100 & 1010 = 1000
(bitwise-or  12 10)         ; => 14   ; 1100 | 1010 = 1110
(bitwise-xor 12 10)         ; => 6    ; 1100 ^ 1010 = 0110
(bitwise-not 0)             ; => -1
(arithmetic-shift 1 4)      ; => 16   ; 1 << 4
(arithmetic-shift 256 -4)   ; => 16   ; 256 >> 4
(bit-count 255)             ; => 8    ; eight 1-bits
(bitwise-and)               ; => -1   ; identity
(bitwise-or)                ; => 0    ; identity
(bitwise-xor)               ; => 0    ; identity
```

### Comparison

All accept two or more arguments and return `#t` if the relation holds for
every adjacent pair.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `=` | -1 | Numeric equal |
| `<` | -1 | Less than |
| `>` | -1 | Greater than |
| `<=` | -1 | Less than or equal |
| `>=` | -1 | Greater than or equal |

```scheme
(= 1 1 1)    ; => #t
(< 1 2 3)    ; => #t
(>= 5 5 3)   ; => #t
```

### Pairs and Lists

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `cons` | 2 | Construct a pair |
| `car` | 1 | First element of pair |
| `cdr` | 1 | Rest of pair |
| `pair?` | 1 | Is a pair? |
| `null?` | 1 | Is nil/empty list? |
| `list` | -1 | Build a proper list |

```scheme
(cons 1 2)           ; => (1 . 2)
(cons 1 '())         ; => (1)
(car '(a b c))       ; => a
(cdr '(a b c))       ; => (b c)
(pair? '(1))         ; => #t
(null? '())          ; => #t
(list 1 2 3)         ; => (1 2 3)
```

### Vectors

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `vector` | -1 | Construct vector from args |
| `make-vector` | -1 | `(make-vector len)` or `(make-vector len fill)` |
| `vector-ref` | 2 | `(vector-ref v i)` — zero-indexed |
| `vector-set!` | 3 | `(vector-set! v i val)` — mutates in place |
| `vector-length` | 1 | Number of elements |
| `vector?` | 1 | Is a vector? |
| `vector-copy` | -1 | `(vector-copy v [start [end]])` — new copy, optional range |
| `vector-copy!` | -1 | `(vector-copy! to at from [start [end]])` — destructive copy into target at offset |
| `vector-fill!` | -1 | `(vector-fill! v val [start [end]])` — destructive fill |
| `vector-append` | -1 | Concatenate vectors into new vector |

Vectors render as `#(1 2 3)` notation in both display and write.

```scheme
(vector 1 2 3)                ; => #(1 2 3)
(define v (make-vector 3 0))  ; => #(0 0 0)
(vector-set! v 1 99)
(vector-ref v 1)              ; => 99
(vector-length v)             ; => 3

(vector-copy #(1 2 3))        ; => #(1 2 3)
(vector-copy #(1 2 3 4) 1 3)  ; => #(2 3)

(define v2 (make-vector 5 0))
(vector-copy! v2 1 #(a b c))  ; => #(0 a b c 0)

(vector-fill! #(1 2 3) 0)     ; => #(0 0 0)

(vector-append #(1 2) #(3 4)) ; => #(1 2 3 4)
```

### Bytevectors

R7RS-compatible mutable byte arrays. Each element is an exact integer in
the range 0–255. Distinct from vectors, which hold arbitrary Scheme values.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `bytevector` | -1 | `(bytevector b ...)` — construct from individual bytes |
| `make-bytevector` | -1 | `(make-bytevector n)` or `(make-bytevector n fill)` — fill defaults to 0 |
| `bytevector?` | 1 | Is a bytevector? |
| `bytevector-length` | 1 | Number of bytes |
| `bytevector-u8-ref` | 2 | `(bytevector-u8-ref bv i)` → 0..255 |
| `bytevector-u8-set!` | 3 | `(bytevector-u8-set! bv i val)` — mutates byte at index |
| `bytevector-copy` | -1 | `(bytevector-copy bv [start [end]])` — new copy, optional range |
| `bytevector-append` | -1 | `(bytevector-append bv ...)` — concatenate bytevectors |
| `bytevector->string` | 1 | `(bytevector->string bv)` — interpret bytes as UTF-8 string |
| `string->bytevector` | 1 | `(string->bytevector str)` — encode string as UTF-8 bytes |
| `bytevector-u16be-ref` | 2 | `(bytevector-u16be-ref bv offset)` → big-endian u16 |
| `bytevector-u16le-ref` | 2 | `(bytevector-u16le-ref bv offset)` → little-endian u16 |
| `bytevector-u32be-ref` | 2 | `(bytevector-u32be-ref bv offset)` → big-endian u32 |
| `bytevector-u32le-ref` | 2 | `(bytevector-u32le-ref bv offset)` → little-endian u32 |
| `bytevector-u16be-set!` | 3 | `(bytevector-u16be-set! bv offset val)` — write big-endian u16 |
| `bytevector-u16le-set!` | 3 | `(bytevector-u16le-set! bv offset val)` — write little-endian u16 |
| `bytevector-u32be-set!` | 3 | `(bytevector-u32be-set! bv offset val)` — write big-endian u32 |
| `bytevector-u32le-set!` | 3 | `(bytevector-u32le-set! bv offset val)` — write little-endian u32 |

Bounds errors raise `ContractViolation`. Multi-byte accessors require the
full word to fit: u16 needs `offset+1 < length`, u32 needs `offset+3 < length`.

```scheme
(define bv (make-bytevector 4 0))
(bytevector-u32be-set! bv 0 305419896)  ; 0x12345678
(bytevector-u32be-ref bv 0)             ; => 305419896
(bytevector-u8-ref bv 0)                ; => 18  (0x12)
(bytevector-u8-ref bv 3)                ; => 120 (0x78)

(bytevector->string (string->bytevector "hello"))  ; => "hello"

(define b2 (bytevector 1 2 3 4))
(bytevector-length b2)                  ; => 4
(bytevector-copy b2 1 3)                ; => bytevector of bytes 2 3
(bytevector-append (bytevector 1 2) (bytevector 3 4))  ; length 4

(define bv5 (make-bytevector 4 0))
(bytevector-u16be-set! bv5 0 43981)     ; 0xABCD
(bytevector-u8-ref bv5 0)               ; => 171 (0xAB, high byte)
(bytevector-u8-ref bv5 1)               ; => 205 (0xCD, low byte)
(bytevector-u16le-ref bv5 0)            ; => 52651 (0xCDAB — LE reads low first)
```

### Strings

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `string-length` | 1 | Number of characters |
| `string-ref` | 2 | `(string-ref s i)` — returns character |
| `string-append` | -1 | Concatenate strings |
| `substring` | -1 | `(substring s start)` or `(substring s start end)` |
| `string->number` | 1 | Parse string to number, or `#f` |
| `number->string` | 1 | Convert number to string |
| `string->symbol` | 1 | Intern string as symbol |
| `symbol->string` | 1 | Symbol name as string |
| `string-upcase` | 1 | ASCII uppercase |
| `string-downcase` | 1 | ASCII lowercase |
| `gensym` | 0–1 | Generate a fresh unique symbol; optional string/symbol prefix |

```scheme
(string-length "hello")        ; => 5
(string-ref "hello" 1)         ; => #\e
(string-append "foo" "bar")    ; => "foobar"
(substring "hello" 1 3)        ; => "el"
(substring "hello" 2)          ; => "llo"
(string->number "42")          ; => 42
(number->string 3.14)          ; => "3.14"
(string->symbol "foo")         ; => foo
(symbol->string 'bar)          ; => "bar"
(string-upcase "hello")        ; => "HELLO"
(gensym)                       ; => #:g0
(gensym "tmp")                 ; => #:tmp1
(eq? (gensym) (gensym))        ; => #f  (always fresh)
```

### Characters

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `char->integer` | 1 | Unicode codepoint of character |
| `integer->char` | 1 | Character from codepoint |
| `char->string` | 1 | Single-character string |

```scheme
(char->integer #\A)   ; => 65
(integer->char 97)    ; => #\a
(char->string #\x)    ; => "x"
```

### Predicates

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `symbol?` | 1 | Is a symbol? |
| `boolean?` | 1 | Is `#t` or `#f`? |
| `number?` | 1 | Is a number (fixnum or float)? |
| `integer?` | 1 | Is a fixnum? |
| `float?` | 1 | Is a float? |
| `char?` | 1 | Is a character? |
| `string?` | 1 | Is a string? |
| `procedure?` | 1 | Is a procedure (closure or primitive)? |

```scheme
(number? 42)       ; => #t
(integer? 3.0)     ; => #f
(string? "hi")     ; => #t
(procedure? car)   ; => #t
```

### Equality

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `eq?` | 2 | Identity equality (pointer / immediate) |
| `equal?` | 2 | Structural equality (deep) |

```scheme
(eq? 'foo 'foo)          ; => #t  (symbols are interned)
(eq? '(1) '(1))          ; => #f  (different heap objects)
(equal? '(1 2) '(1 2))   ; => #t
(equal? "hi" "hi")       ; => #t
```

### I/O

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `display` | 1 | Print value without quotes/escapes |
| `write` | 1 | Print value in read-back form (strings quoted, chars as `#\x`) |
| `newline` | 0 | Print a newline |
| `display-to-string` | 1 | Like `display` but returns a string instead of printing |
| `write-to-string` | 1 | Like `write` but returns a string instead of printing |
| `format` | -1 | `(format fmt arg ...)` → string — interpolate args into format string |
| `argv` | 0 | Return command-line args as a list of strings |

`format` directives: `~a` (display), `~s` (write), `~%` (newline), `~~` (literal tilde).

```scheme
(display "hello")               ; prints: hello
(write "hello")                 ; prints: "hello"
(newline)                       ; prints newline
(display-to-string '(1 2 3))    ; => "(1 2 3)"
(write-to-string "hi")          ; => "\"hi\""
(format "~a + ~a = ~a" 1 2 3)   ; => "1 + 2 = 3"
(format "line~%end")            ; => "line\nend"
(argv)                          ; => ("zepo" "foo.lisp" ...)
```

### File I/O

All paths are relative to the process working directory unless absolute.
`file-append-string` creates the file if it does not exist.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `file-read-string` | 1 | `(file-read-string path)` → string — read entire file |
| `file-write-string` | 2 | `(file-write-string path str)` — write (truncate) file |
| `file-append-string` | 2 | `(file-append-string path str)` — append to file, creating if needed |
| `file-exists?` | 1 | `(file-exists? path)` → bool |
| `file-delete` | 1 | `(file-delete path)` — delete file; raises `IOError` if it does not exist |
| `file-read-bytes` | 1 | `(file-read-bytes path)` → bytevector — read entire file as raw bytes |
| `file-write-bytes` | 2 | `(file-write-bytes path bv)` — write bytevector to file (truncate) |

```scheme
(file-write-string "/tmp/out.txt" "hello\n")
(file-append-string "/tmp/out.txt" "world\n")
(file-read-string "/tmp/out.txt")   ; => "hello\nworld\n"
(file-exists? "/tmp/out.txt")       ; => #t
(file-delete "/tmp/out.txt")
(file-exists? "/tmp/out.txt")       ; => #f
```

### Input Ports

R7RS-compatible streaming input port primitives for processing files line-by-line
without loading the entire file into memory.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `open-input-file` | 1 | `(open-input-file path)` → port — open file for reading; raises `IOError` if not found |
| `close-input-port` | 1 | `(close-input-port port)` — close the port; safe to call once |
| `current-input-port` | 0 | `(current-input-port)` → a port wrapping stdin (fd 0) |
| `input-port?` | 1 | `(input-port? val)` → `#t` if val is an input port |
| `read-line` | 0–1 | `(read-line)` or `(read-line port)` → string or eof-object; strips trailing newline |
| `read-char` | 1 | `(read-char port)` → character or eof-object |
| `peek-char` | 1 | `(peek-char port)` → character without advancing, or eof-object |
| `eof-object` | 0 | `(eof-object)` → the EOF singleton |
| `eof-object?` | 1 | `(eof-object? val)` → `#t` if val is the EOF singleton |

```scheme
; Read a file line by line
(define p (open-input-file "data.ndjson"))
(let loop ((line (read-line p)))
  (unless (eof-object? line)
    (display line)
    (newline)
    (loop (read-line p))))
(close-input-port p)

; Read characters one at a time
(define p (open-input-file "greet.txt"))
(let loop ((c (read-char p)))
  (unless (eof-object? c)
    (display c)
    (loop (read-char p))))
(close-input-port p)

; Peek without consuming
(define p (open-input-file "data.txt"))
(display (peek-char p))  ; => first char (not consumed)
(display (read-char p))  ; => same first char
(close-input-port p)

; eof-object singleton
(eof-object? (eof-object))   ; => #t
(eof-object? "hello")        ; => #f

; stdin port
(define stdin-port (current-input-port))
(input-port? stdin-port)     ; => #t
```

### Directory and Path

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `directory-list` | 1 | `(directory-list path)` → list of entry name strings |
| `make-directory` | 1 | `(make-directory path)` — create directory and any missing parents |
| `current-directory` | 0 | `(current-directory)` → absolute path string of CWD |
| `file-directory?` | 1 | `(file-directory? path)` → `#t` if path is a directory, else `#f` |
| `file-size` | 1 | `(file-size path)` → integer byte count, or `#f` if not a regular file |
| `file-mtime` | 1 | `(file-mtime path)` → integer Unix timestamp (seconds), or `#f` if path doesn't exist |
| `file-type` | 1 | `(file-type path)` → symbol `'file`, `'directory`, `'symlink`, or `'other`; `#f` if not found |

```scheme
(make-directory "/tmp/zepo-test/sub")
(current-directory)              ; => "/Users/me/myproject"
(directory-list ".")             ; => ("src" "lib" "project.lisp" ...)

(file-directory? ".")            ; => #t
(file-directory? "build.zig")    ; => #f
(file-size "build.zig")          ; => 14613  (bytes)
(file-size ".")                  ; => #f  (not a regular file)
(file-mtime "build.zig")         ; => 1779283282  (Unix seconds)
(file-mtime "/nonexistent")      ; => #f
(file-type ".")                  ; => directory
(file-type "build.zig")          ; => file
(file-type "/nonexistent")       ; => #f
```

### Environment and Shell

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `getenv` | 1 | `(getenv name)` → string or `#f` if unset |
| `shell` | 1 | `(shell cmd)` → stdout string (exit code ignored) |
| `shell/status` | 1 | `(shell/status cmd)` → integer exit code |
| `getpid` | 0 | `(getpid)` → integer process ID |

```scheme
(getenv "HOME")                         ; => "/Users/me"
(getenv "UNDEFINED_VAR")               ; => #f
(shell "echo hello")                    ; => "hello\n"
(shell/status "test -f project.lisp")  ; => 0 or 1
(getpid)                               ; => 12345
```

### Subprocess Management

Spawn child processes with full stdin/stdout pipe control. The child's stderr is inherited from the parent.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `process-spawn` | -1 | `(process-spawn cmd arg ...)` → process — fork+exec with stdin/stdout pipes |
| `process?` | 1 | Return `#t` if value is a process handle |
| `process-pid` | 1 | `(process-pid proc)` → integer PID |
| `process-send` | 2 | `(process-send proc str)` — write string to child's stdin |
| `process-close-stdin` | 1 | `(process-close-stdin proc)` — send EOF to child's stdin |
| `process-recv` | 2 | `(process-recv proc max-bytes)` → string — read up to N bytes from stdout (empty = EOF) |
| `process-recv-line` | 1 | `(process-recv-line proc)` → string or eof-object — read one line |
| `process-recv-all` | 1 | `(process-recv-all proc)` → string — read all remaining stdout |
| `process-wait` | 1 | `(process-wait proc)` → integer — wait for exit, return exit code |
| `process-kill` | 2 | `(process-kill proc sig-num)` — send signal to child (use `signal-number` for names) |

```scheme
; Run a command and collect its output
(define p (process-spawn "ls" "-la"))
(display (process-recv-all p))
(process-wait p)

; Pipe input to a child
(define p (process-spawn "cat"))
(process-send p "hello\n")
(process-send p "world\n")
(process-close-stdin p)
(display (process-recv-all p))   ; => "hello\nworld\n"
(process-wait p)

; Read output line by line
(define p (process-spawn "seq" "1" "5"))
(let loop ()
  (let ((line (process-recv-line p)))
    (unless (eof-object? line)
      (display line) (newline)
      (loop))))
(process-wait p)

; Kill a process
(define p (process-spawn "sleep" "60"))
(process-kill p (signal-number 'SIGTERM))
(process-wait p)
```

### Signals

Register Lisp thunks as OS signal handlers. The VM polls for pending signals
every 1000 opcodes, so handlers fire promptly during any active computation.

Supported signal names: `SIGHUP`, `SIGINT`, `SIGQUIT`, `SIGTERM`, `SIGUSR1`, `SIGUSR2`.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `signal-set!` | 2 | `(signal-set! sig-sym handler-fn)` → `#f`; installs handler for named signal |
| `signal-number` | 1 | `(signal-number sig-sym)` → integer signal number, or `#f` for unknown names |

```scheme
;; Graceful shutdown on SIGTERM
(signal-set! 'SIGTERM (lambda ()
  (println "shutting down")
  (exit 0)))

;; Interrupt handler
(signal-set! 'SIGINT (lambda ()
  (println "interrupted")
  (exit 1)))

;; Query signal numbers
(signal-number 'SIGTERM)   ; => 15
(signal-number 'SIGINT)    ; => 2
(signal-number 'SIGHUP)    ; => 1
(signal-number 'SIGUSR1)   ; => 10
(signal-number 'SIGUSR2)   ; => 12
(signal-number 'SIGFOO)    ; => #f  (unknown)
```

### String Output Ports

String output ports accumulate text without printing to stdout, useful for capturing
formatted output or building strings.

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `open-output-string` | 0 | Create a string output port |
| `string-port?` | 1 | Is a string output port? |
| `get-output-string` | 1 | Return accumulated string from port |
| `port-display` | 2 | `(port-display port val)` — display-style write to port |
| `port-write` | 2 | `(port-write port val)` — write-style write to port |

```scheme
(define out (open-output-string))
(port-display out "hello")
(port-display out " ")
(port-display out "world")
(get-output-string out)   ; => "hello world"

(define out2 (open-output-string))
(port-write out2 "test")
(get-output-string out2)  ; => "test"
```

### Apply and Not

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `not` | 1 | Boolean negation |
| `apply` | -1 | `(apply f arg... lst)` — call `f` with args spread from `lst` |
| `values` | -1 | Return single value or multiple values as a tagged box |
| `call-with-values` | 2 | `(call-with-values producer consumer)` — call producer, spread values to consumer |

```scheme
(not #f)                  ; => #t
(not 42)                  ; => #f
(apply + '(1 2 3))        ; => 6
(apply + 1 2 '(3 4))      ; => 10

; Multiple values
(values 1)                ; => 1
(values 1 2 3)            ; => tagged box containing (1 2 3)

(define (producer)
  (values 10 20 30))

(call-with-values producer (lambda (a b c) (+ a b c)))
; => 60
```

### Parameter objects

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `make-parameter` | 1–2 | `(make-parameter init [converter])` → a fiber-local parameter object |

A parameter object is itself a procedure:

- `(p)` returns its current dynamic value — the most recent
  [`parameterize`](#parameterize) binding in the current fiber, or its default.
- `(p v)` sets the current binding's value (or the default if none is active).

If a `converter` procedure is supplied, it is applied to the initial value and
to every value subsequently bound via `parameterize` or `(p v)`.

```scheme
(define radix (make-parameter 10))
(radix)                                   ; => 10
(parameterize ((radix 16)) (radix))       ; => 16
(radix)                                   ; => 10

; converter coerces every bound value
(define level (make-parameter 0 (lambda (x) (max 0 x))))
(parameterize ((level -5)) (level))       ; => 0
```

See [`parameterize`](#parameterize) for the binding form and its
fiber-local / unwind semantics.

### Error

Zepo uses R7RS-style structured exceptions.

```scheme
(error "message")
(error "bad value:" x)   ; additional args are appended to the message
```

`error` raises an error condition object. Additional arguments beyond the
message string become the condition's *irritants*.

```scheme
; raise any value as an exception
(raise 42)

; with-exception-handler — low-level catch
(with-exception-handler
  (lambda (e)
    (if (error-object? e)
      (display (error-object-message e))
      (display "unknown error")))
  (lambda () (error "oops" 1 2)))

; guard — structured catch with clauses (evaluated top-to-bottom)
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

---

### Advice and dynamic hooks

Two ways to inject cross-cutting behaviour (logging, timing, instrumentation)
into existing functions.

**Production idiom — a parameterize'd hook.** Hold the hook in a
[parameter](#make-parameter) and switch it on for a dynamic extent. No global
mutation, composes cleanly, and is fiber-local. Prefer this in library code.

```scheme
(define *trace* (make-parameter #f))

(define (http-get url)
  (when (*trace*) (display (string-append "GET " url "\n")))
  (do-fetch url))

(parameterize ((*trace* #t))
  (http-get "/a")        ; traced
  (http-get "/b"))       ; traced
(http-get "/c")          ; not traced — *trace* restored to #f
```

**REPL / debug idiom — `advise`.** `(advise 'name wrapper)` replaces the global
function bound to `name` with a wrapper. The wrapper is called as
`(wrapper orig arg ...)` — `orig` is the function bound just before this advise;
call it with `(apply orig args)`. Advice **stacks**; `(unadvise 'name)` restores
the original (pre-advice) function and drops all advice on it. Because `advise`
mutates the global binding, it is best for interactive debugging and
instrumentation, not library code — reach for the parameterize hook there.

```scheme
(define (greet name) (string-append "Hello, " name))

(advise 'greet
  (lambda (orig . args)
    (string-append "[" (apply orig args) "]")))
(greet "Ann")            ; => "[Hello, Ann]"

(advised? 'greet)        ; => #t
(unadvise 'greet)
(greet "Ann")            ; => "Hello, Ann"
```

An optional **advice type** selects how the advice combines with the original:

```scheme
(advise 'f :before  (lambda (x) (log x)))         ; run before; result ignored
(advise 'f :after   (lambda (result x) (log result))) ; run after; orig's result returned
(advise 'f :around  (lambda (orig x) (* 2 (orig x)))) ; wrap; call orig yourself
(advise 'f :override (lambda (x) 'stubbed))        ; replace entirely
```

| Function | Description |
|----------|-------------|
| `(advise 'name fn)` | Wrap the global `name`; `fn` is called `(fn orig arg ...)` (i.e. `:around`). Stacks. |
| `(advise 'name :before fn)` | Run `(fn arg ...)` before the original; its result is ignored. |
| `(advise 'name :after fn)` | Run `(fn result arg ...)` after; the original's result is returned. |
| `(advise 'name :around fn)` | `fn` receives `(orig arg ...)` and calls `orig` itself. |
| `(advise 'name :override fn)` | `fn` replaces the original entirely. |
| `(unadvise 'name)` | Restore the original function and drop all advice on `name`. |
| `(advised? 'name)` | True if `name` currently has advice installed. |

### Hooks (extension points)

A **hook** is a named list of functions — the canonical way for a library to
expose an extension point. The library runs the hook at the relevant moment;
users register functions on it. Provided by the `hooks` library:

```scheme
(import hooks (add-hook remove-hook run-hooks run-hooks/results clear-hooks))

;; --- library side: expose and run a hook ---
(define (save-document doc)
  (run-hooks 'before-save doc)        ; call every handler with the document
  (write-to-disk doc))

;; --- user side: register a handler ---
(add-hook 'before-save (lambda (doc) (validate doc)))
(add-hook 'before-save (lambda (doc) (log "saving" doc)))
```

| Function | Description |
|----------|-------------|
| `(add-hook name fn)` | Register `fn` under `name` (runs in registration order). |
| `(remove-hook name fn)` | Unregister `fn` from `name`. |
| `(run-hooks name arg...)` | Call every handler under `name` with `arg...`. |
| `(run-hooks/results name arg...)` | Like `run-hooks` but returns the list of results. |
| `(clear-hooks name)` | Remove all handlers under `name`. |

Handlers run in registration order and each receives the args passed to
`run-hooks`. This is distinct from two related mechanisms:

- [`advise`/`unadvise`](#advice-and-dynamic-hooks) *wraps an existing function*
  (you don't control its call sites); hooks are *explicit extension points* the
  author placed with `run-hooks`.
- The testing framework's `before-each`/`after-each`/`before-all`/`after-all`
  are **intentionally a separate** abstraction: they are scoped to the
  `describe` tree and run with lifecycle ordering (outer→inner before, inner→
  outer after), not a flat named list — so they live in the testing library,
  not here.

---

## Standard Library

All functions below are defined in `lib/stdlib.lisp` and are always available.

### List — Basics

#### `(length lst)`
Count elements of a proper list.
```scheme
(length '(a b c))   ; => 3
```

#### `(append lst1 lst2)`
Concatenate two lists.
```scheme
(append '(1 2) '(3 4))   ; => (1 2 3 4)
```

#### `(reverse lst)`
Reverse a list.
```scheme
(reverse '(1 2 3))   ; => (3 2 1)
```

#### `(map f list ...)`
Apply `f` to corresponding elements across one or more lists; collect results. Stops at the end of the shortest list.
```scheme
(map (lambda (x) (* x x)) '(1 2 3))   ; => (1 4 9)
(map + '(1 2 3) '(4 5 6))             ; => (5 7 9)
(map + '(1 2) '(10 20) '(100 200))    ; => (111 222)
```

#### `(filter pred lst)`
Keep elements where `pred` returns truthy.
```scheme
(filter odd? '(1 2 3 4 5))   ; => (1 3 5)
```

#### `(for-each f list ...)`
Call `f` on corresponding elements for side effects; return `()`. Accepts multiple lists like `map`.
```scheme
(for-each display '(1 2 3))                           ; prints: 123
(for-each (lambda (a b) (display (+ a b))) '(1 2) '(3 4))  ; prints: 36
```

#### `(fold-left f acc lst)`
Left fold: `(f (f (f acc e1) e2) e3)`.
```scheme
(fold-left + 0 '(1 2 3 4))   ; => 10
```

#### `(fold-right f init lst)`
Right fold: `(f e1 (f e2 (f e3 init)))`.
```scheme
(fold-right cons '() '(1 2 3))   ; => (1 2 3)
```

#### `(assoc key lst)`
Find first pair in association list whose `car` is `equal?` to `key`. Returns the pair or `#f`.
```scheme
(assoc 'b '((a 1) (b 2) (c 3)))   ; => (b 2)
```

#### `(member x lst)`
Find first tail of `lst` where `car` is `equal?` to `x`. Returns the tail or `#f`.
```scheme
(member 3 '(1 2 3 4))   ; => (3 4)
```

#### Composites — `caar cadr cdar cddr caddr cadddr`
```scheme
(cadr '(a b c))    ; => b
(caddr '(a b c))   ; => c
```

### Numeric

#### `(zero? n)` `(positive? n)` `(negative? n)`
```scheme
(zero? 0)       ; => #t
(positive? 1)   ; => #t
(negative? -1)  ; => #t
```

#### `(abs n)`
```scheme
(abs -5)   ; => 5
```

#### `(min2 a b)` `(max2 a b)`
Two-argument min/max (use `min`/`max` from stdlib for variadic).
```scheme
(min2 3 7)   ; => 3
```

### List — Extended (stdlib)

#### `(list? x)`
True for proper lists (including nil); handles cycles (returns `#f`).
```scheme
(list? '(1 2 3))   ; => #t
(list? '(1 . 2))   ; => #f
```

#### `(list-ref lst n)`
Element at zero-based index.
```scheme
(list-ref '(a b c) 1)   ; => b
```

#### `(list-tail lst n)`
Tail starting at index `n`.
```scheme
(list-tail '(a b c d) 2)   ; => (c d)
```

#### `(last lst)`
Last element.
```scheme
(last '(1 2 3))   ; => 3
```

#### `(take lst n)`
First `n` elements.
```scheme
(take '(a b c d) 2)   ; => (a b)
```

#### `(drop lst n)`
All but the first `n` elements.
```scheme
(drop '(a b c d) 2)   ; => (c d)
```

#### `(iota count [start [step]])`
Generate a list of `count` numbers.
```scheme
(iota 5)          ; => (0 1 2 3 4)
(iota 5 1)        ; => (1 2 3 4 5)
(iota 4 0 2)      ; => (0 2 4 6)
```

#### `(any pred lst)`
True if any element satisfies `pred`.
```scheme
(any negative? '(1 -2 3))   ; => #t
```

#### `(every pred lst)`
True if all elements satisfy `pred`.
```scheme
(every positive? '(1 2 3))   ; => #t
```

#### `(find pred lst)`
First element satisfying `pred`, or `#f`.
```scheme
(find even? '(1 3 4 5))   ; => 4
```

#### `(remove pred lst)`
Remove elements satisfying `pred`.
```scheme
(remove even? '(1 2 3 4 5))   ; => (1 3 5)
```

#### `(count pred lst)`
Count elements satisfying `pred`.
```scheme
(count odd? '(1 2 3 4 5))   ; => 3
```

#### `(flatten lst)`
Recursively flatten nested lists.
```scheme
(flatten '(1 (2 3) (4 (5 6))))   ; => (1 2 3 4 5 6)
```

#### `(zip list ...)`
Transpose lists into a list of lists.
```scheme
(zip '(1 2 3) '(a b c))   ; => ((1 a) (2 b) (3 c))
```

#### `(sort lst less?)`
Stable merge sort.
```scheme
(sort '(3 1 4 1 5 9) <)   ; => (1 1 3 4 5 9)
```

### Association Lists (stdlib)

An alist is a list of `(key . value)` pairs.

#### `(alist-get key al)`
Value for `key`, or `#f`.
```scheme
(alist-get 'b '((a . 1) (b . 2)))   ; => 2
```

#### `(alist-set key val al)`
Return new alist with `key` mapped to `val` (old entry removed).
```scheme
(alist-set 'b 99 '((a . 1) (b . 2)))   ; => ((b . 99) (a . 1))
```

#### `(alist-delete key al)`
Return alist without `key`.
```scheme
(alist-delete 'a '((a . 1) (b . 2)))   ; => ((b . 2))
```

#### `(alist-keys al)` `(alist-values al)`
```scheme
(alist-keys '((a . 1) (b . 2)))     ; => (a b)
(alist-values '((a . 1) (b . 2)))   ; => (1 2)
```

#### `(assq key lst)`
Like `assoc` but uses `eq?` instead of `equal?`.
```scheme
(assq 'b '((a 1) (b 2)))   ; => (b 2)
```

#### `(memq x lst)`
Like `member` but uses `eq?`.
```scheme
(memq 'b '(a b c))   ; => (b c)
```

### Numeric — Extended (stdlib)

#### `(min first . rest)` `(max first . rest)`
```scheme
(min 3 1 4 1 5)   ; => 1
(max 3 1 4 1 5)   ; => 5
```

#### `(even? n)` `(odd? n)`
```scheme
(even? 4)   ; => #t
(odd? 7)    ; => #t
```

#### `(gcd a b)` `(lcm a b)`
```scheme
(gcd 12 8)   ; => 4
(lcm 4 6)    ; => 12
```

#### `(expt base exp)`
Fast integer exponentiation (binary method).
```scheme
(expt 2 10)   ; => 1024
```

### Characters (stdlib)

#### Comparison: `char=?` `char<?` `char>?` `char<=?` `char>=?`
```scheme
(char<? #\a #\b)   ; => #t
```

#### `(char-alphabetic? c)` `(char-numeric? c)` `(char-whitespace? c)`
```scheme
(char-alphabetic? #\a)    ; => #t
(char-numeric? #\5)       ; => #t
(char-whitespace? #\space) ; => #t
```

#### `(char-upcase c)` `(char-downcase c)`
```scheme
(char-upcase #\a)     ; => #\A
(char-downcase #\Z)   ; => #\z
```

### Strings (stdlib)

#### Comparison: `string=?` `string<?` `string>?` `string<=?` `string>=?`
```scheme
(string<? "abc" "abd")   ; => #t
```

#### `(string->list s)`
```scheme
(string->list "abc")   ; => (#\a #\b #\c)
```

#### `(list->string chars)`
```scheme
(list->string '(#\a #\b #\c))   ; => "abc"
```

#### `(string-contains s sub)`
Return index of first occurrence, or `#f`.
```scheme
(string-contains "hello world" "world")   ; => 6
```

#### `(string-join strs sep)`
```scheme
(string-join '("a" "b" "c") ", ")   ; => "a, b, c"
```

#### `(string-split s delim)`
```scheme
(string-split "a,b,c" ",")   ; => ("a" "b" "c")
```

#### `(string-trim s)` `(string-trim-left s)` `(string-trim-right s)`
Strip ASCII whitespace.
```scheme
(string-trim "  hello  ")   ; => "hello"
```

### Higher-Order Utilities (stdlib)

#### `(compose f g)`
`(compose f g)` returns `(lambda (x) (f (g x)))`.
```scheme
((compose car cdr) '(1 2 3))   ; => 2
```

#### `(identity x)`
Returns `x` unchanged.

#### `(const x)`
Returns a procedure that ignores its arguments and always returns `x`.
```scheme
((const 42) 'anything)   ; => 42
```

#### `(flip f)`
Returns `(lambda (a b) (f b a))`.
```scheme
((flip -) 1 10)   ; => 9
```

### I/O (stdlib)

#### `(println x)`
`display` followed by `newline`.
```scheme
(println "hello")   ; prints: hello\n
```

#### `(writeln x)`
`write` followed by `newline`.
```scheme
(writeln "hello")   ; prints: "hello"\n
```

### Vectors (stdlib)

#### `(vector->list v)`
```scheme
(vector->list (make-vector 3 0))   ; => (0 0 0)
```

#### `(list->vector lst)`
```scheme
(list->vector '(1 2 3))   ; => #(1 2 3)
```

#### `(vector-map f v)`
Apply `f` to each element; return new vector.
```scheme
(vector-map (lambda (x) (* x 2)) (list->vector '(1 2 3)))
; => #(2 4 6)
```

#### `(vector-for-each f v)`
Call `f` on each element for side effects.

### Misc (stdlib)

#### `(assert expr)`
Raise an error if `expr` is falsy.
```scheme
(assert (= 1 1))   ; passes
(assert #f)        ; error: "Assertion failed"
```

### Hash tables

First-class mutable hash tables with `equal?` key semantics. Open-addressed
with linear probing; resizes automatically past a 0.75 load factor.

Hash tables are **portable**: a table whose keys and values are all portable
can be sent across a channel to a worker (it is deep-copied into the receiver's
heap). This makes them a convenient carrier for JSON-shaped data — see
[Channels](#channels). A table containing a non-portable value (a closure,
port, fiber, or foreign object) raises `NonPortableValue` when sent.

#### `(make-hash-table)` → `ht`

Creates an empty hash table with default capacity.

#### `(hash-table? x)` → `#t | #f`

#### `(hash-set! ht key value)` → NIL

Insert or update. Returns NIL. `()` (nil) is **not** a permitted key and
raises `error.ContractViolation`.

#### `(hash-get ht key [default])` → `value`

Returns the stored value, or `default` if the key is absent. If `default`
is omitted, returns `#f`.

#### `(hash-contains? ht key)` → `#t | #f`

#### `(hash-delete! ht key)` → `#t | #f`

Removes the entry, returns `#t` if something was removed.

#### `(hash-size ht)` → count

#### `(hash-keys ht)` `(hash-values ht)` → vector

Snapshot vectors of all keys / values in unspecified order.

#### `(hash-for-each f ht)`

Calls `(f key value)` once per entry. Iteration order is unspecified and not
guaranteed stable across mutations.

#### `(hash->alist ht)` `(alist->hash al)`

Convert between hash tables and association lists. Useful for merging into
JSON (which uses alists) or for serialization.

```scheme
(define config (make-hash-table))
(hash-set! config "timeout" 30)
(hash-set! config "retries" 3)
(hash-get config "timeout")            ; => 30
(hash-size config)                     ; => 2
(hash-for-each
  (lambda (k v) (display k) (display "=") (display v) (newline))
  config)
```

---

### Result objects (stdlib)

Result objects express success or failure without throwing. Used by the FFI
layer and available for any library that prefers explicit results over raised
errors.

Shape:

- **Ok**: `(cons 'ok value)`
- **Err**: `(list 'err kind-symbol message-string)`

#### `(ok value)`

Wrap a success value. Returns `(ok . value)`.

#### `(err kind message)`

Build an error result. `kind` is a symbol (e.g. `'type-mismatch`), `message`
is a string.

```scheme
(err 'parse-error "unexpected token at offset 42")
```

#### `(ok? r)` `(err? r)`

Predicates. Both return `#f` for non-result values.

#### `(result-value r)`

Extract the value from an ok result. Behavior on an err result is undefined —
check with `ok?` first.

#### `(err-kind r)` `(err-message r)`

Extract fields from an err result. Undefined on ok results.

```scheme
(define r (parse-something input))
(if (ok? r)
    (use (result-value r))
    (display (err-message r)))
```

---

### JSON

Built-in primitives — no import needed.

#### `(json-parse str)` → `result`

Parses a JSON string. Returns `(ok value)` on success or `(err kind msg)` on
failure (see [Result objects](#result-objects-stdlib) for the result API).

Type mapping from JSON to Zepo:

| JSON | Zepo |
|------|------|
| object | hash table (string keys) |
| array | vector |
| string | string |
| number | number |
| `true` / `false` | `#t` / `#f` |
| `null` | `()` |

#### `(json-stringify value)` → `result`

Serializes a Lisp value to a JSON string. Returns `(ok json-str)` on success
or `(err kind msg)` on failure.

Type mapping from Zepo to JSON:

| Zepo | JSON |
|------|------|
| hash table | object |
| alist (list of pairs) | object |
| vector | array |
| string | string |
| number | number |
| `#t` / `#f` | `true` / `false` |
| `()` | `null` |

```scheme
(define r (json-parse "{\"x\": 1, \"y\": [2, 3]}"))
(when (ok? r)
  (define obj (result-value r))
  (hash-get obj "x"))               ; => 1

(json-stringify (list (cons "name" "zepo") (cons "version" 1)))
; => (ok "{\"name\":\"zepo\",\"version\":1}")
```

---

### Plists (stdlib)

A plist is a flat list of alternating keys and values: `(key1 val1 key2 val2 ...)`.
Keywords (`:key`) are the conventional key type.

#### `(plist-get pl key)`
Value for `key`, or `#f`.
```scheme
(plist-get '(:x 1 :y 2) :x)   ; => 1
```

#### `(plist-set pl key val)`
Return new plist with `key` set to `val`.
```scheme
(plist-set '(:x 1) :y 2)   ; => (:x 1 :y 2)
```

#### `(plist-has? pl key)`
```scheme
(plist-has? '(:x 1) :x)   ; => #t
```

#### `(plist-keys pl)` `(plist-values pl)`
```scheme
(plist-keys '(:a 1 :b 2))     ; => (:a :b)
(plist-values '(:a 1 :b 2))   ; => (1 2)
```

#### `(plist-delete pl key)`
Return plist without `key` and its value.

#### `(plist->alist pl)` `(alist->plist al)`
Convert between representations.
```scheme
(plist->alist '(:a 1 :b 2))   ; => ((:a . 1) (:b . 2))
(alist->plist '((:a . 1) (:b . 2)))   ; => (:a 1 :b 2)
```

### Extended cXr (stdlib)

`caaar`, `cdaar`, `cadar`, `cddar`, `caadr`, `cdadr`, `cdddr`,
`cadaar`, `caddar`, `cadadr`, `caaddr`, `cddddr`, `caaaar`

---

## Module System

Zepo has three container forms — `module`, `lib`, and `package` — plus an
`import` form with legacy bare syntax and a tier-dispatch keyword syntax. See
[Container forms](#container-forms) at the top of this document for the full
container reference including metadata keywords and `zepo new` scaffolding.

**When to use each:**

| Form | Use case |
|------|----------|
| `(module ...)` | In-project namespacing — groups definitions, hides internals |
| `(lib ...)` | Single-file distributable library installed with `zepo install` |
| `(package ...)` | Multi-file distributable — entry in `src/main.lisp` |

### Defining a module

```scheme
(module my-math
  (export square cube)

  (define (square x) (* x x))
  (define (cube x)   (* x x x))
  (define (helper x) x))   ; private — not exported
```

`export` lists the names that become part of the module's public interface.
All other definitions are private to the module.

### Defining a lib (distributable single-file library)

```scheme
; parser/parser.lisp
(lib parser
  :version "1.0.0"
  :docstring "A simple parser"
  (export parse-tokens)

  (define (parse-tokens src) ...))
```

Install with `zepo install ./parser`. Import with `(import :libs (parser))`.

### Defining a package (distributable multi-file container)

```scheme
; myapp/src/main.lisp
(package myapp
  :version "1.0.0"
  :depends (parser))
```

Sub-modules live in `src/` and are imported from `main.lisp`:

```scheme
(import :modules (myapp.core myapp.utils))
```

Install with `zepo install ./myapp`. Import with `(import :packages (myapp))`.

### Importing — keyword tier dispatch (preferred)

The keyword form makes the search tier explicit:

```scheme
(import :modules  (utils math))       ; project-local .lisp/.zbc files
(import :libs     (parser json))      ; installed single-file libs
(import :packages (myapp framework))  ; installed multi-module packages

; Mix tiers in one form:
(import :modules (utils) :libs (json) :packages (framework))
```

Each tier searches a different path:

| Tier | Paths searched |
|------|----------------|
| `:modules` | Project-local paths (project.lisp paths, `ZEPO_PATH`) |
| `:libs` | `~/.local/lib/zepo/<name>/` per installed lib |
| `:packages` | `~/.local/lib/zepo/` root — loads `<name>/src/main.lisp` |

### Importing — legacy bare form

The bare form is still supported and searches the combined module path:

```scheme
(import my-math)
(square 5)   ; => 25

; Selective import — only the listed names
(import my-math (only square))
(square 3)   ; => 9
; (cube 2)   ; would be an error — not imported
```

### Aliased import

Import with an alias to create a namespace:

```scheme
(import math/core as mc)
(mc.sin 0)    ; => 0
(mc.cos 0)    ; => 1
```

### Import inside function bodies

`import` can appear inside function bodies, executing at runtime via the
`IMPORT` opcode. On first execution it auto-loads the module from the search
path (exactly like a top-level import), so conditional/lazy imports work:

```scheme
(define (use-math)
  (import math/core (only clamp))
  (clamp 42 0 10))   ; => 10

(use-math)
```

The module's body forms are evaluated on the current call stack (via `execFn`,
not a fresh scheduler) so the outer VM frame is preserved. One consequence: a
module whose **top-level body yields or spawns a fiber** cannot be auto-loaded
from this nested context and raises `ContractViolation` — import such modules at
the top level instead.

### Rules

- Modules are not first-class values; `module`/`lib`/`package`/`import`/`export` are
  syntactic forms. `import` can appear at top level or inside function bodies.
- `import` inside a module body imports into that module's environment.
- Exporting a name that is never defined raises `ExportNameUndefined`.
- Importing a name that conflicts with an existing binding: existing bindings
  silently win. No `ImportNameConflict` error is raised (re-exports of
  primitives into modules are silently skipped).
- Nested modules/libs/packages are not allowed.

### Example — project module

```scheme
; modules/utils.lisp
(module utils
  (export greet)
  (define (greet name)
    (string-append "Hello, " name "!")))

; main.lisp — bare import (searches module path)
(import utils)
(println (greet "world"))   ; prints: Hello, world!
```

### Example — installed lib

```scheme
; parser/parser.lisp
(lib parser
  :version "0.1.0"
  (export parse))

; Install once:
; zepo install ./parser

; Any program:
(import :libs (parser))
(parse some-source)
```

---

## The clap Library

`clap` is a command-line argument parser shipped as `lib/clap.lisp`. Load it
on demand with `(import clap)`, which finds `clap.lisp` via the module search
path.

The data model is entirely plist-based. Every object (program, command, option,
positional, parse result, parse error) is a flat plist.

### Constructors

```scheme
(make-program name summary description version root-cmd)
(make-command name summary)
(make-option  key help)       ; key is a symbol used in the result plist
(make-positional key help)
```

### Builder — `opt-set`

Set any field on a plist object (used to configure options and commands).

```scheme
(define my-opt
  (opt-set
    (opt-set
      (make-option 'output "Output file")
      :long "output")
    :short \o))
```

Common option fields: `:long`, `:short`, `:kind` (`flag` `counter` `value` `multi`),
`:type` (`string` `integer` `number` `boolean`), `:required`, `:default`,
`:value-name`.

Common command fields: `:description`, `:aliases`, `:handler`, `:subcommands`.

### Building commands

```scheme
(define cmd
  (cmd-add-option
    (cmd-add-positional
      (make-command "serve" "Start the server")
      (opt-set (make-positional 'host "Host to bind") :required #t))
    (opt-set (opt-set (make-option 'port "Port") :long "port") :short \p)))
```

### Parsing

```scheme
(define prog
  (make-program "myapp" "My application" "" "1.0" root-cmd))

(define result (parse prog (cdr (argv))))
```

Or use the all-in-one entry point, which reads `(argv)` automatically and
calls the command handler if one is set:

```scheme
(run prog)
```

### Inspecting results

```scheme
(parse-result? result)   ; => #t on success
(parse-error?  result)   ; => #t on failure

; Success accessors
(result-option     result 'port)     ; value of --port option
(result-positional result 'host)     ; value of positional
(result-command    result)           ; the matched command plist
(result-remaining  result)           ; unconsumed arguments

; Error accessors
(error-kind        result)   ; symbol: unknown-option, missing-required, ...
(error-message     result)   ; human-readable string
(error-token       result)   ; the offending token string or #f
(error-suggestions result)   ; list of similar valid names
```

### Help and error rendering

```scheme
(render-help  prog cmd)   ; => multi-line help string
(render-usage prog cmd)   ; => single-line usage string
(render-error err)        ; => error + hint string
```

### Minimal example

```scheme
(import clap)

(define root
  (cmd-add-option
    (make-command "greet" "Greet someone")
    (opt-set (opt-set (make-option 'name "Name to greet")
                      :long "name")
             :required #t)))

(define prog (make-program "greet" "A greeter" "" "1.0" root))

(define result (parse prog (cdr (argv))))

(if (parse-error? result)
    (begin (display (render-error result)) (newline))
    (println (string-append "Hello, " (result-option result 'name) "!")))
```

```sh
zepo greet.lisp --name Alice
# => Hello, Alice!
```

---

## String Utilities

The following string utilities are defined in `lib/stdlib.lisp` and are always available.

#### `(string-repeat str n)`
Repeat `str` `n` times.
```scheme
(string-repeat "ab" 3)   ; => "ababab"
(string-repeat "x" 0)    ; => ""
```

#### `(string-replace str old new)`
Replace all occurrences of `old` with `new`.
```scheme
(string-replace "hello world" "o" "0")   ; => "hell0 w0rld"
(string-replace "aaa" "a" "bb")          ; => "bbbbbbbb"
```

#### `(string-pad-left str width ch)`
Pad `str` on the left with character `ch` to reach `width`. If `str` is already >= `width`, return unchanged.
```scheme
(string-pad-left "5" 3 #\0)   ; => "005"
(string-pad-left "hello" 3 #\*)  ; => "hello"
```

#### `(string-pad-right str width ch)`
Pad `str` on the right with character `ch` to reach `width`. If `str` is already >= `width`, return unchanged.
```scheme
(string-pad-right "5" 3 #\0)   ; => "500"
(string-pad-right "hi" 5 #\.)   ; => "hi..."
```

#### `(string-prefix? prefix str)`
Return `#t` if `str` starts with `prefix`, otherwise `#f`.
```scheme
(string-prefix? "hello" "hello world")   ; => #t
(string-prefix? "bye" "hello world")     ; => #f
```

#### `(string-suffix? suffix str)`
Return `#t` if `str` ends with `suffix`, otherwise `#f`.
```scheme
(string-suffix? "world" "hello world")   ; => #t
(string-suffix? "earth" "hello world")   ; => #f
```

#### `(string-index str ch [start])`
Return the zero-based index of the first occurrence of character `ch` at or after position `start` (default 0). Return `#f` if not found.
```scheme
(string-index "hello" #\l)       ; => 2
(string-index "hello" #\l 3)     ; => 3
(string-index "hello" #\x)       ; => #f
```

---

## Date and Time

The following date and time primitives are always available.

#### `(current-time-ms)`
Return current Unix time in milliseconds.
```scheme
(current-time-ms)   ; => 1755012345000
```

#### `(epoch->date ms)`
Convert epoch milliseconds to an association list with keys `year`, `month`, `day`, `hour`, `minute`, `second`.
```scheme
(epoch->date 1640988000000)
; => ((year . 2021) (month . 12) (day . 31) (hour . 10) (minute . 0) (second . 0))
```

#### `(date->epoch year month day hour minute second)`
Convert a date to epoch milliseconds.
```scheme
(date->epoch 2021 12 31 10 0 0)   ; => 1640988000000
```

#### `(time-format ms fmt)`
Format epoch milliseconds as a string using strftime-style format. Supported directives: `%Y` (year), `%m` (month), `%d` (day), `%H` (hour), `%M` (minute), `%S` (second), `%%` (literal percent).
```scheme
(time-format 1640988000000 "%Y-%m-%d %H:%M:%S")
; => "2021-12-31 10:00:00"
(time-format 1640988000000 "%Y/%m/%d")
; => "2021/12/31"
```

---

## Test Framework

The test framework is provided by `lib/stdlib.lisp` and available without import.

#### `(clear-tests!)`
Reset the global test registry. Useful for multi-file test isolation.
```scheme
(clear-tests!)
```

#### `(make-suite)`
Create an isolated test suite. Returns a pair `(cons register! run!)` containing a register function and a run function.
```scheme
(define my-suite (make-suite))
(define (register! test-fn) ((car my-suite) test-fn))
(define (run! [name]) ((cdr my-suite) name))

(register! (lambda () (assert-equal 1 1)))
(run!)   ; run the isolated suite
```

#### `(run-tests/tap [name])`
Run all registered tests and output TAP (Test Anything Protocol) version 14 format. Exits with status code 1 if any test fails, 0 if all pass.
```scheme
(run-tests/tap)         ; run all tests
(run-tests/tap "suite1")  ; run with a label
```

TAP output:
```
1..2
ok 1 - test passed
not ok 2 - assertion failed
```

---

## Fibers

Zepo has cooperative green threads called *fibers*. Fibers share a single OS thread; they yield control voluntarily at `(yield)`, `(sleep ...)`, and any blocking I/O call. The scheduler uses `poll(2)` so blocked fibers never burn CPU.

### Primitives

#### `(spawn thunk)`
Create and schedule a new fiber that will call `(thunk)` with no arguments. Returns a fiber handle immediately; the thunk runs on the next scheduler step.
```scheme
(define f (spawn (lambda () (+ 1 2))))
```

#### `(yield)`
Yield control to the scheduler, allowing other fibers to run. The current fiber is re-enqueued and resumes shortly.
```scheme
(yield)
```

#### `(sleep seconds)`
Park the current fiber for `seconds` (integer or float). The scheduler uses `poll(2)` with a timeout — no busy-waiting.
```scheme
(sleep 1)       ; sleep 1 second
(sleep 0.25)    ; sleep 250 ms
```

#### `(fiber-join handle)`
Suspend the current fiber until the fiber identified by `handle` completes. Returns the fiber's result value. If the target fiber errored, raises `UserError`.
```scheme
(define f (spawn (lambda () 42)))
(fiber-join f)   ; => 42
```

#### `(fiber? obj)`
Return `#t` if `obj` is a fiber handle.

#### `(fiber-done? handle)`
Return `#t` if the fiber has completed successfully.

#### `(fiber-errored? handle)`
Return `#t` if the fiber terminated with an error.

#### `(fiber-result handle)`
Return the fiber's result (if done) or error value (if errored). Raises `ContractViolation` if the fiber is still running.

### Concurrency pattern

All TCP I/O primitives are non-blocking. When a socket would block, the calling fiber is suspended and re-scheduled when the fd is ready. This means you can write straightforward sequential code inside each fiber:

```scheme
; Echo server: one fiber per connection
(define (handle-conn conn)
  (let loop ()
    (let ((line (tcp-recv-line conn)))
      (if (eof-object? line) (tcp-close conn)
          (begin
            (tcp-send conn (string-append line "\n"))
            (loop))))))

(define srv (tcp-listen 8080))
(let accept-loop ()
  (let ((conn (tcp-accept srv)))
    (spawn (lambda () (handle-conn conn))))
  (accept-loop))
```

---

## Evaluating forms (`eval`)

#### `(eval form)` → value
Compile and run an s-expression `form` in the current VM's top-level global
environment, returning its result. Because Zepo code is data (lists and
symbols), `eval` is what turns a form received over a channel — or built with
quasiquote — back into running code:

```scheme
(eval 42)                              ; => 42
(eval (list '+ 1 2))                   ; => 3
((eval '(lambda (x) (* x x))) 5)       ; => 25
```

This is the receiving half of the worker code-as-data pattern: the parent sends
a quoted/quasiquoted form over a channel (forms are portable), and the worker
calls `(eval ...)` on it:

```scheme
;; in the worker entry
(let ((task (channel-recv! in)))
  (channel-send! out (eval task)))
```

**Synchronous only (v1).** A form passed to `eval` must run to completion
without yielding — if it spawns a fiber or yields, `eval` raises an error
rather than suspending. Long-running concurrency belongs in the worker's own
top-level entry (which runs under the scheduler), not inside an `eval`'d form.

**`eval` is dynamic code execution.** Only `eval` forms you trust; treat data
arriving from untrusted sources as you would any code.

## Channels

Channels are thread-safe FIFO queues for passing values between fibers or across worker OS threads. A channel can be unbuffered (capacity 0, rendezvous semantics) or buffered (capacity N).

Only **portable values** can cross a channel between workers: `nil`, booleans, fixnums, floats, chars, strings, symbols, bytevectors, pairs/lists of portable values, vectors of portable values, and hash tables whose keys and values are themselves portable. The value is deep-copied into the receiver's heap, so the two sides never share mutable state. Non-portable values (closures, ports, fibers, foreign objects, cyclic structures) raise `NonPortableValue`. To send **code** to a worker, pass it as a quoted/quasiquoted *form* — an ordinary portable list — and have the receiver compile it with [`eval`](#evaluating-forms-eval); see [Workers](#workers). Within a single-threaded fiber context all values pass through fine because no copy is needed.

### Primitives

#### `(make-channel [capacity])` → channel
Create a channel with optional buffer size (default 0 — unbuffered). Capacity 0 means sender and receiver must rendezvous: the sender parks until a receiver is ready.

```scheme
(define ch (make-channel))    ; unbuffered
(define ch (make-channel 8))  ; buffered, 8 slots
```

#### `(channel? obj)` → bool
Return `#t` if `obj` is a channel.

#### `(channel-send! ch val)` → `#void`
Send `val` to `ch`. If the buffer is full (or the channel is unbuffered and no receiver is waiting), the calling fiber parks until space is available. Raises `ContractViolation` if the channel is closed.

#### `(channel-recv! ch)` → value
Receive the next value from `ch`. If the channel is empty, the calling fiber parks until a value arrives. Raises `ContractViolation` if the channel is closed and empty.

#### `(channel-try-send! ch val)` → bool
Non-blocking send. Returns `#t` if the value was delivered, `#f` if the channel is full. Raises `ContractViolation` if the channel is closed.

#### `(channel-try-recv! ch)` → value | `#f`
Non-blocking receive. Returns the value if one is available, `#f` if the channel is empty.

#### `(channel-close ch)` → `#void`
Close the channel. Any fibers parked in `channel-recv!` are woken and will see `ContractViolation`. Subsequent sends also raise `ContractViolation`.

#### `(channel-empty? ch)` → bool
Return `#t` if the channel has no buffered values and no parked senders.

### Patterns

**Producer/consumer pipeline:**
```scheme
(define ch (make-channel 4))

(spawn (lambda ()                      ; producer
  (let loop ((i 0))
    (channel-send! ch i)
    (loop (+ i 1)))))

(let loop ()                           ; consumer (main fiber)
  (display (channel-recv! ch)) (newline)
  (loop))
```

**Fan-out: distribute work across N fibers:**
```scheme
(define work-ch (make-channel 16))

(define (worker id)
  (let loop ()
    (let ((item (channel-recv! work-ch)))
      (display (list id item)) (newline)
      (loop))))

(spawn (lambda () (worker 0)))
(spawn (lambda () (worker 1)))
(spawn (lambda () (worker 2)))
```

---

## Workers

Workers are OS threads, each with a completely isolated VM instance (own GC heap, symbol table, global environment, stdlib). They communicate with the spawning VM exclusively through shared `Channel` objects.

Because workers have separate heaps, only **portable values** (see Channels above) can transit channels between a worker and its parent. The worker's entry is supplied either as a Lisp **source string** or as a **portable form** (for example a quasiquoted lambda with captured values spliced in by value); either is evaluated fresh in the worker's stdlib context and must yield a callable.

### Primitives

#### `(spawn-worker entry channel ...)` → worker-handle
Spawn a new OS thread. `entry` is either a **source string** or a **portable form** (see [Workers](#workers) intro). It is evaluated in the worker's fresh stdlib context and must produce a callable whose arity matches the number of `channel` arguments. The callable is immediately invoked with the channels.

```scheme
;; String entry (back-compatible).
(define result-ch (make-channel 1))
(define w (spawn-worker
  "(lambda (out)
    (channel-send! out (* 6 7)))"
  result-ch))
(display (channel-recv! result-ch))   ; => 42
```

You can also pass a **form** built with quasiquote, splicing captured values in
*by value* with `,` — this is how you "send a closure" to a worker without
sharing heap pointers:

```scheme
(define factor 6)
(define out (make-channel 1))
(define w (spawn-worker
  `(lambda (out) (channel-send! out (* 7 ,factor)))  ; factor spliced as 6
  out))
(display (channel-recv! out))   ; => 42
```

A captured **list** (or other compound datum) must be quoted so the worker does
not try to evaluate it as code: write `` `(... ',xs) `` so `xs`'s value is
embedded as a literal.

#### `(worker? obj)` → bool
Return `#t` if `obj` is a worker handle.

#### `(worker-alive? handle)` → bool
Return `#t` if the worker OS thread is still running.

```scheme
(sleep 0.1)
(display (worker-alive? w))   ; => #f  (if the lambda returned)
```

#### `(worker-stop handle)` → `#void`
Request the worker to stop by setting its stop flag. The worker is responsible for checking `(worker-stopping?)` and exiting cleanly.

#### `(worker-stopping?)` → bool
Called **inside a worker** to check whether `worker-stop` has been requested. Returns `#f` in non-worker contexts. Use this to implement cooperative cancellation.

**Automatic shutdown.** When the parent VM tears down (process exit, REPL session end), any still-running workers are stopped and joined before channel memory is reclaimed. You do not need an explicit drain loop just to avoid crashes — a sentinel-based shutdown is still recommended for graceful semantics, but a script that exits with live workers will exit cleanly.

```scheme
(define ctl-ch (make-channel 0))
(define w (spawn-worker
  "(lambda (ctl)
    (let loop ((n 0))
      (if (worker-stopping?)
          (channel-send! ctl n)   ; report how far we got
          (loop (+ n 1)))))"
  ctl-ch))

(sleep 0.05)
(worker-stop w)
(display (channel-recv! ctl-ch))   ; => some large number
```

### Worker pool example

```scheme
; A fixed pool of N workers sharing a single job channel.
(define (make-worker-pool n worker-fn)
  (define job-ch (make-channel 64))
  (let loop ((i 0))
    (when (< i n)
      (spawn-worker worker-fn job-ch)
      (loop (+ i 1))))
  job-ch)

; Each worker processes jobs until the channel is closed.
(define pool-worker
  "(lambda (jobs)
    (let loop ()
      (channel-send! jobs 'done)   ; replace with actual recv
      (loop)))")

; Submit work:
;   (channel-send! job-ch my-item)
; Shut down:
;   (channel-close job-ch)
```

A realistic worker pool with results:

```scheme
(define job-ch    (make-channel 32))
(define result-ch (make-channel 32))

; Spawn 4 workers, each reading from job-ch and writing to result-ch.
(define workers
  (let loop ((i 0) (acc '()))
    (if (= i 4) acc
        (loop (+ i 1)
              (cons (spawn-worker
                      "(lambda (jobs out)
                        (let loop ()
                          (let ((x (channel-recv! jobs)))
                            (channel-send! out (* x x))
                            (loop))))"
                      job-ch result-ch)
                    acc)))))

; Submit 20 jobs.
(let loop ((i 0))
  (when (< i 20)
    (channel-send! job-ch i)
    (loop (+ i 1))))

; Collect 20 results.
(let loop ((n 0))
  (when (< n 20)
    (display (channel-recv! result-ch)) (newline)
    (loop (+ n 1))))
```

---

## TCP Networking

All TCP primitives are non-blocking. When a socket call would block (EAGAIN), the current fiber yields and the scheduler calls `poll(2)`; the fiber resumes when the fd is ready. Use `spawn` to handle multiple connections concurrently.

### Primitives

#### `(tcp-socket? obj)`
Return `#t` if `obj` is a TCP connection socket.

#### `(tcp-server? obj)`
Return `#t` if `obj` is a TCP server socket.

#### `(tcp-listen port)`
Create a non-blocking server socket listening on `port` (integer). Returns a server handle. Raises `IOError` on failure.
```scheme
(define srv (tcp-listen 8080))
```

#### `(tcp-accept server)`
Accept one incoming connection on `server`. Returns a connection socket. Yields the current fiber if no connection is pending yet.
```scheme
(define conn (tcp-accept srv))
```

#### `(tcp-connect host port)`
Connect to `host` (string) at `port` (integer). Returns a connection socket. Raises `IOError` on failure. The connect itself is synchronous; use `spawn` to avoid blocking other fibers.
```scheme
(define sock (tcp-connect "127.0.0.1" 8080))
```

#### `(tcp-send conn str)`
Send all bytes of `str` over `conn`. Yields if the socket buffer is full, resuming when space is available. Returns `#void`.
```scheme
(tcp-send sock "Hello\n")
```

#### `(tcp-recv conn max-bytes)`
Receive up to `max-bytes` from `conn`. Returns a string, or the `eof-object` when the connection is closed. Yields if no data is available.
```scheme
(tcp-recv sock 4096)          ; => "some data"
(eof-object? (tcp-recv sock 1)) ; => #t when closed
```

#### `(tcp-recv-line conn)`
Read bytes from `conn` until a `\n` is found. Returns the line without the newline, or the `eof-object` at connection close. Buffers internally so partial reads across yields work correctly. Yields when waiting for data.
```scheme
(tcp-recv-line sock)   ; => "one line"
```

#### `(tcp-close conn-or-server)`
Close a connection or server socket. The GC finalizer also closes it automatically, but explicit close is preferred to release fds promptly.
```scheme
(tcp-close sock)
(tcp-close srv)
```

### Helper functions (`lib/net.lisp`)

Import with `(import net)`.

#### `(tcp-recv-all conn)`
Read from `conn` until EOF, return all data as one string.
```scheme
(import net)
(tcp-recv-all sock)   ; => "full response body"
```

#### `(with-tcp-connection host port thunk)`
Open a connection, call `(thunk sock)`, close the socket, return the result.
```scheme
(import net)
(with-tcp-connection "example.com" 80
  (lambda (sock)
    (tcp-send sock "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
    (tcp-recv-all sock)))
```

#### `(tcp-serve port handler)`
Listen on `port`, spawn a fiber for each accepted connection, call `(handler conn)` in that fiber. Runs forever.
```scheme
(import net)
(tcp-serve 8080
  (lambda (conn)
    (tcp-send conn "hello\n")
    (tcp-close conn)))
```

---

## HTTP Client

HTTP client functionality is provided by the `lib/http.lisp` module. The core `http-request` primitive is always available.

### Primitives

#### `(http-request method url headers body)`
Make an HTTP request. `method` is a string like `"GET"`, `"POST"`, etc. `headers` is an alist of `(key . "value")` pairs or `nil`. `body` is a string or `nil`. Return a plist with `:status` (number) and `:body` (string).
```scheme
(http-request "GET" "http://example.com/" nil nil)
; => (:status 200 :body "<!DOCTYPE html>...")

(http-request "POST" "http://example.com/api"
  '(("content-type" . "text/plain"))
  "hello")
; => (:status 201 :body "")
```

### Helper functions

The `lib/http.lisp` module (imported with `(import http)`) provides convenience wrappers:

#### `(http-get url)`
GET request. Return response plist.
```scheme
(import http)
(http-get "http://example.com/")
; => (:status 200 :body "...")
```

#### `(http-post url body)`
POST request with string body. Return response plist.
```scheme
(http-post "http://example.com/api" "data")
```

#### `(http-put url body)`
PUT request with string body. Return response plist.

#### `(http-delete url)`
DELETE request. Return response plist.

#### `(http-head url)`
HEAD request. Return response plist (body is typically empty).

#### `(http-get-json url)`
GET request, parse response body as JSON. Return parsed data.
```scheme
(http-get-json "http://api.example.com/users")
; => #(user1 user2 user3) or (("id" . 1) ("name" . "Alice") ...)
```

#### `(http-post-json url data)`
POST request with JSON body, parse response as JSON. `data` is Lisp data that will be converted to JSON.
```scheme
(http-post-json "http://api.example.com/users"
  '(("name" . "Bob") ("email" . "bob@example.com")))
; => parsed JSON response
```

#### `(http-ok? resp)`
Return `#t` if response status is 2xx, otherwise `#f`.
```scheme
(http-ok? '(:status 200 :body "ok"))   ; => #t
(http-ok? '(:status 404 :body "not found"))   ; => #f
```

#### `(http-status resp)`
Extract status code from response plist.
```scheme
(http-status '(:status 200 :body "ok"))   ; => 200
```

#### `(http-body resp)`
Extract body string from response plist.
```scheme
(http-body '(:status 200 :body "ok"))   ; => "ok"
```

---

## Regular Expressions

Regular expression functionality is provided by the `lib/regex.lisp` module. The core primitives `regex-compile`, `regex-exec`, and `regex?` are always available.

### Primitives

#### `(regex? obj)`
Return `#t` if `obj` is a compiled regex, otherwise `#f`.

#### `(regex-compile pattern [flags])`
Compile a regex from `pattern` (string). Optional `flags` string may contain `"i"` (case-insensitive) and `"n"` (newline mode). Return a regex object. Raise `RegexError` on invalid pattern.
```scheme
(regex-compile "hello")     ; => regex object
(regex-compile "[0-9]+" "i")  ; => case-insensitive regex
```

#### `(regex-exec regex-obj str)`
Execute regex against `str`. Return a match alist on success:
```scheme
'((match . "matched text")
  (start . 0)
  (end . 13)
  (groups . ("group1" "group2")))
```
Return `#f` if no match.
```scheme
(regex-exec (regex-compile "l+") "hello")
; => ((match . "ll") (start . 2) (end . 4) (groups . ()))

(regex-exec (regex-compile "x") "hello")
; => #f
```

### Helper functions

The `lib/regex.lisp` module (imported with `(import regex)`) provides these utilities:

#### `(regex-match? regex-obj str)`
Return `#t` if regex matches, otherwise `#f`.
```scheme
(import regex)
(regex-match? (regex-compile "^[0-9]+$") "12345")   ; => #t
(regex-match? (regex-compile "^[0-9]+$") "abc")     ; => #f
```

#### `(regex-find regex-obj str)`
Return the first match alist, or `#f` if no match.
```scheme
(regex-find (regex-compile "l+") "hello")
; => ((match . "ll") (start . 2) (end . 4) (groups . ()))
```

#### `(regex-find-all regex-obj str)`
Return a list of all match alists.
```scheme
(regex-find-all (regex-compile "l+") "hello world")
; => (((match . "ll") (start . 2) (end . 4) (groups . ()))
;     ((match . "l") (start . 9) (end . 10) (groups . ())))
```

#### `(regex-replace regex-obj str replacement)`
Replace the first match in `str` with `replacement` string. Return the modified string.
```scheme
(regex-replace (regex-compile "hello") "hello world" "goodbye")
; => "goodbye world"
```

#### `(regex-replace-all regex-obj str replacement)`
Replace all matches in `str` with `replacement` string. Return the modified string.
```scheme
(regex-replace-all (regex-compile "l") "hello" "L")
; => "heLLo"
```

#### `(regex-split regex-obj str)`
Split `str` by regex matches. Return a list of substrings.
```scheme
(regex-split (regex-compile "[,\\s]+") "a, b   c")
; => ("a" "b" "c")
```

---

## Math Libraries

Math functionality is organized into modules under `lib/math/`:

### math/core

Mathematical constants and derived helpers, layered on top of the built-in math
primitives.

> **No import needed for the primitives.** The trig/elementary/rounding/predicate
> functions below (`sqrt`, `sin`, `cos`, `pow`, `ln`, `floor`, `nan?`, `zero?`,
> `even?`, `odd?`, etc.) are registered **global primitives** — they work in any
> file with no import. `math/core` adds what the primitives don't provide: the
> **constants** and the **derived helpers** (marked below). Those are the only
> things that genuinely require the import.
>
> **Import it aliased or selectively, not bare.** Because `math/core` re-exports
> the builtin predicates (`zero?`, `even?`...), a bare `(import math/core)` raises
> an `ImportNameConflict` — those names are already global. Use
> `(import math/core as m)` and reach names via `m.pi`, or
> `(import math/core (only pi clamp ...))` to bind specific names unqualified.

**Constants:** *(require `(import math/core)`)*
- `pi`, `tau`, `e`, `phi`, `epsilon`, `inf`, `neg-inf`, `nan`

**Trigonometry:**
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `hypot`, `fmod`

**Elementary:**
`sqrt`, `cbrt`, `pow`, `exp`, `ln`, `log10`, `log2`, `log-base`

**Rounding:**
`floor`, `ceiling`, `round`, `truncate`, `frac` (fractional part)

**Predicates:** *(all global primitives — no import needed)*
`number?`, `integer?`, `float?`, `finite?`, `infinite?`, `nan?`, `zero?`, `positive?`, `negative?`, `even?`, `odd?`

**Comparison:** *(require the import)*
`sign`, `clamp`, `between?`, `almost-eq?`, `abs-close?`, `rel-close?`

**Utilities:** `abs`, `min`, `max` *(global primitives)*; `deg->rad`, `rad->deg`, `square`, `cube`, `copy-sign`, `lerp`, `invlerp`, `normalize-range`, `log-base`, `frac` *(require the import)*

```scheme
(sin 0)                    ; => 0   — primitive, no import needed
(sqrt 16)                  ; => 4   — primitive, no import needed

(import math/core as m)
m.pi                       ; => 3.141592653589793   — constant, needs import
(m.between? 5 1 10)        ; => #t  — derived helper, needs import
(m.almost-eq? 1.0 1.0000000001) ; => #t
```

### math/linear

Vector and matrix operations.

**Functions:**
`vec` (construct vector), `vec-add`, `dot` (dot product), `norm` (vector norm), `mat` (construct matrix), `mat-rows`, `mat-cols`, `mat-shape`, `mat-ref`, `rows->mat`, `transpose`, `matvec` (matrix-vector product), `solve` (linear solve), `det` (determinant)

```scheme
(import math/linear)

(define v1 (vec 1 2 3))
(define v2 (vec 4 5 6))
(dot v1 v2)                ; => 32
(norm v1)                  ; => sqrt(14) ≈ 3.74

(define m (rows->mat '((1 2) (3 4))))
(mat-ref m 0 1)            ; => 2
(transpose m)
```

### math/numeric/fit

Curve fitting.

**Functions:**
`fit-linear` (linear regression y=mx+b), `least-squares-line` (alias), `fit-poly-2` (quadratic regression y=ax²+bx+c)

Returns a hash with keys:
- `fit-linear`: `slope`, `intercept`
- `fit-poly-2`: `a`, `b`, `c`

```scheme
(import math/numeric/fit)

(define xs #(1 2 3 4))
(define ys #(2 4 6 8))

(define line (fit-linear xs ys))
(hash-get line 'slope)     ; => 2.0
(hash-get line 'intercept) ; => 0.0

(define quad (fit-poly-2 xs ys))
(hash-get quad 'a)         ; => coefficient for x²
(hash-get quad 'b)         ; => coefficient for x
(hash-get quad 'c)         ; => constant term
```

### math/numeric/integrate

Numerical integration.

**Functions:**
`midpoint` (midpoint rule), `trapz` (trapezoidal rule), `simpson` (Simpson's rule)

All take `(f a b n)`: function `f`, bounds `a`/`b`, number of intervals `n`.

```scheme
(import math/numeric/integrate)

(define (f x) (* x x))

(midpoint f 0 1 100)  ; ≈ 0.333
(trapz f 0 1 100)     ; ≈ 0.333
(simpson f 0 1 100)   ; ≈ 0.333
```

### math/numeric/roots

Root finding.

**Functions:**
- `bisect-root` — bisection method with keyword args `:tol` and `:max-iter`
- `newton-root` — Newton's method, needs function `f` and its derivative `df`, with keyword args `:tol` and `:max-iter`
- `secant-root` — secant method, needs function `f` and two initial guesses, with keyword args `:tol` and `:max-iter`

```scheme
(import math/numeric/roots)

(define (f x) (- (* x x) 2))  ; roots at ±√2

; Bisection
(bisect-root f 0 2)           ; => ≈ 1.414

; Newton (needs derivative)
(define (df x) (* 2 x))
(newton-root f df 1.5)        ; => ≈ 1.414

; Secant
(secant-root f 1.0 2.0)       ; => ≈ 1.414
```

### math/stats

Descriptive statistics, paired statistics, transforms, and linear regression over numeric **vectors** (lists are accepted and coerced). Variance/stdev/covariance default to the **sample** estimator (`/(n-1)`); population variants are `p`-prefixed (`/n`).

Exports: `mean`, `sum`, `variance`, `stdev`, `pvariance`, `pstdev` (variance/stdev, sample & population), `median`, `quantile` (q∈[0,1], type-7), `percentile`, `mode`, `span` (max−min), `iqr`, `covariance`, `pcovariance`, `correlation` (Pearson r), `standardize` (z-scores), `normalize` (min-max to [0,1]), `linreg` (simple OLS → hashtable `{slope intercept r2 n}`), `ols` (multivariate via normal equations → hashtable `{coeffs r2}`), `summary` (→ hashtable `{n mean stdev min q1 median q3 max}`). Empty input, `n<2` for sample variance/covariance/correlation, out-of-range quantile, zero variance, and unequal-length pairs all raise an explicit error.

```scheme
(import math/stats)
(mean (vector 1 2 3 4))            ; => 2.5
(stdev (vector 2 4 4 4 5 5 7 9))   ; => 2.138... (sample)
(correlation (vector 1 2 3 4) (vector 3 5 7 9))  ; => 1.0
(hash-get (linreg (vector 1 2 3 4) (vector 3 5 7 9)) 'slope 0)  ; => 2.0
```

### math/dist

A seeded `xoshiro128**` pseudo-random generator (explicit generator objects only — no global RNG) plus the error function and the uniform and normal distributions.

Exports: `make-rng` (seed → generator), `rng-next!` (raw 32-bit draw), `rng-float!` ([0,1)), `rng-int!` (`lo hi` → integer in [lo,hi), unbiased), `erf`, `erfc`, `uniform-pdf`/`uniform-cdf`/`uniform-sample!`, `normal-pdf`/`normal-cdf`/`normal-sample!`. Samplers take an explicit `rng` (so runs are reproducible). `sigma<=0` and `b<=a` raise errors.

```scheme
(import math/dist)
(define r (make-rng 42))
(rng-int! r 1 7)               ; => a die roll in 1..6
(normal-cdf 1 0 1)             ; => ≈ 0.8413
(normal-sample! r 100 15)      ; => one N(100,15) draw
```

### math/tensor

Pure-Lisp n-dimensional arrays (row-major) for data shaping and small linear algebra. A tensor is a `{shape, data}` hashtable; every dimension is ≥ 1.

Exports: `tensor` (shape + flat data), `zeros`, `ones`, `full`, `arange`, `from-nested`; `tensor?`, `shape` (→ list), `rank`, `size`, `tensor->nested`; `tref`/`tset!` (multi-index get/set); `reshape` (shares the buffer), `transpose` (reverses axes), `slice` (one axis, `[start,end)`); `t+`/`t-`/`t*`/`t/` (elementwise — identical-shape or tensor+scalar), `t-map`, `t-zip`, `t-equal?`; `t-sum`/`t-mean`/`t-max`/`t-min` (whole-tensor, or along an `axis`); `matmul` (2-D). No broadcasting and no strided views; shape mismatches and out-of-range indices/axes raise errors.

```scheme
(import math/tensor)
(define a (from-nested (list (list 1 2 3) (list 4 5 6))))   ; 2x3
(shape (transpose a))                       ; => (3 2)
(tensor->nested (t* a 10))                   ; => ((10 20 30) (40 50 60))
(tensor->nested (t-sum a 0))                 ; => (5 7 9)   column sums
(tensor->nested (matmul a (transpose a)))    ; => ((14 32) (32 77))
```

---

## Zig FFI

Zepo has a compile-time FFI for calling Zig functions from Lisp. It is intended for embedding Zepo in a Zig host application or for shipping accelerated Zig libraries alongside a Zepo script.

FFI is a **build-time** feature — you write a Zig file, use `zepo.ffi.expose` to generate wrappers, and register them before creating an `EvalContext`. It is not available from plain `.lisp` scripts.

### Type mapping

The FFI automatically marshals between Zig and Lisp types:

| Zig param/return type | Lisp value |
|---|---|
| `bool` | `#t` / `#f` |
| any integer (`i8`…`i64`, `u8`…`u32`) | fixnum |
| any float (`f32`, `f64`) | float |
| `[]const u8` | string (copied) |
| `void` | FFI void handle (convert with `ffi-to-lisp` → `#void`) |
| error union (`!T`) | `(ok . value)` or `(err kind-symbol message)` on error |

Opaque handles (int, float, bool, string, void returns) land as **foreign objects** — they are GC-managed but opaque to Lisp. Use the accessor primitives below to convert them to first-class Lisp values.

### Defining and registering Zig bindings

```zig
// math_lib.zig  — the Zig module to expose
pub fn add(a: i64, b: i64) i64 { return a + b; }
pub fn sqrt_f(x: f64) f64 { return @sqrt(x); }
pub fn greet(name: []const u8) []const u8 { return "hello"; }

// In your Zig host:
const Bindings = zepo.ffi.expose(math_lib, .{
    .add    = .{},
    .sqrt_f = .{},
    .greet  = .{},
});

// Register before creating EvalContext:
try Bindings.register(&gc, &globals, &symbols);
// Or into a module:
try Bindings.registerIntoModule(&gc, &symbols, &my_module);
```

After `register`, `add`, `sqrt_f`, and `greet` are callable from Lisp.

### Accessor primitives

FFI return values are opaque foreign handles. These primitives unwrap them:

#### `(ffi-to-lisp handle)` → value
Universal converter — inspects the handle's type tag and converts automatically. Returns `#void` for void handles, a fixnum for int handles, etc. Raises `TypeError` for unknown tag types (e.g. user-defined opaque handles).

#### `(ffi-int handle)` → fixnum
Unwrap an integer handle. Raises `ContractViolation` if the value overflows the fixnum range (i63).

#### `(ffi-float handle)` → float
Unwrap a float handle.

#### `(ffi-bool handle)` → bool
Unwrap a boolean handle.

#### `(ffi-string handle)` → string
Unwrap a string handle (copies the bytes into the Zepo GC heap).

### Usage from Lisp

```lisp
; Assuming add, sqrt_f, greet are registered Zig FFI functions:
(define result (add 3 4))          ; => opaque i64 handle
(ffi-to-lisp result)               ; => 7

(ffi-to-lisp (sqrt_f 2.0))        ; => 1.4142135623730951

(ffi-to-lisp (greet "world"))     ; => "hello"

; Error union: returns (ok . value) or (err kind msg)
; (define r (parse-u32 "42"))
; (car r)   ; => 'ok
; (cdr r)   ; => 42
```

### `FnConfig` options

Each entry in the config struct passed to `expose` is a `FnConfig`:

| Field | Values | Meaning |
|---|---|---|
| `return_lifetime` | `.copy` (default) | String return is copied into a GC-owned `StringPayload` |
| `return_lifetime` | `.owned` | String was heap-allocated by the Zig fn; FFI takes ownership |
| `return_lifetime` | `.borrow_until_next_call` | String is static/stack — valid only until the next FFI call |

### Limitations

- Only primitive Zig types are supported (no structs, slices of non-char, pointers). Complex types require writing a manual wrapper.
- `u64`/`i128` etc. that don't fit in i63 fixnum cause `ContractViolation` at call time.
- FFI is compile-time only — not accessible from standalone `.lisp` scripts.

---

## Hooks and Advice

Hook and advice functionality is provided by the `lib/hooks.lisp` module. Import with `(import hooks)`.

### Hooks

A hook is a named list of functions that can be called together. Hooks are useful for
event-driven programming and plugin-like extensibility.

#### `(add-hook name fn)`
Prepend `fn` to the hook list named `name` (a symbol).
```scheme
(import hooks)
(add-hook 'startup-hook (lambda () (display "Starting up") (newline)))
```

#### `(remove-hook name fn)`
Remove `fn` from the hook list, using `eq?` for comparison.

#### `(run-hooks name)`
Call each function in hook `name` with no arguments. Return `()`.
```scheme
(run-hooks 'startup-hook)   ; calls all functions in the hook
```

#### `(run-hooks/results name)`
Call each function in hook `name` with no arguments. Return list of results.
```scheme
(define results (run-hooks/results 'compute-hook))
```

### Advice

Advice allows wrapping an existing function with pre-, post-, around, or override logic.
The `name` in advice macros is a symbol referring to a globally-bound function.

#### `(defadvice name type fn-expr)`

Macro that wraps function `name` with advice. `type` is one of:

- `':before` — call `(advice-fn . original-args)`, return value ignored, original function called and returned
- `':after` — call `(advice-fn result . original-args)`, return value ignored, original result returned
- `':around` — call `(advice-fn original-fn . args)`, advice must call `original-fn` explicitly
- `':override` — `advice-fn` replaces the function entirely

```scheme
(import hooks)

(define (greet name)
  (string-append "Hello, " name))

; Add before advice
(defadvice greet ':before
  (lambda (name)
    (display "→ ")))

(greet "Alice")   ; prints: → => "Hello, Alice"

; Add around advice
(defadvice greet ':around
  (lambda (orig name)
    (string-append "[" (orig name) "]")))

(greet "Bob")     ; => "[Hello, Bob]"
```

#### `(remove-advice name)`

Macro that restores the original function, removing all advice.
```scheme
(remove-advice greet)
(greet "Charlie")  ; => "Hello, Charlie" (back to original)
```

#### `(advised? name)`

Predicate; return `#t` if `name` (a symbol) has active advice, otherwise `#f`.
```scheme
(advised? 'greet)  ; => #t or #f
```
