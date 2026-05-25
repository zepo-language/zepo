; json-handlescope-regress.lisp — regression for zepo-gol (part 1).
;
; marshalJson's .object branch pushed a key AND value handle per entry into a
; single 32-slot HandleScope and never released them, so a JSON object with
; >= 16 keys overflowed the scope (panic in roots.zig HandleScope.push). Real
; LLM/embedding responses with many fields tripped this under the explain
; pipeline. Once an entry is stored in the hash-table it is rooted via the
; table, so the per-entry handles can be released.
;
; This object has 20 keys (pre-fix: 1 + 2*20 = 41 > 32 -> panic).
;
; Run:
;   zepo examples/json-handlescope-regress.lisp
;
; zepo-gol

(define big-obj
  "{\"k0\":0,\"k1\":1,\"k2\":2,\"k3\":3,\"k4\":4,\"k5\":5,\"k6\":6,\"k7\":7,\"k8\":8,\"k9\":9,\"k10\":10,\"k11\":11,\"k12\":12,\"k13\":13,\"k14\":14,\"k15\":15,\"k16\":16,\"k17\":17,\"k18\":18,\"k19\":19}")

(define r (json-parse big-obj))

(cond
  ((and (ok? r) (hash-table? (result-value r))
        (= 19 (hash-get (result-value r) "k19")))
   (display "OK  20-key object parsed without HandleScope overflow") (newline))
  (else
   (display "FAIL ") (write r) (newline) (exit 1)))
