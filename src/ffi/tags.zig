//! Type tag constants for FFI opaque handles. Each FFI-returned Value is a
//! foreign-kind heap object whose body[2] word carries one of these tags.

pub const VOID: u64 = 0;
pub const I64: u64 = 1;
pub const F64: u64 = 2;
pub const BOOL: u64 = 3;
pub const STRING: u64 = 4;
