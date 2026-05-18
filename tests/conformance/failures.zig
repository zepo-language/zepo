//! Failure-mode conformance tests. Each asserts a specific error.

const std = @import("std");
const zepo = @import("zepo");
const helpers = @import("helpers.zig");
const Rig = helpers.Rig;

const alloc = std.testing.allocator;

test "fail: unbound variable" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try std.testing.expectError(error.UnboundVariable, r.eval("undefined-var-xyz"));
}

test "fail: arity mismatch" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.eval("(define (f x) x)");
    try std.testing.expectError(error.ArityMismatch, r.eval("(f 1 2)"));
}

test "fail: car of non-pair" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try std.testing.expectError(error.CarOfNonPair, r.eval("(car 42)"));
}

test "fail: cdr of non-pair" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try std.testing.expectError(error.CdrOfNonPair, r.eval("(cdr 42)"));
}

test "fail: division by zero" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try std.testing.expectError(error.DivisionByZero, r.eval("(/ 1 0)"));
}

test "fail: type error in arithmetic" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try std.testing.expectError(error.TypeError, r.eval("(+ 1 \"a\")"));
}

test "fail: invalid special form" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try std.testing.expectError(error.InvalidSpecialForm, r.eval("(define)"));
}

test "fail: prim called with wrong arity" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    try std.testing.expectError(error.ArityMismatch, r.eval("(cons 1)"));
}

// zepo-01r: vm_max_regs must thread from EvalContext through to VM.init.
// This catches the regression where pushFast call sites swallow StackOverflow
// as OutOfMemory (zepo-7be) — the EvalContext path is what the CLI uses.
test "fail: stack overflow via EvalContext vm_max_regs" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // zepo-01r: set before first eval so VM is created with this ceiling
    r.ctx.vm_max_regs = 256;
    try std.testing.expectError(error.StackOverflow, r.eval(
        \\(define (count-down n)
        \\  (if (= n 0) 0 (+ 1 (count-down (- n 1)))))
        \\(count-down 100000)
    ));
}
