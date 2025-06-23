const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");
const ldebug = @import("ldebug.zig");
const lobject = @import("lobject.zig");

pub inline fn @"resume"(L: *lua.State, from: ?*lua.State, narg: i32) lua.Status {
    return @enumFromInt(c.lua_resume(@ptrCast(L), @ptrCast(from), narg));
}

pub inline fn resumeerror(L: *lua.State, from: ?*lua.State) lua.Status {
    return @enumFromInt(c.lua_resumeerror(@ptrCast(L), @ptrCast(from)));
}

pub fn yield(L: *lua.State, nresults: u32) i32 {
    if (L.nCcalls > L.baseCcalls)
        ldebug.GrunerrorL(L, "attempt to yield across metamethod/C-call boundary", .{});
    L.base = L.top.sub_num(nresults);
    L.curr_status = @intFromEnum(lua.Status.Yield);
    return -1;
}

pub fn @"break"(L: *lua.State) i32 {
    if (L.nCcalls > L.baseCcalls)
        ldebug.GrunerrorL(L, "attempt to yield across metamethod/C-call boundary", .{});
    L.curr_status = @intFromEnum(lua.Status.Break);
    return -1;
}

pub fn isyieldable(L: *lua.State) bool {
    return L.nCcalls <= L.baseCcalls;
}
