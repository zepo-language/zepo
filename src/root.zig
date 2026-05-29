//! Zepo root module. Re-exports ABI, GC, runtime, and compiler/VM stacks.

const std = @import("std");

pub const abi = @import("abi/mod.zig");
pub const gc = @import("gc/mod.zig");
pub const runtime = @import("runtime/mod.zig");
pub const reader = @import("reader/mod.zig");
pub const ast = @import("ast/mod.zig");
pub const sema = @import("sema/mod.zig");
pub const ir = @import("ir/mod.zig");
pub const expand = @import("expand/mod.zig");
pub const cg = @import("cg/mod.zig");
pub const vm = @import("vm/mod.zig");
pub const prims = @import("prims/mod.zig");
pub const ffi = @import("ffi/zig_ffi.zig");
pub const lsp = @import("lsp/mod.zig");

pub const Value = abi.Value;
pub const ObjHeader = abi.ObjHeader;
pub const Kind = abi.Kind;
pub const Space = abi.Space;
pub const GC = gc.GC;

test {
    _ = abi;
    _ = gc;
    _ = runtime;
    _ = reader;
    _ = ast;
    _ = sema;
    _ = ir;
    _ = expand;
    _ = cg;
    _ = vm;
    _ = prims;
    _ = ffi;
    _ = lsp;
}
