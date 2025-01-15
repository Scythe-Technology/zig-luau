const config = @import("luaconf.zig");

pub const L_Umaxalign = config.I_USER_ALIGNMENT_T;

///
/// type for virtual-machine instructions
/// must be an unsigned with (at least) 4 bytes (see details in lopcodes.h)
///
pub const Instruction = u32;
