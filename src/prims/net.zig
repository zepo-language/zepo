//! TCP networking primitives.
//! zepo-04p: std.net was removed in Zig 0.16. Stubs return IOError until
//! rewritten for std.Io networking.

const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

pub const TAG_TCP_CONN: u64 = 0x74637370;
pub const TAG_TCP_SERVER: u64 = 0x74637376;

pub fn primTcpConnect(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
pub fn primTcpSend(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
pub fn primTcpRecv(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
pub fn primTcpClose(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
pub fn primTcpSocketQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
pub fn primTcpServerQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
pub fn primTcpListen(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
pub fn primTcpAccept(vm: *VM, args: []const Value) LispError!Value {
    _ = vm; _ = args; return error.IOError;
}
