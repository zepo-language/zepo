//! GC public surface.

pub const collector = @import("collector.zig");
pub const nursery = @import("nursery.zig");
pub const oldgen = @import("oldgen.zig");
pub const cards = @import("cards.zig");
pub const roots = @import("roots.zig");
pub const verifier = @import("verifier.zig");

pub const GC = collector.GC;
pub const Nursery = collector.Nursery;
pub const OldGen = collector.OldGen;
pub const CardTable = collector.CardTable;
pub const RootSet = collector.RootSet;
pub const HandleScope = collector.HandleScope;
pub const Verifier = verifier.Verifier;
pub const MarkPhase = collector.MarkPhase;

test {
    _ = collector;
    _ = nursery;
    _ = oldgen;
    _ = cards;
    _ = roots;
    _ = verifier;
}
