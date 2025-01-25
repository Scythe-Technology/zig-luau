const lua = @import("lua.zig");

pub const TMS = enum {
    TM_INDEX,
    TM_NEWINDEX,
    TM_MODE,
    TM_NAMECALL,
    TM_CALL,
    TM_ITER,
    TM_LEN,
    TM_EQ, // last tag method with `fast' access
    TM_ADD,
    TM_SUB,
    TM_MUL,
    TM_DIV,
    TM_IDIV,
    TM_MOD,
    TM_POW,
    TM_UNM,
    TM_LT,
    TM_LE,
    TM_CONCAT,
    TM_TYPE,
    TM_METATABLE,
    TM_N, // number of elements in the enum
};

pub const N: comptime_int = @intFromEnum(TMS.TM_N);

pub const typenames = [_][:0]const u8{
    // ORDER TYPE
    "nil",
    "boolean",

    "userdata",
    "number",
    "vector",

    "string",

    "table",
    "function",
    "userdata",
    "thread",
    "buffer",
};

pub const eventname = [_][:0]const u8{
    // ORDER TM

    "__index",
    "__newindex",
    "__mode",
    "__namecall",
    "__call",
    "__iter",
    "__len",

    "__eq",

    "__add",
    "__sub",
    "__mul",
    "__div",
    "__idiv",
    "__mod",
    "__pow",
    "__unm",

    "__lt",
    "__le",
    "__concat",
    "__type",
    "__metatable",
};

comptime {
    if (typenames.len != lua.Type.T_COUNT)
        @compileError("typenames size mismatch");
    if (eventname.len != N)
        @compileError("eventname size mismatch");
    if (@intFromEnum(TMS.TM_EQ) >= 8)
        @compileError("fasttm optimization stores a bitfield with metamethods in a byte");
}

pub const LONGEST_TYPENAME_SIZE = res: {
    var large = 0;
    for (typenames) |name|
        large = @max(large, name.len);
    break :res large;
};
