//! Signal handling primitives: signal-set! and signal-number.
//!
//! Uses a global atomic pending-flag array set by the C-level signal handler.
//! The VM polls between dispatch iterations via pollSignals().

// zepo-6qx
const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

// ── Global state ──────────────────────────────────────────────────────────────

// zepo-6qx
/// Atomic pending flags — set by C signal handler, cleared by VM poll.
var pending: [32]std.atomic.Value(bool) = blk: {
    var arr: [32]std.atomic.Value(bool) = undefined;
    for (&arr) |*a| a.* = std.atomic.Value(bool).init(false);
    break :blk arr;
};

/// Registered Lisp handler Values (null = no handler).
/// Only accessed from the single VM thread (except C handler which only
/// writes the atomic pending flags, not these values).
var handlers: [32]?Value = [_]?Value{null} ** 32;

// ── C-level signal handler ────────────────────────────────────────────────────

// zepo-6qx
fn cSignalHandler(sig: c_int) callconv(.c) void {
    if (sig >= 0 and sig < 32)
        pending[@intCast(sig)].store(true, .release);
}

// ── sigaction bindings ────────────────────────────────────────────────────────

// zepo-6qx
/// macOS sigset_t is 4 x u32 (= 128-bit mask).
const Sigaction = extern struct {
    handler: *const fn (c_int) callconv(.c) void,
    mask: [4]u32,
    flags: c_int,
};

const SA_RESTART: c_int = 0x0002;

extern "c" fn sigaction(sig: c_int, act: *const Sigaction, oact: ?*Sigaction) c_int;

// ── Signal name table ─────────────────────────────────────────────────────────

// zepo-6qx
const SigEntry = struct { name: []const u8, num: c_int };

const SIG_TABLE: []const SigEntry = &.{
    .{ .name = "SIGHUP", .num = 1 },
    .{ .name = "SIGINT", .num = 2 },
    .{ .name = "SIGQUIT", .num = 3 },
    .{ .name = "SIGTERM", .num = 15 },
    .{ .name = "SIGUSR1", .num = 10 },
    .{ .name = "SIGUSR2", .num = 12 },
};

fn lookupSigName(name: []const u8) ?c_int {
    for (SIG_TABLE) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.num;
    }
    return null;
}

// ── VM poll hook ──────────────────────────────────────────────────────────────

// zepo-6qx
/// Called periodically by the VM dispatch loop to fire pending Lisp handlers.
pub fn pollSignals(vm: *VM) LispError!void {
    for (0..32) |i| {
        if (pending[i].load(.acquire)) {
            pending[i].store(false, .release);
            if (handlers[i]) |handler| {
                _ = try vm.callValue(handler, &[_]Value{});
            }
        }
    }
}

// ── Primitives ────────────────────────────────────────────────────────────────

// zepo-6qx
/// (signal-set! sig-sym handler-fn) → #f
/// Registers a Lisp thunk as the handler for the named signal and installs
/// the C-level handler via sigaction.
pub fn primSignalSet(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    const sym = args[0];
    const handler = args[1];
    if (!objects.isSymbol(sym)) return error.TypeError;
    if (!objects.isProcedure(handler)) return error.TypeError;

    const name = objects.symbolName(sym);
    const signum = lookupSigName(name) orelse return value_mod.FALSE;
    if (signum < 0 or signum >= 32) return value_mod.FALSE;

    handlers[@intCast(signum)] = handler;

    const act = Sigaction{
        .handler = cSignalHandler,
        .mask = [4]u32{ 0, 0, 0, 0 },
        .flags = SA_RESTART,
    };
    _ = sigaction(signum, &act, null);

    return value_mod.FALSE;
}

// zepo-6qx
/// (signal-number sig-sym) → integer or #f
/// Returns the OS signal number for a signal name symbol.
pub fn primSignalNumber(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const sym = args[0];
    if (!objects.isSymbol(sym)) return error.TypeError;

    const name = objects.symbolName(sym);
    const signum = lookupSigName(name) orelse return value_mod.FALSE;
    return value_mod.fixnum(@intCast(signum));
}

// zepo-6qx
/// (getpid) → integer
/// Returns the current process ID.
pub fn primGetpid(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 0) return error.ArityMismatch;
    return value_mod.fixnum(@intCast(std.c.getpid()));
}
