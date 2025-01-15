const c = @import("c");
const config = @import("config");

pub const LUAU_VERSION = config.luau_version;

/// Can be used to reconfigure internal error handling to use longjmp instead of C++ EH
pub const USE_LONGJMP = c.LUA_USE_LONGJMP;

/// LUA_IDSIZE gives the maximum size for the description of the source
pub const IDSIZE = c.LUA_IDSIZE;

/// LUA_MINSTACK is the guaranteed number of Lua stack slots available to a C function
pub const MINSTACK = c.LUA_MINSTACK;

/// LUAI_MAXCSTACK limits the number of Lua stack slots that a C function can use
pub const I_MAXCSTACK = c.LUAI_MAXCSTACK;

/// LUAI_MAXCALLS limits the number of nested calls
pub const I_MAXCALLS = c.LUAI_MAXCALLS;

/// LUAI_MAXCCALLS is the maximum depth for nested C calls; this limit depends on native stack size
pub const I_MAXCCALLS = c.LUAI_MAXCCALLS;

/// buffer size used for on-stack string operations; this limit depends on native stack size
pub const BUFFERSIZE = c.LUA_BUFFERSIZE;

/// number of valid Lua userdata tags
pub const UTAG_LIMIT = c.LUA_UTAG_LIMIT;

/// number of valid Lua lightuserdata tags
pub const LUTAG_LIMIT = c.LUA_LUTAG_LIMIT;

/// upper bound for number of size classes used by page allocator
pub const SIZECLASSES = c.LUA_SIZECLASSES;

/// available number of separate memory categories
pub const MEMORY_CATEGORIES = c.LUA_MEMORY_CATEGORIES;

/// minimum size for the string table (must be power of 2)
pub const MINSTRTABSIZE = c.LUA_MINSTRTABSIZE;

/// maximum number of captures supported by pattern matching
pub const MAXCAPTURES = c.LUA_MAXCAPTURES;

pub const I_USER_ALIGNMENT_T = extern union {
    u: f64,
    s: *anyopaque,
    l: c_long,
};

/// The length of Luau vector values, either 3 or 4.
pub const VECTOR_SIZE = if (config.use_4_vector) 4 else 3;

pub const EXTRA_SIZE = (VECTOR_SIZE - 2);
