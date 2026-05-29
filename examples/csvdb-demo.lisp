; csvdb-demo.lisp — exercises the full csvdb library
; Creates a small employee database, runs queries, mutates, saves, reloads.

(import csvdb/api (csv-open csv-row-count csv-columns csv-select ; zepo-y1a4
                   csv-insert! csv-update! csv-delete! csv-save!))
(import format (format)) ; zepo-y1a4

(define (hr) (display "================================") (newline))
(define (section title) (newline) (hr) (display title) (newline) (hr))

; ── 1. Seed data ─────────────────────────────────────────────────────────────

(define CSV-PATH "/tmp/employees.csv")

(file-write-string CSV-PATH
  (string-append
    "id,name,dept,salary,city\n"
    "1,Alice,Engineering,95000,Florence\n"
    "2,Bob,Marketing,72000,Rome\n"
    "3,Carla,Engineering,105000,Florence\n"
    "4,Dave,HR,61000,Milan\n"
    "5,Eve,Marketing,78000,Rome\n"
    "6,Frank,Engineering,88000,Milan\n"
    "7,Grace,HR,64000,Florence\n"
    "8,Hiro,Engineering,112000,Tokyo\n"))

(define db (csv-open CSV-PATH (make-hash-table)))
(display (format "Loaded ~a employees. Columns: ~a~%" (csv-row-count db) (csv-columns db)))

; ── helper: print rows as maps ────────────────────────────────────────────────

(define (print-rows result cols)
  (let loop ((i 0))
    (when (< i (vector-length result))
      (let ((row (vector-ref result i)))
        (let col-loop ((cs cols))
          (when (pair? cs)
            (display (format "  ~a=~a" (car cs) (hash-get row (car cs) "")))
            (col-loop (cdr cs))))
        (newline))
      (loop (+ i 1)))))

; ── 2. Simple select ─────────────────────────────────────────────────────────

(section "Engineering dept")
(define eng-opts (make-hash-table))
(hash-set! eng-opts 'where '(= dept "Engineering"))
(hash-set! eng-opts 'as ':maps)
(let ((r (csv-select db eng-opts)))
  (display (format "  (~a rows)~%" (vector-length r)))
  (print-rows r '("name" "city" "salary")))

; ── 3. Compound predicate ─────────────────────────────────────────────────────

(section "Florence employees NOT in Engineering")
(define o3 (make-hash-table))
(hash-set! o3 'where '(and (= city "Florence") (!= dept "Engineering")))
(hash-set! o3 'as ':maps)
(let ((r (csv-select db o3)))
  (print-rows r '("name" "dept")))

; ── 4. String ops ─────────────────────────────────────────────────────────────

(section "Names containing 'a' or 'i'")
(define o4 (make-hash-table))
(hash-set! o4 'where '(or (contains name "a") (contains name "i")))
(hash-set! o4 'as ':maps)
(let ((r (csv-select db o4)))
  (print-rows r '("name")))

; ── 5. Pagination ─────────────────────────────────────────────────────────────

(section "Page 1 (limit 3)")
(define o5a (make-hash-table))
(hash-set! o5a 'limit 3)
(hash-set! o5a 'as ':maps)
(let ((r (csv-select db o5a)))
  (print-rows r '("id" "name")))

(section "Page 2 (limit 3, offset 3)")
(define o5b (make-hash-table))
(hash-set! o5b 'limit 3)
(hash-set! o5b 'offset 3)
(hash-set! o5b 'as ':maps)
(let ((r (csv-select db o5b)))
  (print-rows r '("id" "name")))

; ── 6. in predicate ───────────────────────────────────────────────────────────

(section "HR or Marketing")
(define o6 (make-hash-table))
(hash-set! o6 'where '(in dept "HR" "Marketing"))
(hash-set! o6 'as ':maps)
(let ((r (csv-select db o6)))
  (print-rows r '("name" "dept")))

; ── 7. Insert ────────────────────────────────────────────────────────────────

(section "Insert Ingrid (Engineering, Berlin)")
(define new-emp (make-hash-table))
(hash-set! new-emp "id"     "9")
(hash-set! new-emp "name"   "Ingrid")
(hash-set! new-emp "dept"   "Engineering")
(hash-set! new-emp "salary" "98000")
(hash-set! new-emp "city"   "Berlin")
(csv-insert! db new-emp)
(display (format "  Row count: ~a~%" (csv-row-count db)))

; ── 8. Update: give Engineering a raise ──────────────────────────────────────

(section "Give every Engineer +5000 salary")
(define eng-rows-opts (make-hash-table))
(hash-set! eng-rows-opts 'where '(= dept "Engineering"))
(hash-set! eng-rows-opts 'as ':maps)
(let ((eng (csv-select db eng-rows-opts)))
  (let loop ((i 0))
    (when (< i (vector-length eng))
      (let* ((row     (vector-ref eng i))
             (name    (hash-get row "name" ""))
             (old-sal (hash-get row "salary" "0"))
             (new-sal (number->string (+ (string->number old-sal) 5000)))
             (patch   (make-hash-table))
             (where   (make-hash-table)))
        (hash-set! patch "salary" new-sal)
        (hash-set! where 'where (list '= 'name name))
        (csv-update! db where patch)
        (display (format "  ~a: ~a -> ~a~%" name old-sal new-sal)))
      (loop (+ i 1)))))

; ── 9. Delete HR ──────────────────────────────────────────────────────────────

(section "Delete HR department")
(define od (make-hash-table))
(hash-set! od 'where '(= dept "HR"))
(csv-delete! db od)
(display (format "  Rows remaining: ~a~%" (csv-row-count db)))

; ── 10. Save, reload, verify ─────────────────────────────────────────────────

(section "Save -> reload -> verify")
(csv-save! db)
(define db2 (csv-open CSV-PATH (make-hash-table)))
(display (format "  Reloaded ~a rows~%" (csv-row-count db2)))

(define oi (make-hash-table))
(hash-set! oi 'where '(= name "Ingrid"))
(hash-set! oi 'as ':maps)
(let ((r (csv-select db2 oi)))
  (if (> (vector-length r) 0)
      (let ((row (vector-ref r 0)))
        (display (format "  Ingrid: dept=~a city=~a salary=~a~%"
                         (hash-get row "dept" "")
                         (hash-get row "city" "")
                         (hash-get row "salary" ""))))
      (display "  ERROR: Ingrid not found\n")))

(define ohr (make-hash-table))
(hash-set! ohr 'where '(= dept "HR"))
(display (format "  HR rows: ~a (should be 0)~%" (vector-length (csv-select db2 ohr))))

(define oa (make-hash-table))
(hash-set! oa 'where '(= name "Alice"))
(hash-set! oa 'as ':maps)
(let ((r (csv-select db2 oa)))
  (display (format "  Alice salary: ~a (should be 100000)~%"
                   (hash-get (vector-ref r 0) "salary" ""))))

(newline) (hr)
(display "done.") (newline)
