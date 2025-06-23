const config = @import("luaconf.zig");

///
/// type for virtual-machine instructions
/// must be an unsigned with (at least) 4 bytes (see details in lopcodes.h)
///
pub const Instruction = u32;
