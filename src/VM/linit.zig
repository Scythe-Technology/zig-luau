const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");

pub fn Lopenlibs(L: *lua.State) void {
    c.luaL_openlibs(@ptrCast(L));
}

pub fn Lsandbox(L: *lua.State) void {
    c.luaL_sandbox(@ptrCast(L));
}

pub fn Lsandboxthread(L: *lua.State) void {
    c.luaL_sandboxthread(@ptrCast(L));
}
