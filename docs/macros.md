# Building DSLs with macros

Zepo's macro system (`defmacro`, `define-syntax` / `syntax-rules`, with hygiene)
is most valuable for building small **domain-specific languages**: a notation
that reads like the problem instead of like plumbing. This page describes the
pattern and walks two libraries in the standard distribution that follow it —
`testing` and `clap`.

For the macro mechanics themselves (quoting, `defmacro`, `define-syntax`,
hygiene, nested quasiquote) see the
[Macros section of the reference](reference.md#defmacro).

## The pattern: small functional core + thin macro layer

> Write the behaviour as ordinary **functions**. Add **macros** only for the
> parts that functions cannot express, and keep them thin.

A function can't do three things a macro can:

1. **Defer evaluation** — a function's arguments are evaluated before it runs;
   a macro receives them as unevaluated code and can wrap them in a thunk, a
   conditional, or a loop.
2. **Introduce a binding or name** — `(define foo ...)`, a new local variable,
   etc., must be produced as code.
3. **Read literal syntax** — discriminate keywords from positional forms,
   destructure a literal binding list, and so on, before anything is evaluated.

If a form needs none of those, it should be a function. The result is a system
that is mostly testable, composable functions with a thin macro skin that makes
the call sites read like the domain. Both libraries below are >90% functions.

## Exemplar 1 — `testing`: macros to defer evaluation

The BDD surface reads like English:

```scheme
(describe "stack"
  (it "is empty on creation"
    (is (stack-empty? (make-stack))))
  (it "pops what it pushed"
    (=check (pop (push (make-stack) 1)) 1)))
```

**The functional core** is plain state-mutating functions: `push-context!` /
`pop-context!` maintain the current describe path, and `register-test!` records
a `(name . thunk)` pair to be run later. None of these are macros.

**The macro layer** is three short macros whose only job is deferral and
threading:

```scheme
(defmacro describe (name . body)
  `(begin (push-context! ,name) ,@body (pop-context!)))

(defmacro it (name . body)
  `(register-test! ,name (lambda () ,@body)))
```

Why each is a macro and not a function:

- `it` **must** be a macro. If it were a function, `(it "name" (is (= 1 2)))`
  would *evaluate* `(is (= 1 2))` immediately, at registration time — the test
  would run when you declare it, not when you run the suite. The macro wraps the
  body in `(lambda () ...)` so it stays dormant until `run-tests` calls the
  thunk. Expansion:

  ```scheme
  (it "pops what it pushed" (=check (pop (push (make-stack) 1)) 1))
  ;; expands to →
  (register-test! "pops what it pushed"
                  (lambda () (=check (pop (push (make-stack) 1)) 1)))
  ```

- `describe` is a macro so the nested `it` forms run *during* its body (pushing
  onto the context stack first), again without evaluating their test bodies.
  `(fdescribe / xdescribe / fit / xit)` are the same shape with a mode flag.

That is the whole trick: the core is functions; the macros only defer. Assertion
forms (`is`, `=check`, `throws`) are macros for the *same* reason — they need
the unevaluated expression both to run it and to print it on failure.

## Exemplar 2 — `clap`: functions to build, one macro to declare

A CLI is described declaratively:

```scheme
(defprogram greet
  :version "1.0"
  :summary "greet someone"
  (command "hello"
    :handler (lambda (r) (display "hi") (newline))
    :options (list (option 'loud :long "loud" :kind 'flag :help "shout"))
    :positionals (list (positional 'who :help "name to greet"))))
```

**The functional core** here is even larger than testing's, and it is the
interesting contrast: `option`, `positional`, and `command` are **plain
functions**. They take keyword props and return a plist record:

```scheme
(define (option key . props) ...)      ; → an option record (a plist)
(define (command name . props) ...)    ; → a command record (options/positionals
                                       ;   come in via :options/:positionals)
(define (build-program . args) ...)    ; assembles the program record
```

Note that a command's options arrive as `:options (list (option ...) ...)` — an
ordinary `list` of values returned by the `option` function. Because these are
functions, they compose with everything: you can `map` over a list of specs to
generate the options, store a shared option in a variable and reuse it across
commands, or build a command conditionally — no macro needed, because nothing is
being deferred or bound.

**The single macro** is `defprogram`, and it earns its place on two of the three
counts above — it **introduces a binding** (`define`s the program name) and it
**reads literal syntax** (it must tell keyword-metadata pairs apart from command
forms *before* evaluation):

```scheme
(defmacro defprogram (name . body)
  (let loop ((rest body) (props '()) (cmds '()))
    (cond
      ((null? rest)
       `(define ,name (build-program ,@(reverse props)
                                     :commands (list ,@(reverse cmds)))))
      ((and (symbol? (car rest)) (string-prefix? ":" (symbol->string (car rest))))
       (loop (cddr rest) (cons (cadr rest) (cons (car rest) props)) cmds))
      (#t
       (loop (cdr rest) props (cons (car rest) cmds))))))
```

It walks the body at macro-expansion time, splits `:key value` pairs from
`(command ...)` forms, and emits a single `(define NAME (build-program ...))`.
Everything it places in the output — `build-program`, `command`, `option` — is
an ordinary function call evaluated normally. Expansion:

```scheme
(defprogram greet :version "1.0" (command "hello" ...))
;; expands to →
(define greet
  (build-program :version "1.0"
                 :commands (list (command "hello" ...))))
```

So `clap` is a functional library with a one-macro front door, whereas
`testing` needs a macro per block form. The difference is exactly the
"defer evaluation" axis: a test body must not run when declared; a CLI option
record can be built eagerly.

## A checklist for your own DSL

1. Write the behaviour as functions returning plain data (plists, records,
   closures). Make them work and test them directly.
2. Reach for a macro only when a call site needs to **defer** a body, **bind** a
   name, or **read** literal syntax — and keep the macro body to a quasiquote
   template plus a little parsing.
3. Have the macro expand to calls into the functional core, so the expansion is
   readable and the core stays independently testable.
4. Mind [hygiene](reference.md#define-syntax-and-syntax-rules): use
   `syntax-rules` (or gensym in `defmacro`) for temporaries so your template
   can't capture a user's variable.
