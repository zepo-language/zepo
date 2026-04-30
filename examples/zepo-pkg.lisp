; zepo-pkg — package manager for Zepo.
;
; Run:
;   zepo examples/zepo-pkg.lisp -- search csv --registry examples/registry.json
;   zepo examples/zepo-pkg.lisp -- install clap --registry examples/registry.json --packages /tmp/pkgs
;   zepo examples/zepo-pkg.lisp -- install clap --dry-run --registry examples/registry.json
;   zepo examples/zepo-pkg.lisp -- list --packages /tmp/pkgs
;   zepo examples/zepo-pkg.lisp -- remove clap --packages /tmp/pkgs

(import clap)

;;; ── Default paths ──────────────────────────────────────────────────────────

(define (default-registry-path)
  (let ((home (getenv "HOME")))
    (if home
        (string-append home "/.zepo/registry.json")
        ".zepo/registry.json")))

(define (default-packages-path)
  (let ((home (getenv "HOME")))
    (if home
        (string-append home "/.zepo/packages")
        ".zepo/packages")))

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

;;; ── Installed-package helpers ──────────────────────────────────────────────

(define (pkg-dir packages-dir name)
  (string-append packages-dir "/" name))

(define (pkg-installed? packages-dir name)
  (file-exists? (pkg-dir packages-dir name)))

(define (installed-packages packages-dir)
  (if (file-exists? packages-dir)
      (filter (lambda (n) (not (string-prefix? "." n)))
              (directory-list packages-dir))
      '()))

;;; ── Dependency helpers ─────────────────────────────────────────────────────

(define (deps-list pkg)
  ; JSON arrays parse as vectors; normalise to a list.
  (let ((raw (pkg-field pkg "dependencies")))
    (cond ((not raw)     '())
          ((null? raw)   '())
          ((vector? raw) (vec->list raw))
          (#t            raw))))

(define (resolve-dep-repo name registry-p)
  (let ((found (vec-fold (lambda (acc p)
                           (if (equal? (pkg-field p "name") name) p acc))
                         #f (load-registry registry-p))))
    (if found (or (pkg-field found "repo") "") "")))

(define (install-dependencies pkg packages-d registry-p dry-run)
  (let ((deps (deps-list pkg)))
    (if (null? deps)
        #f
        (begin
          (display "Installing dependencies...\n")
          (for-each
            (lambda (dep)
              (if (pkg-installed? packages-d dep)
                  (begin (display (string-append "  " dep " already installed")) (newline))
                  (let* ((repo (resolve-dep-repo dep registry-p))
                         (dest (pkg-dir packages-d dep))
                         (cmd  (string-append "git clone --depth 1 " repo " " dest)))
                    (if dry-run
                        (begin (display (string-append "  would clone " dep " → " dest)) (newline))
                        (shell/status cmd)))))
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
         (dry-run    (ctx-option ctx 'dry-run))
         (found      (vec-fold (lambda (acc p)
                                 (if (equal? (pkg-field p "name") name) p acc))
                               #f (load-registry registry-p))))
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
             (install-dependencies found packages-d registry-p #t))
            ((pkg-installed? packages-d name)
             (display (string-append name " is already installed")) (newline))
            (#t
             (display (string-append "Installing " name "@" version " from " repo "...\n"))
             (make-directory packages-d)
             (let ((status (shell/status (string-append "git clone --depth 1 " repo " " dest))))
               (if (= 0 status)
                   (begin
                     (display (string-append "✓ Installed " name "@" version " → " dest))
                     (newline)
                     (install-dependencies found packages-d registry-p #f))
                   (begin
                     (display (string-append "error: git clone failed (exit "
                                             (number->string status) ")"))
                     (newline))))))))))

(define (do-list ctx)
  (let* ((packages-d (or (ctx-option ctx 'packages) (default-packages-path)))
         (installed  (installed-packages packages-d)))
    (if (null? installed)
        (begin (display "No packages installed.") (newline))
        (begin
          (display (string-append (number->string (length installed))
                                  " package(s) installed in " packages-d ":\n"))
          (for-each (lambda (name)
                      (display (string-append "  " name)) (newline))
                    installed)))))

(define (do-remove ctx)
  (let* ((name       (ctx-positional ctx 'name))
         (packages-d (or (ctx-option ctx 'packages) (default-packages-path)))
         (dest       (pkg-dir packages-d name)))
    (if (not (pkg-installed? packages-d name))
        (begin (display (string-append "error: " name " is not installed")) (newline))
        (let ((status (shell/status (string-append "rm -rf " dest))))
          (if (= 0 status)
              (begin (display (string-append "✓ Removed " name)) (newline))
              (begin (display (string-append "error: failed to remove " dest)) (newline)))))))

;;; ── Program definition ─────────────────────────────────────────────────────

(defprogram zepo-pkg
  :name "zepo-pkg"
  :version "0.1.0"
  :summary "Package manager for Zepo"
  :description "Search, install, list, and remove Zepo packages."
  :global-options (list
    (option 'registry :long "registry" :short "r" :kind 'value
            :config "registry"
            :help "Path to registry JSON file")
    (option 'packages :long "packages" :short "p" :kind 'value
            :config "packages"
            :help "Path to packages install directory"))

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
