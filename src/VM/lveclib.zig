const c = @import("c");

const lua = @import("lua.zig");

pub inline fn open(L: *lua.State) void {
    _ = c.luaopen_vector(@ptrCast(L));
}
