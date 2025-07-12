const c = @import("c");
const std = @import("std");

const lmem = @import("lmem.zig");
const lstate = @import("lstate.zig");

const lua = @import("lua.zig");
const ldebug = @import("ldebug.zig");
const lobject = @import("lobject.zig");

extern "c" fn zig_luau_luaD_throw(L: *lua.State, errcode: i32) noreturn;

pub const MAX_STACK_SIZE = (1024 / @sizeOf(lobject.TValue)) * 1024 * 1024;

pub inline fn throw(L: *lua.State, errcode: lua.Status) noreturn {
    zig_luau_luaD_throw(L, @intFromEnum(errcode));
}

pub inline fn getgrownstacksize(L: *lua.State, n: usize) usize {
    return if (n <= L.stacksize) 2 * @as(u32, @intCast(L.stacksize)) else @as(u32, @intCast(L.stacksize)) + n;
}

pub inline fn Dcheckstackfornewci(L: *lua.State, n: usize) !void {
    if (@intFromPtr(L.stack_last) - @intFromPtr(L.top) < n * @sizeOf(lobject.TValue))
        try Dreallocstack(L, getgrownstacksize(L, n), true)
    else
        try Dreallocstack(L, L.stacksize - lstate.EXTRA_STACK, true);
}

pub inline fn Dcheckstack(L: *lua.State, n: usize) !void {
    if (@intFromPtr(L.stack_last) - @intFromPtr(L.top) < n * @sizeOf(lobject.TValue))
        try Dgrowstack(L, n)
    else
        try Dreallocstack(L, @as(u32, @intCast(L.stacksize)) - lstate.EXTRA_STACK, false);
}

pub inline fn incr_top(L: *lua.State) !void {
    try Dcheckstack(L, 1);
    L.top = L.top.add_num(1);
}

pub inline fn expandstacklimit(L: *lua.State, p: *lobject.TValue) void {
    std.debug.assert(@intFromPtr(p) <= @intFromPtr(L.stack_last));
    if (@intFromPtr(L.ci.?.top) < @intFromPtr(p))
        L.ci.?.top = p;
}

fn correctstack(L: *lua.State, oldstack: [*]lobject.TValue) void {
    const oldstack_0 = @intFromPtr(oldstack);
    const newstack_0 = @intFromPtr(L.stack);
    L.top = @ptrFromInt((@intFromPtr(L.top) - oldstack_0) + newstack_0);
    var up: ?*lobject.UpVal = L.openupval;
    while (up) |uv| : (up = uv.u.open.threadnext)
        uv.v = @ptrFromInt((@intFromPtr(uv.v) - oldstack_0) + newstack_0);
    var ci = L.base_ci;
    const top_bound = @intFromPtr(L.ci);
    while (@intFromPtr(ci) <= top_bound) : (ci = ci.?.add_num(1)) {
        ci.?.top = @ptrFromInt((@intFromPtr(ci.?.top) - oldstack_0) + newstack_0);
        ci.?.base = @ptrFromInt((@intFromPtr(ci.?.base) - oldstack_0) + newstack_0);
        ci.?.func = @ptrFromInt((@intFromPtr(ci.?.func) - oldstack_0) + newstack_0);
    }
    L.base = @ptrFromInt((@intFromPtr(L.base) - oldstack_0) + newstack_0);
}

pub fn Dreallocstack(L: *lua.State, newsize: usize, fornewci: bool) !void {
    // throw 'out of memory' error because space for a custom error message cannot be guaranteed here
    if (newsize > MAX_STACK_SIZE) {
        // reallocation was performed to setup a new CallInfo frame, which we have to remove
        if (fornewci) {
            const cip: *lstate.CallInfo = L.ci.?.sub_num(1);

            L.ci = cip;
            L.base = cip.base;
            L.top = cip.top;
        }

        return error.OutOfMemory;
    }

    const realsize = newsize + lstate.EXTRA_STACK;
    if (L.stacksize == realsize) {
        // fast path: skip reallocation
        return;
    }

    const oldstack = L.stack;
    std.debug.assert(L.stack_last.sub(@ptrCast(L.stack)) == L.stacksize - lstate.EXTRA_STACK);
    L.stack = try lmem.Mreallocarray(L, lobject.TValue, L.stack, @intCast(L.stacksize), realsize, L.header.memcat);
    const newstack = L.stack;
    for (@intCast(L.stacksize)..realsize) |i|
        newstack[i].setnilvalue();
    L.stacksize = @intCast(realsize);
    L.stack_last = newstack[0].add_num(newsize);
    correctstack(L, oldstack);
}

pub fn DreallocCI(L: *lua.State, newsize: usize) !void {
    const oldci = L.base_ci;
    L.base_ci = @ptrCast(@alignCast(try lmem.Mreallocarray(L, lstate.CallInfo, @ptrCast(@alignCast(L.base_ci.?)), @intCast(L.size_ci), newsize, L.header.memcat)));
    L.size_ci = @intCast(newsize);
    L.ci = @ptrFromInt((@intFromPtr(L.ci) - @intFromPtr(oldci)) + @intFromPtr(L.base_ci));
    L.end_ci = L.base_ci.?.add_num(newsize - 1);
}

pub fn Dgrowstack(L: *lua.State, n: usize) !void {
    try Dreallocstack(L, getgrownstacksize(L, n), false);
}

pub inline fn @"resume"(L: *lua.State, from: ?*lua.State, narg: i32) lua.Status {
    return @enumFromInt(c.lua_resume(@ptrCast(L), @ptrCast(from), narg));
}

pub inline fn resumeerror(L: *lua.State, from: ?*lua.State) lua.Status {
    return @enumFromInt(c.lua_resumeerror(@ptrCast(L), @ptrCast(from)));
}

pub fn yield(L: *lua.State, nresults: u32) !i32 {
    if (L.nCcalls > L.baseCcalls)
        try ldebug.GrunerrorL(L, "attempt to yield across metamethod/C-call boundary", .{});
    L.base = L.top.sub_num(nresults);
    L.curr_status = @intFromEnum(lua.Status.Yield);
    return -1;
}

pub fn @"break"(L: *lua.State) !i32 {
    if (L.nCcalls > L.baseCcalls)
        try ldebug.GrunerrorL(L, "attempt to yield across metamethod/C-call boundary", .{});
    L.curr_status = @intFromEnum(lua.Status.Break);
    return -1;
}

pub fn isyieldable(L: *lua.State) bool {
    return L.nCcalls <= L.baseCcalls;
}
