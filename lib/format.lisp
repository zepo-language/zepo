; zepo-axm: format is now a top-level native primitive (see src/prims/io.zig
; primFormat). This module is kept only so existing `(import format)` calls
; succeed; the actual `format` binding comes from the prim table.
(module format
  (export format)
  (define format format))
