//! Codegen aggregate module.

pub const bytecode = @import("bytecode.zig");
pub const emit = @import("emit.zig");
pub const serialize = @import("serialize.zig");

pub const Opcode = bytecode.Opcode;
pub const Instr = bytecode.Instr;
pub const CompiledFn = bytecode.CompiledFn;
pub const SafepointMap = bytecode.SafepointMap;
pub const Emitter = emit.Emitter;

test {
    _ = bytecode;
    _ = emit;
}
