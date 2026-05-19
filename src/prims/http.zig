//! HTTP client primitive.
// zepo-04p: std.http.Client requires std.Io in Zig 0.16; stubbed until Io plumbing available.

const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

pub fn primHttpRequest(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    _ = args;
    return error.IOError;
}
