const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");

pub fn openlibs(L: *lua.State) void {
    c.luaL_openlibs(@ptrCast(L));
}

pub fn sandbox(L: *lua.State) void {
    c.luaL_sandbox(@ptrCast(L));
}

pub fn sandboxthread(L: *lua.State) void {
    c.luaL_sandboxthread(@ptrCast(L));
}
