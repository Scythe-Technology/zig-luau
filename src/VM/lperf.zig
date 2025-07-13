const c = @import("c");

const lua = @import("lua.zig");

extern "c" fn lua_clock() f64;

pub fn clock() f64 {
    return lua_clock();
}
