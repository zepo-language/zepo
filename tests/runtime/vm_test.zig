//! Tests for VM dispatch and fiber scheduler.
//! Covers: fiber spawn/join, yield ordering, sleep, deep recursion,
//! fiber error propagation, and multi-fiber channel handoff.

// zepo-yz1

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;
const sched_mod = zepo.vm.sched;

const Rig = struct {
    gc: zepo.GC,
    syms: runtime.SymbolTable,
    globals: runtime.GlobalEnv,
    ctx: runtime.EvalContext,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !*Rig {
        const r = try allocator.create(Rig);
        errdefer allocator.destroy(r);
        r.allocator = allocator;
        r.gc = try zepo.GC.init(allocator);
        errdefer r.gc.deinit();
        r.syms = try runtime.SymbolTable.init(&r.gc, allocator);
        errdefer r.syms.deinit();
        r.globals = try runtime.GlobalEnv.init(&r.gc, allocator);
        errdefer r.globals.deinit();
        try zepo.prims.registerAll(&r.gc, &r.globals, &r.syms);
        r.ctx = try runtime.EvalContext.init(&r.gc, &r.syms, &r.globals, allocator);
        errdefer r.ctx.deinit();
        try runtime.loadStdlib(&r.ctx);
        return r;
    }

    fn deinit(r: *Rig) void {
        const a = r.allocator;
        r.ctx.deinit();
        r.globals.deinit();
        r.syms.deinit();
        r.gc.deinit();
        a.destroy(r);
    }

    fn eval(r: *Rig, src: []const u8) !abi.Value {
        return r.ctx.evalString(src, "<vm_test>");
    }
};

fn expectInt(v: abi.Value, n: i63) !void {
    try std.testing.expect(value_mod.isFixnum(v));
    try std.testing.expectEqual(n, value_mod.fixnumVal(v));
}

fn expectBool(v: abi.Value, b: bool) !void {
    if (b) try std.testing.expect(!value_mod.isFalse(v))
    else   try std.testing.expect(value_mod.isFalse(v));
}

// ── Scheduler primitive ────────────────────────────────────────────────────

test "scheduler: nowMs returns non-negative monotonic time" {
    const t0 = sched_mod.nowMs();
    const t1 = sched_mod.nowMs();
    try std.testing.expect(t0 >= 0);
    try std.testing.expect(t1 >= t0);
}

// ── Deep recursion ─────────────────────────────────────────────────────────

test "vm: tail-recursive loop does not overflow" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // Named-let loop — TCO must handle 100k iterations without stack overflow.
    const v = try rig.eval(
        \\(let loop ((i 0) (acc 0))
        \\  (if (= i 100000) acc
        \\      (loop (+ i 1) (+ acc i))))
    );
    try expectInt(v, 4999950000);
}

test "vm: mutual recursion via even?/odd? (non-trivial call depth)" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define (my-even? n)
        \\  (if (= n 0) #t (my-odd? (- n 1))))
        \\(define (my-odd? n)
        \\  (if (= n 0) #f (my-even? (- n 1))))
    );
    try expectBool(try rig.eval("(my-even? 1000)"), true);
    try expectBool(try rig.eval("(my-odd? 999)"), true);
}

// ── Fiber lifecycle ────────────────────────────────────────────────────────

test "vm: fiber-join returns fiber result" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    const v = try rig.eval(
        \\(let ((f (spawn (lambda () 42))))
        \\  (fiber-join f))
    );
    try expectInt(v, 42);
}

test "vm: multiple fibers run and join independently" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define f1 (spawn (lambda () 1)))
        \\(define f2 (spawn (lambda () 2)))
        \\(define f3 (spawn (lambda () 3)))
    );
    try expectInt(try rig.eval("(fiber-join f1)"), 1);
    try expectInt(try rig.eval("(fiber-join f2)"), 2);
    try expectInt(try rig.eval("(fiber-join f3)"), 3);
}

test "vm: fiber-join on already-finished fiber returns its value" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval("(define f (spawn (lambda () 99)))");
    // Join twice — second join should also return 99.
    try expectInt(try rig.eval("(fiber-join f)"), 99);
    try expectInt(try rig.eval("(fiber-join f)"), 99);
}

// ── Yield and cooperative scheduling ──────────────────────────────────────

test "vm: yield allows other fibers to run" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // Two fibers that each yield several times — they interleave but both
    // complete, and the channel collects all values.
    _ = try rig.eval(
        \\(define ch (make-channel 16))
        \\(define f1
        \\  (spawn (lambda ()
        \\    (channel-send! ch 'a)
        \\    (yield)
        \\    (channel-send! ch 'b)
        \\    (yield)
        \\    (channel-send! ch 'c))))
        \\(define f2
        \\  (spawn (lambda ()
        \\    (channel-send! ch 1)
        \\    (yield)
        \\    (channel-send! ch 2)
        \\    (yield)
        \\    (channel-send! ch 3))))
        \\(fiber-join f1)
        \\(fiber-join f2)
    );
    // Collect all 6 values — order may vary but count must be 6.
    const len = try rig.eval(
        \\(let loop ((n 0))
        \\  (if (channel-empty? ch) n
        \\      (begin (channel-recv! ch) (loop (+ n 1)))))
    );
    try expectInt(len, 6);
}

// ── Channel + fiber handoff ────────────────────────────────────────────────

test "vm: producer-consumer fiber pair via channel" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    const v = try rig.eval(
        \\(let* ((ch (make-channel 4))
        \\       (producer (spawn (lambda ()
        \\                    (channel-send! ch 10)
        \\                    (channel-send! ch 20)
        \\                    (channel-send! ch 30))))
        \\       (sum (+ (channel-recv! ch)
        \\               (channel-recv! ch)
        \\               (channel-recv! ch))))
        \\  (fiber-join producer)
        \\  sum)
    );
    try expectInt(v, 60);
}

// ── Sleep ──────────────────────────────────────────────────────────────────

test "vm: sleep returns without error for tiny duration" {
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    // sleep takes seconds; 0.001 = 1 ms.  Just verifies it completes.
    _ = try rig.eval("(sleep 0.001)");
}

// ── Worker teardown (zepo-p5b) ────────────────────────────────────────────

test "vm: worker parked on channel-recv shuts down cleanly at VM.deinit" {
    // zepo-p5b: a worker parked on a cross-thread channel must not segfault
    // (or hang) when the parent VM tears down without explicit shutdown.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit(); // <- the test: this must complete without crash/hang.
    _ = try rig.eval(
        \\(define ch (make-channel 4))
        \\(spawn-worker
        \\  "(lambda (c)
        \\     (let loop ()
        \\       (let ((x (channel-recv! c)))
        \\         (when x (loop)))))"
        \\  ch)
    );
    // No sentinel send, no worker-alive? drain — exercise the unhelpful exit path.
}

test "vm: worker that has not yet entered scheduler shuts down cleanly" {
    // zepo-p5b: race-y case — parent tears down before the worker thread has
    // finished stdlib load and published its wakeup_fd. stopAndJoin must
    // tolerate a -1 wakeup_fd and still join cleanly.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    _ = try rig.eval(
        \\(define ch (make-channel 4))
        \\(spawn-worker
        \\  "(lambda (c) (channel-recv! c))"
        \\  ch)
    );
}

// ── Register pressure ──────────────────────────────────────────────────────

test "vm: many local bindings in one frame" {
    // Exercises register allocation for a function with many let-bound vars.
    const rig = try Rig.init(std.testing.allocator);
    defer rig.deinit();
    const v = try rig.eval(
        \\(let ((a 1) (b 2) (c 3) (d 4) (e 5)
        \\      (f 6) (g 7) (h 8) (i 9) (j 10)
        \\      (k 11) (l 12) (m 13) (n 14) (o 15)
        \\      (p 16) (q 17) (r 18) (s 19) (t 20))
        \\  (+ a b c d e f g h i j k l m n o p q r s t))
    );
    try expectInt(v, 210);
}
