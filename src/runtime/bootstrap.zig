//! Stdlib loader. Evaluates the Zepo standard library into the given EvalContext.
//! The stdlib source (lib/stdlib.lisp) is embedded at build time via lib_opts.

const std = @import("std");
const eval_mod = @import("eval.zig");
const EvalContext = eval_mod.EvalContext;

const lib_opts = @import("lib_opts");

pub fn loadStdlib(ctx: *EvalContext) !void {
    std.debug.assert(ctx.current_module == null);
    _ = try ctx.evalString(lib_opts.stdlib_src, "<stdlib>");
}
