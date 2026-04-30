; zepo-pkg — package manager for Zepo.
;
; File layout (XDG):
;   ~/.local/lib/zepo/<name>/         installed package code
;   ~/.local/share/zepo/registry.json remote package index (cache, re-fetchable)
;   ~/.local/share/zepo/installed.json install manifest (ground truth)
;
; Run:
;   zepo examples/zepo-pkg.lisp -- search csv --registry examples/registry.json
;   zepo examples/zepo-pkg.lisp -- install clap --registry examples/registry.json
;   zepo examples/zepo-pkg.lisp -- install clap --registry examples/registry.json --dry-run
;   zepo examples/zepo-pkg.lisp -- list
;   zepo examples/zepo-pkg.lisp -- remove clap

(import clap)

;;; ── XDG paths ──────────────────────────────────────────────────────────────

(define (zepo-share file)
  (string-append (or (getenv "HOME") "") "/.local/share/zepo/" file))

(define (zepo-lib file)
  (string-append (or (getenv "HOME") "") "/.local/lib/zepo/" file))

(define (default-registry-path)  (zepo-share "registry.json"))
(define (default-manifest-path)  (zepo-share "installed.json"))
(define (default-packages-path)  (zepo-lib ""))

(define (ensure-share-dir)
  (make-directory (zepo-share "")))

;;; ── Registry helpers ───────────────────────────────────────────────────────

(define (load-registry path)
  (if (not (file-exists? path))
      (begin
        (display (string-append "error: registry not found: " path)) (newline)
        (vector))
      (let* ((raw (file-read-string path))
             (r   (json-parse raw)))
        (if (ok? r)
            (hash-get (result-value r) "packages" (vector))
            (begin
              (display (string-append "error: invalid registry JSON: " path)) (newline)
              (vector))))))

(define (vec-fold f init v)
  (let loop ((i 0) (acc init))
    (if (>= i (vector-length v))
        acc
        (loop (+ i 1) (f acc (vector-ref v i))))))

(define (vec-filter pred v)
  (list->vector
    (reverse
      (vec-fold (lambda (acc pkg)
                  (if (pred pkg) (cons pkg acc) acc))
                '() v))))

(define (vec->list v)
  (vec-fold (lambda (acc x) (append acc (list x))) '() v))

(define (pkg-field pkg key)
  (hash-get pkg key #f))

(define (pkg-matches? pkg query)
  (let ((name    (or (pkg-field pkg "name")    ""))
        (summary (or (pkg-field pkg "summary") "")))
    (or (string-contains (string-downcase name)    (string-downcase query))
        (string-contains (string-downcase summary) (string-downcase query)))))

;;; ── Manifest (installed.json) ──────────────────────────────────────────────
;
; The manifest is a JSON array of records:
;   [{"name":"clap","version":"1.0.0","repo":"...","installed_at":1234567890}, ...]
;
; It is the ground truth for `list` and the version metadata source for
; everything else. Directory existence is still checked as a belt-and-suspenders
; guard against manual deletions.

(define (read-manifest path)
  (if (not (file-exists? path))
      '()
      (let* ((raw (file-read-string path))
             (r   (json-parse raw)))
        (if (ok? r)
            (vec->list (result-value r))
            '()))))

(define (write-manifest path records)
  (let ((r (json-stringify (list->vector records))))
    (if (ok? r)
        (file-write-string path (result-value r))
        (begin (display "error: failed to serialise manifest") (newline)))))

(define (manifest-add path name version repo)
  (let* ((existing (read-manifest path))
         (cleaned  (filter (lambda (r)
                             (not (equal? (hash-get r "name" "") name)))
                           existing))
         (rec      (let ((h (make-hash-table)))
                     (hash-set! h "name"         name)
                     (hash-set! h "version"      version)
                     (hash-set! h "repo"         repo)
                     (hash-set! h "installed_at" (current-time-ms))
                     h)))
    (write-manifest path (append cleaned (list rec)))))

(define (manifest-remove path name)
  (write-manifest path
    (filter (lambda (r) (not (equal? (hash-get r "name" "") name)))
            (read-manifest path))))

(define (manifest-find path name)
  (let loop ((records (read-manifest path)))
    (cond ((null? records) #f)
          ((equal? (hash-get (car records) "name" "") name) (car records))
          (#t (loop (cdr records))))))

;;; ── Package directory helpers ──────────────────────────────────────────────

(define (pkg-dir packages-dir name)
  (string-append packages-dir name))

(define (pkg-installed? packages-dir name)
  (file-exists? (pkg-dir packages-dir name)))

;;; ── Dependency helpers ─────────────────────────────────────────────────────

(define (deps-list pkg)
  (let ((raw (pkg-field pkg "dependencies")))
    (cond ((not raw)     '())
          ((null? raw)   '())
          ((vector? raw) (vec->list raw))
          (#t            raw))))

(define (find-in-registry registry-p name)
  (vec-fold (lambda (acc p)
              (if (equal? (pkg-field p "name") name) p acc))
            #f (load-registry registry-p)))

(define (install-dependencies pkg packages-d manifest-p registry-p dry-run)
  (let ((deps (deps-list pkg)))
    (if (null? deps)
        #f
        (begin
          (display "Installing dependencies...\n")
          (for-each
            (lambda (dep)
              (if (pkg-installed? packages-d dep)
                  (begin (display (string-append "  " dep " already installed")) (newline))
                  (let* ((found (find-in-registry registry-p dep))
                         (repo  (if found (or (pkg-field found "repo") "") ""))
                         (ver   (if found (or (pkg-field found "version") "?") "?"))
                         (dest  (pkg-dir packages-d dep))
                         (cmd   (string-append "git clone --depth 1 " repo " " dest)))
                    (if dry-run
                        (begin (display (string-append "  would clone " dep " → " dest)) (newline))
                        (let ((status (shell/status cmd)))
                          (if (= 0 status)
                              (manifest-add manifest-p dep ver repo)
                              (begin (display (string-append "  error: failed to install dep: " dep))
                                     (newline))))))))
            deps)))))

;;; ── Command handlers ───────────────────────────────────────────────────────

(define (do-search ctx)
  (let* ((query      (ctx-positional ctx 'query))
         (registry-p (or (ctx-option ctx 'registry) (default-registry-path)))
         (pkgs       (load-registry registry-p))
         (matches    (vec-filter (lambda (p) (pkg-matches? p query)) pkgs)))
    (if (= 0 (vector-length matches))
        (begin (display (string-append "No packages found matching: " query)) (newline))
        (begin
          (display (string-append "Found " (number->string (vector-length matches))
                                  " package(s) matching '" query "':\n"))
          (vec-fold (lambda (_ pkg)
                      (display (string-append
                                 "  " (or (pkg-field pkg "name") "?")
                                 "@" (or (pkg-field pkg "version") "?")
                                 "  " (or (pkg-field pkg "summary") "")))
                      (newline))
                    #f matches)))))

(define (do-install ctx)
  (let* ((name       (ctx-positional ctx 'name))
         (registry-p (or (ctx-option ctx 'registry) (default-registry-path)))
         (packages-d (or (ctx-option ctx 'packages) (default-packages-path)))
         (manifest-p (or (ctx-option ctx 'manifest) (default-manifest-path)))
         (dry-run    (ctx-option ctx 'dry-run))
         (found      (find-in-registry registry-p name)))
    (if (not found)
        (begin (display (string-append "error: package not found: " name)) (newline))
        (let* ((repo    (pkg-field found "repo"))
               (version (or (pkg-field found "version") "?"))
               (dest    (pkg-dir packages-d name)))
          (cond
            (dry-run
             (display (string-append "would install " name "@" version)) (newline)
             (display (string-append "  clone: " repo)) (newline)
             (display (string-append "  dest:  " dest)) (newline)
             (display (string-append "  manifest: " manifest-p)) (newline)
             (install-dependencies found packages-d manifest-p registry-p #t))
            ((pkg-installed? packages-d name)
             (display (string-append name " is already installed")) (newline))
            (#t
             (display (string-append "Installing " name "@" version " from " repo "...\n"))
             (ensure-share-dir)
             (make-directory packages-d)
             (let ((status (shell/status (string-append "git clone --depth 1 " repo " " dest))))
               (if (= 0 status)
                   (begin
                     (manifest-add manifest-p name version repo)
                     (display (string-append "✓ Installed " name "@" version " → " dest))
                     (newline)
                     (install-dependencies found packages-d manifest-p registry-p #f))
                   (begin
                     (display (string-append "error: git clone failed (exit "
                                             (number->string status) ")"))
                     (newline))))))))))

(define (do-list ctx)
  (let* ((manifest-p (or (ctx-option ctx 'manifest) (default-manifest-path)))
         (records    (read-manifest manifest-p)))
    (if (null? records)
        (begin (display "No packages installed.") (newline))
        (begin
          (display (string-append (number->string (length records))
                                  " package(s) installed:\n"))
          (for-each (lambda (r)
                      (display (string-append
                                 "  " (hash-get r "name" "?")
                                 "@" (hash-get r "version" "?")))
                      (newline))
                    records)))))

(define (do-remove ctx)
  (let* ((name       (ctx-positional ctx 'name))
         (packages-d (or (ctx-option ctx 'packages) (default-packages-path)))
         (manifest-p (or (ctx-option ctx 'manifest) (default-manifest-path))))
    (if (not (pkg-installed? packages-d name))
        (begin (display (string-append "error: " name " is not installed")) (newline))
        (let ((status (shell/status (string-append "rm -rf " (pkg-dir packages-d name)))))
          (if (= 0 status)
              (begin
                (manifest-remove manifest-p name)
                (display (string-append "✓ Removed " name)) (newline))
              (begin
                (display (string-append "error: failed to remove " (pkg-dir packages-d name)))
                (newline)))))))

;;; ── Program definition ─────────────────────────────────────────────────────

(defprogram zepo-pkg
  :name "zepo-pkg"
  :version "0.1.0"
  :summary "Package manager for Zepo"
  :description "Search, install, list, and remove Zepo packages.\nRegistry and manifest paths follow XDG conventions."
  :global-options (list
    (option 'registry :long "registry" :short "r" :kind 'value
            :config "registry"
            :help "Registry JSON path (default: ~/.local/share/zepo/registry.json)")
    (option 'packages :long "packages" :short "p" :kind 'value
            :config "packages"
            :help "Package install path (default: ~/.local/lib/zepo/)")
    (option 'manifest :long "manifest" :short "m" :kind 'value
            :config "manifest"
            :help "Installed manifest path (default: ~/.local/share/zepo/installed.json)"))

  (command "search"
    :summary "Search the registry for packages"
    :positionals (list
      (positional 'query :required #t :help "Search term"))
    :handler do-search)

  (command "install"
    :summary "Install a package by name"
    :positionals (list
      (positional 'name :required #t :help "Package name"))
    :options (list
      (option 'dry-run :long "dry-run" :kind 'flag
              :help "Show what would be installed without doing it"))
    :handler do-install)

  (command "list"
    :summary "List installed packages"
    :handler do-list)

  (command "remove"
    :summary "Remove an installed package"
    :positionals (list
      (positional 'name :required #t :help "Package name"))
    :handler do-remove)

  (command "help"
    :summary "Show help"
    :handler (lambda (ctx)
      (let ((prog (ctx-program ctx)))
        (display (render-help prog (plist-get prog :root-command)))
        (newline))))

  (command "docs"
    :summary "Print documentation as Markdown"
    :handler (lambda (ctx)
      (display (render-markdown (ctx-program ctx)))
      (newline))))

;;; ── Entry point ────────────────────────────────────────────────────────────

(run zepo-pkg)
