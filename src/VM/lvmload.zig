const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");

pub inline fn load(L: *lua.State, chunkname: [:0]const u8, bytecode: []const u8, env: i32) !void {
    if (c.luau_load(@ptrCast(L), chunkname.ptr, bytecode.ptr, bytecode.len, env) != 0)
        return error.Fail;
}
