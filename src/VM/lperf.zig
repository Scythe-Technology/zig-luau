const c = @import("c");

const lua = @import("lua.zig");

pub fn clock() f64 {
    return c.lua_clock();
}
