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
       zepo install <path>
       zepo build [file.lisp] [-o outname]

Options:
  --repl        Start an interactive REPL
  --help        Show this help message

Commands:
  install <path>       Install a package to ~/.local/lib/zepo/
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

### Startup and module search path

On startup the runtime evaluates the built-in **stdlib** (`lib/stdlib.lisp` —
embedded at compile time). No other files are auto-loaded.

Additional libraries are loaded **on demand** via `(import name)`. When
`import` is evaluated, the runtime searches for `<name>.lisp` in order:

1. `<exe-dir>/../../lib/` — the project's own `lib/` directory
2. Each entry in `ZEPO_PATH` (colon-separated)

If not found, `ModuleNotFound` is raised.

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

Functions can accept keyword arguments by including `#:name` in the parameter list.

```scheme
(define (greet name #:greeting msg)
  (string-append msg ", " name "!"))

(greet "Alice")                              ; error: missing keyword #:greeting
(greet "Alice" #:greeting "Hello")           ; => "Hello, Alice!"
(greet "Bob" #:greeting "Hi")                ; => "Hi, Bob!"
```

Keyword arguments are required unless a default value is provided (via
`define` shorthand):

```scheme
(define (configure port #:host h #:debug d)
  (display (string-append "Host: " h " Port: " (number->string port))))

(configure 8080 #:host "localhost" #:debug #t)
```

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
| `argv` | 0 | Return command-line args as a list of strings |

```scheme
(display "hello")     ; prints: hello
(write "hello")       ; prints: "hello"
(newline)             ; prints newline
(argv)                ; => ("zepo" "foo.lisp" ...)
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

```scheme
(file-write-string "/tmp/out.txt" "hello\n")
(file-append-string "/tmp/out.txt" "world\n")
(file-read-string "/tmp/out.txt")   ; => "hello\nworld\n"
(file-exists? "/tmp/out.txt")       ; => #t
(file-delete "/tmp/out.txt")
(file-exists? "/tmp/out.txt")       ; => #f
```

### Directory and Path

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `directory-list` | 1 | `(directory-list path)` → list of entry name strings |
| `make-directory` | 1 | `(make-directory path)` — create directory and any missing parents |
| `current-directory` | 0 | `(current-directory)` → absolute path string of CWD |

```scheme
(make-directory "/tmp/zepo-test/sub")
(current-directory)              ; => "/Users/me/myproject"
(directory-list ".")             ; => ("src" "lib" "project.lisp" ...)
```

### Environment and Shell

| Primitive | Arity | Description |
|-----------|-------|-------------|
| `getenv` | 1 | `(getenv name)` → string or `#f` if unset |
| `shell` | 1 | `(shell cmd)` → stdout string (exit code ignored) |
| `shell/status` | 1 | `(shell/status cmd)` → integer exit code |

```scheme
(getenv "HOME")                         ; => "/Users/me"
(getenv "UNDEFINED_VAR")               ; => #f
(shell "echo hello")                    ; => "hello\n"
(shell/status "test -f project.lisp")  ; => 0 or 1
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

#### `(map f lst)`
Apply `f` to each element, collect results.
```scheme
(map (lambda (x) (* x x)) '(1 2 3))   ; => (1 4 9)
```

#### `(filter pred lst)`
Keep elements where `pred` returns truthy.
```scheme
(filter odd? '(1 2 3 4 5))   ; => (1 3 5)
```

#### `(for-each f lst)`
Call `f` on each element for side effects; return `()`.
```scheme
(for-each display '(1 2 3))   ; prints: 123
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

Modules provide namespacing. A module declaration must appear at the top level
of a file (not inside another module or procedure).

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

### Importing a module

```scheme
; Full import — brings all exported names into the current environment
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
`IMPORT` opcode:

```scheme
(define (use-math)
  (import math/core)
  (sqrt 16))   ; => 4

(use-math)
```

### Rules

- Modules are not first-class values; `module`/`import`/`export` are
  syntactic forms. `import` can appear at top level or inside function bodies.
- `import` inside a module body imports into that module's environment.
- Exporting a name that is never defined raises `ExportNameUndefined`.
- Importing a name that conflicts with an existing binding: existing bindings
  silently win. No `ImportNameConflict` error is raised (re-exports of
  primitives into modules are silently skipped).
- Nested modules are not allowed.

### Example — two-file program

```scheme
; lib/utils.lisp
(module utils
  (export greet)
  (define (greet name)
    (string-append "Hello, " name "!")))

; main.lisp
(import utils)
(println (greet "world"))   ; prints: Hello, world!
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

## TCP Networking

TCP networking primitives are always available. The `lib/net.lisp` module provides higher-level helpers.

### Primitives

#### `(tcp-socket? obj)`
Return `#t` if `obj` is a TCP socket, otherwise `#f`.

#### `(tcp-server? obj)`
Return `#t` if `obj` is a TCP server socket, otherwise `#f`.

#### `(tcp-connect host port)`
Connect to a TCP server at `host` (string) and `port` (number). Return a socket on success. Raise `TcpError` on failure.
```scheme
(define sock (tcp-connect "localhost" 8080))
```

#### `(tcp-send socket str)`
Send string `str` over `socket`. Return number of bytes sent. Raise `TcpError` on failure.
```scheme
(tcp-send sock "Hello, server!")   ; => 14
```

#### `(tcp-recv socket max-bytes)`
Receive up to `max-bytes` from `socket`. Return a string. Empty string indicates EOF (connection closed).
```scheme
(tcp-recv sock 1024)   ; => "Hello, client!"
(tcp-recv sock 1024)   ; => "" (EOF after repeated calls)
```

#### `(tcp-listen port)`
Create a server socket listening on `port` (number). Return a server socket. Raise `TcpError` on failure.
```scheme
(define srv (tcp-listen 8080))
```

#### `(tcp-accept server-socket)`
Accept an incoming connection on a server socket. Return a connected socket. Raises `TcpError` on failure or if the server is not actually a server socket.
```scheme
(define client-sock (tcp-accept srv))
```

#### `(tcp-close socket-or-server)`
Close a socket or server socket. Return `nil`. Raise `TcpError` on failure.
```scheme
(tcp-close sock)
(tcp-close srv)
```

### Helper functions

The `lib/net.lisp` module (imported with `(import net)`) provides these utilities:

#### `(tcp-recv-all socket)`
Receive until EOF, returning all data as a single string.
```scheme
(import net)
(tcp-recv-all sock)   ; => accumulated string until EOF
```

#### `(tcp-recv-line socket)`
Receive until a newline or EOF, returning one line (without the newline).
```scheme
(import net)
(tcp-recv-line sock)   ; => "one line"
```

#### `(with-tcp-connection host port f)`
Open a connection to `host:port`, call function `f` with the socket, and close the socket. Return the result of `f`.
```scheme
(import net)
(with-tcp-connection "example.com" 80
  (lambda (sock)
    (tcp-send sock "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
    (tcp-recv sock 4096)))
```

#### `(tcp-serve port handler)`
Create a server listening on `port`, accept connections in a loop, and call `handler` with each socket. Return never (runs forever).
```scheme
(import net)
(tcp-serve 8080
  (lambda (sock)
    (tcp-send sock "Hello!")
    (tcp-close sock)))
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

Mathematical primitives and constants.

**Constants:**
- `pi`, `tau`, `e`, `phi`, `epsilon`, `inf`, `neg-inf`, `nan`

**Trigonometry:**
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `hypot`, `fmod`

**Elementary:**
`sqrt`, `cbrt`, `pow`, `exp`, `ln`, `log10`, `log2`, `log-base`

**Rounding:**
`floor`, `ceiling`, `round`, `truncate`, `frac` (fractional part)

**Predicates:**
`number?`, `integer?`, `float?`, `finite?`, `infinite?`, `nan?`, `zero?`, `positive?`, `negative?`, `even?`, `odd?`

**Comparison:**
`sign`, `clamp`, `between?`, `almost-eq?`, `abs-close?`, `rel-close?`

**Utilities:**
`abs`, `min`, `max`, `deg->rad`, `rad->deg`, `square`, `cube`, `copy-sign`, `lerp`, `invlerp`, `normalize-range`

```scheme
(import math/core)

(sin 0)                    ; => 0
(sqrt 16)                  ; => 4
(between? 5 1 10)         ; => #t
(almost-eq? 1.0 1.0000000001) ; => #t
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
