//! zepo-nmqj: configurable heap caps via GC.initWithSize.
//!
//! Verifies that initWithSize honors user-supplied nursery + old-gen sizes
//! and that default GC.init preserves the original 4 MiB caps.

const std = @import("std");
const zepo = @import("zepo");
const gcmod = zepo.gc;

test "zepo-nmqj: GC.init keeps the historical 4 MiB default caps" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();
    try std.testing.expectEqual(gcmod.nursery.NURSERY_SIZE, gc.nursery.size());
    try std.testing.expectEqual(gcmod.oldgen.OLD_GEN_SIZE, gc.old_gen.heapSize());
}

test "zepo-nmqj: GC.initWithSize gives a larger nursery + old-gen" {
    const alloc = std.testing.allocator;
    const cap: usize = 16 * 1024 * 1024;
    var gc = try gcmod.GC.initWithSize(alloc, cap, cap);
    defer gc.deinit();
    try std.testing.expect(gc.nursery.size() >= cap);
    try std.testing.expect(gc.old_gen.heapSize() >= cap);
}

test "zepo-nmqj: a larger nursery actually holds more user data" {
    const alloc = std.testing.allocator;
    const cap: usize = 16 * 1024 * 1024;
    var gc = try gcmod.GC.initWithSize(alloc, cap, cap);
    defer gc.deinit();
    // A vector body with 1M words = 8 MiB body + header — would not fit in the
    // 4 MiB default but does fit comfortably here.
    const v = try gc.alloc(.vector, 1024 * 1024);
    _ = v;
    try std.testing.expect(gc.nursery.used() > 4 * 1024 * 1024);
}
