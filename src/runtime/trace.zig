//! ZEPO_TRACE subsystem flags.
//!
//! Set the ZEPO_TRACE environment variable to a comma-separated list of
//! subsystem names to enable structured tracing on stderr.
//!
//!   ZEPO_TRACE=gc,module,eval,opcodes ./your-program
//!
//! Subsystems:
//!   gc      — every minor/major GC: nursery fill %, bytes promoted, root count
//!   module  — every module load attempt: name, path tried, outcome
//!   eval    — every top-level form entering evalNonModuleForm: source location
//!   opcodes — per-opcode trace in the VM dispatch loop (very verbose)
//!
//! Zero cost when the flag is not set — all hot paths branch on a single bool.

const std = @import("std");

pub const TraceFlags = struct {
    gc:      bool = false,
    module:  bool = false,
    eval:    bool = false,
    opcodes: bool = false,

    /// Parse ZEPO_TRACE from the process environment. Uses page_allocator for
    /// the temporary string; safe to call before any arena is set up.
    pub fn fromEnv() TraceFlags {
        var flags = TraceFlags{};
        const raw = std.c.getenv("ZEPO_TRACE") orelse return flags;
        const val = std.mem.span(raw);
        var it = std.mem.splitScalar(u8, val, ',');
        while (it.next()) |seg| {
            const s = std.mem.trim(u8, seg, " \t");
            if (std.mem.eql(u8, s, "gc"))      flags.gc      = true
            else if (std.mem.eql(u8, s, "module"))  flags.module  = true
            else if (std.mem.eql(u8, s, "eval"))    flags.eval    = true
            else if (std.mem.eql(u8, s, "opcodes")) flags.opcodes = true;
        }
        return flags;
    }

    pub fn any(f: TraceFlags) bool {
        return f.gc or f.module or f.eval or f.opcodes;
    }
};
