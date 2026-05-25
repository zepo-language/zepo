; gc-spanning-card-regress.lisp — regression for zepo-gol (part 2).
;
; Large objects (e.g. a 768-float embedding vector = 769 words = 6152 bytes)
; SPAN more than one 4096-byte card. The old-gen remembered-set only recorded
; an object's START card (card_starts[cardIdx(start)]), so when a minor GC
; scanned a dirty LATER card of a spanning object it began the walk from a
; different object and never visited the spanning object's slots in that card.
; Those slots' young targets (the float elements) were then collected, leaving
; the vector pointing at reused memory — store-search later read a non-number
; element and raised TypeError.
;
; Repro: build a store of 60 spanning 768-float vectors, churn the heap to
; force minor GCs (promotion + young collection), then search. Pre-fix this
; deterministically raises TypeError in store-search. Offline (stub embedder).
;
; Run:
;   zepo examples/gc-spanning-card-regress.lisp
;
; zepo-gol

(import :libs (orch/registry))
(import :libs (orch/vector_store))
(import :libs (orch/corpus))

(define (big-vec n)
  (let ((v (make-vector n 0.0)))
    (let loop ((i 0))
      (if (< i n) (begin (vector-set! v i (+ 1.0 (* i 0.001))) (loop (+ i 1))) v))))

(define (stub t) (ok (big-vec 768)))            ; 768-float vec spans 2 cards

(define sources (result-value (resolve-sources "lib/orch/**/*.lisp")))
(define store (result-value (build-index-with sources stub "/tmp/zepo-gol-span-cache.json")))

; Force minor GCs so spanning vectors promote and their young float elements
; are subject to collection.
(let loop ((i 0)) (if (< i 200000) (begin (cons i (number->string i)) (loop (+ i 1)))))

(define q (big-vec 768))
(define hits (store-search store q 3))

(cond
  ((= 3 (length hits))
   (display "OK  spanning-vector store survived GC (no remembered-set gap)") (newline))
  (else
   (display "FAIL unexpected hits: ") (display (length hits)) (newline) (exit 1)))
