# csvdb — CSV Database Library

## Overview

csvdb is an in-memory CSV database library for Zepo. It parses RFC 4180 CSV files, infers a schema from the header row, and provides row-level CRUD operations: select with predicates, insert, update, delete, and atomic save. All data is held in memory; the file is read once on `csv-open` and written atomically on `csv-save!`.

The library is split into five modules: `csvdb/parser` (RFC 4180 parsing), `csvdb/schema` (column and type metadata), `csvdb/store` (in-memory table representation), `csvdb/query` (predicate evaluation and row filtering), and `csvdb/api` (user-facing functions). Most code uses only `csvdb` (the api module).

---

## Quick Start

```lisp
(import csvdb)

; Create a test CSV file
(file-write-string "people.csv" "name,age,city\nAlice,30,NYC\nBob,25,LA\n")

; Open the table
(let ((table (csv-open "people.csv" (make-hash-table))))
  
  ; Select rows with a predicate
  (let ((alice-rows (csv-select table
          (hash-set (make-hash-table) 'where '(= name "Alice")))))
    (display (vector-length alice-rows)))  ; prints: 1
  
  ; Insert a new row (as a hash map)
  (csv-insert! table
    (hash-set (hash-set (make-hash-table) 'name "Charlie") 'age "35"))
  
  ; Update matching rows
  (csv-update! table
    (hash-set (make-hash-table) 'where '(= name "Bob"))
    (hash-set (make-hash-table) 'city "SF"))
  
  ; Delete matching rows
  (csv-delete! table
    (hash-set (make-hash-table) 'where '(= name "Alice")))
  
  ; Save changes back to disk (atomic via temp file + move)
  (csv-save! table))
```

---

## Opening a Table

**Signature:**
```lisp
(csv-open path opts) → table
```

Opens a CSV file at `path` and returns a table. The `opts` hash controls parsing:

- `'header` (boolean, default `#t`) — treat first row as column names; if `#f`, auto-names columns `c0`, `c1`, etc.
- `'delimiter` (char, default `,`) — field delimiter; e.g. `(string-ref "\t" 0)` for TSV.
- `'readonly` (boolean, default `#f`) — if `#t`, forbids mutations; attempting `csv-insert!`, `csv-update!`, `csv-delete!`, or `csv-save!` raises an error.

**Returns:** A table object. All data is loaded into memory at open time.

**Example:**
```lisp
(let ((opts (make-hash-table)))
  (hash-set! opts 'header #t)
  (hash-set! opts 'delimiter (string-ref "," 0))
  (let ((table (csv-open "data.csv" opts)))
    (display (csv-row-count table))))
```

---

## Selecting Rows

**Signature:**
```lisp
(csv-select table opts) → vector<row>
```

Filters and returns rows from the table. The `opts` hash controls selection:

- `'where` (predicate or `#f`, default `#f`) — only include rows matching this predicate; `#f` selects all.
- `'limit` (number or `#f`, default `#f`) — max rows to return; `#f` means no limit.
- `'offset` (number, default `0`) — skip this many matching rows before collecting results.
- `'as` (`:rows` or `:maps`, default `:rows`) — return format. `:rows` returns vectors; `:maps` returns hash maps (column-name → value).

**Returns:** A vector of rows (either vectors or maps, depending on `:as`).

**Example with `:rows` output (vectors):**
```lisp
(let ((opts (make-hash-table)))
  (hash-set! opts 'as ':rows)
  (let ((rows (csv-select table opts)))
    (display (vector-ref (vector-ref rows 0) 0))))  ; first field of first row
```

**Example with `:maps` output (hash maps):**
```lisp
(let ((opts (make-hash-table)))
  (hash-set! opts 'as ':maps)
  (hash-set! opts 'where '(= age "30"))
  (let ((maps (csv-select table opts)))
    (when (> (vector-length maps) 0)
      (let ((first-map (vector-ref maps 0)))
        (display (hash-get first-map "age" "N/A"))))))  ; prints: 30
```

---

## Predicate Syntax

Predicates are plain Lisp data. Bare symbols resolve to column values; literals (strings, numbers, booleans) self-evaluate.

**Comparison operators:** `=`, `!=`, `<`, `<=`, `>`, `>=`

All field values are strings by default (no automatic type coercion). Comparisons are string-based: `"10"` < `"2"` is true (lexicographic).

```lisp
'(= name "Alice")           ; column 'name' equals "Alice"
'(> age "25")               ; column 'age' > "25" (string comparison)
'(!= city "NYC")            ; not equal
'(<= salary "50000")        ; less-or-equal (string order)
```

**Boolean operators:** `and`, `or`, `not`

```lisp
'(and (= name "Alice") (> age "25"))
'(or (= city "NYC") (= city "LA"))
'(not (= status "inactive"))
```

**String operators:** `starts-with`, `ends-with`, `contains`

```lisp
'(starts-with email "@gmail.com")
'(ends-with phone "0000")
'(contains address "5th Ave")
```

**Membership:** `in`

```lisp
'(in status "active" "pending" "review")  ; column status is one of these
```

**Null/empty checks:** `nil?`, `empty?`

Both treat empty string `""` and `#f` as empty. Useful after partial parses.

```lisp
'(nil? phone)
'(empty? comment)
```

**Compound example:**
```lisp
'(and (> age "21") 
      (or (= city "NYC") (= city "LA"))
      (starts-with email "@"))
```

---

## Mutating Data

### Insert

**Signature:**
```lisp
(csv-insert! table row-input) → table
```

Appends a row to the table. `row-input` may be a hash map (column-name → value) or a vector in schema order.

**Hash map input (recommended):**
```lisp
(let ((row (make-hash-table)))
  (hash-set! row "name" "Diana")
  (hash-set! row "age" "28")
  (csv-insert! table row))
```

**Vector input (values in column order):**
```lisp
(csv-insert! table (vector "Diana" "28" "Boston"))
```

Returns the table (for chaining). Sets the dirty flag so the next `csv-save!` writes changes.

### Update

**Signature:**
```lisp
(csv-update! table opts patch) → table
```

Updates all rows matching the `where` predicate in `opts`. `patch` is a hash map of column-name → new-value.

```lisp
(let ((opts (make-hash-table)))
  (hash-set! opts 'where '(= name "Bob"))
  (let ((patch (make-hash-table)))
    (hash-set! patch "city" "SF")
    (csv-update! table opts patch)))
```

Matching rows are modified in-place. Non-matching rows are left unchanged. Sets the dirty flag.

### Delete

**Signature:**
```lisp
(csv-delete! table opts) → table
```

Removes all rows matching the `where` predicate in `opts`. Rows that do not match are kept.

```lisp
(let ((opts (make-hash-table)))
  (hash-set! opts 'where '(= name "Alice"))
  (csv-delete! table opts))
```

Sets the dirty flag. Rebuilds the row vector.

### Save

**Signature:**
```lisp
(csv-save! table) → table
```

Writes the table back to disk if the dirty flag is set. Uses atomic rename: writes to a temp file, then moves it over the original. Rebuilds the header row from the schema.

```lisp
(csv-insert! table (make-hash-table))
(csv-update! table (hash-set (make-hash-table) 'where '(= id "1")) 
                   (hash-set (make-hash-table) 'status "done"))
(csv-save! table)  ; all changes written atomically
```

Does nothing if the table is not dirty. Returns the table.

---

## Utilities

**`csv-row-count`**

```lisp
(csv-row-count table) → number
```

Returns the number of data rows (excluding the header).

**`csv-columns`**

```lisp
(csv-columns table) → list<string>
```

Returns a list of column names in order.

```lisp
(display (csv-columns table))  ; prints: (name age city)
```

---

## Lower-Level Modules

Each module is importable separately if you need direct access to low-level functions:

- **`csvdb/parser`** — `parse-csv` (string char → vector<vector<string>>), `emit-csv` (vector<vector<string>> char → string). RFC 4180 compliant; returns all fields as strings.

- **`csvdb/schema`** — `make-schema`, `infer-schema`, `coerce-field`, `coerce-row`. Manages column metadata and type coercion. Used by higher-level code; rarely needed directly.

- **`csvdb/store`** — `make-table`, `load-table`, `table-path`, `table-schema`, `table-rows`, `row-ref`, `row-set!`, `row->map`. Low-level table and row accessors. Tracks the dirty flag.

- **`csvdb/query`** — `eval-pred`, `select-rows`. Predicate evaluation and row filtering engine. Powers `csv-select`.

---

## Limitations

- **All data in memory.** The entire CSV is loaded at `csv-open` time. Files larger than available RAM cannot be processed.

- **Whole-file write.** `csv-save!` rewrites the entire file; there is no incremental append or streaming mode.

- **No type coercion by default.** All parsed fields are strings. Column types in the schema default to `:string`. If you need numeric or boolean columns, use the `csvdb/schema` module directly to construct a custom schema and call `coerce-row` explicitly.

- **String-based comparisons.** The `<`, `<=`, `>`, `>=` operators compare field values as strings, not as numbers. `"10"` is less than `"2"`. If you need numeric comparison, coerce fields to numbers first or use a higher-level abstraction.

- **No indexes.** Queries are full table scans. No index support for fast column lookups.
