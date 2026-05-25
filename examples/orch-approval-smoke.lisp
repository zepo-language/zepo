; orch-approval-smoke.lisp — offline smoke for lib/orch/approval.lisp.
;
; The safety-critical part is approved?: a repo edit happens ONLY on an
; explicit yes. Anything ambiguous, empty, or EOF must deny. Also covers
; describe-action (what the user sees before approving) and the
; integration path: a scripted DENY confirm must leave disk untouched.
;
; Run:
;   zepo examples/orch-approval-smoke.lisp
;
; zepo-dad

(import :libs (orch/registry))
(import :libs (orch/exec))
(import :libs (orch/agent))
(import :libs (orch/tools))
(import :libs (orch/approval))

(define (assert-eq label want got)
  (cond
    ((equal? want got) (display "OK  ") (display label) (newline))
    (else (display "FAIL ") (display label)
          (display " want=") (display want)
          (display " got=") (display got) (newline)
          (exit 1))))

; --- approved? : explicit yes only; everything else denies ---
(assert-eq "y"        #t (approved? "y"))
(assert-eq "yes"      #t (approved? "yes"))
(assert-eq "Y"        #t (approved? "Y"))
(assert-eq "padded"   #t (approved? "  yes  "))
(assert-eq "n"        #f (approved? "n"))
(assert-eq "empty"    #f (approved? ""))
(assert-eq "maybe"    #f (approved? "maybe"))
(assert-eq "eof"      #f (approved? (eof-object)))

; --- describe-action surfaces the path + content preview for edit_file ---
(define (has? s sub) (if (string-contains s sub) #t #f))
(let ((d (describe-action '(tool-call "e1" edit_file
                                      ((path . "src/foo.lisp") (content . "hello world"))))))
  (assert-eq "describe shows path"    #t (has? d "src/foo.lisp"))
  (assert-eq "describe shows content" #t (has? d "hello world")))

; --- integration: a DENY confirm leaves disk untouched; loop still ends ---
(define root "/tmp/zepo-dad-root")
(shell (string-append "rm -rf " root " && mkdir -p " root))
(reset-registry!)
(register-builtin-tools!)
(set-tools-root! root)

; stub planner: edit; if the edit succeeded (approved), run a verify step
; before finishing (zepo-m4z requires it); a denied edit never wrote, so
; it can finish straight away.
(define (ok-step? id ctx)
  (let ((p (assoc id ctx))) (and p (ok? (cdr p)))))
(define (stub-edit goal history ctx)
  (cond ((null? ctx)
         '(tool-call "m1" edit_file ((path . "out.txt") (content . "agent wrote this"))))
        ((and (ok-step? "m1" ctx) (not (assoc "v1" ctx)))
         '(tool-call "v1" run_tests ((cmd . "true"))))
        (else (list 'finish "done"))))

(let ((r (run-agent "edit a file" 8 stub-edit (lambda (action) #f))))   ; deny
  (assert-eq "deny: loop finishes"   '(ok . "done") r)
  (assert-eq "deny: NO file on disk" #f             (file-exists? (string-append root "/out.txt"))))

; --- integration: an APPROVE confirm performs the write ---
(let ((r (run-agent "edit a file" 8 stub-edit (lambda (action) #t))))   ; approve
  (assert-eq "approve: loop finishes" '(ok . "done")     r)
  (assert-eq "approve: file written"  "agent wrote this" (file-read-string (string-append root "/out.txt"))))

(display "all checks passed.") (newline)
