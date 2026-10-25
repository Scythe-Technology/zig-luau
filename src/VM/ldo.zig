const c = @import("c");
const std = @import("std");

const lmem = @import("lmem.zig");
const lstate = @import("lstate.zig");
const ltable = @import("ltable.zig");
const lapi = @import("lapi.zig");

const lua = @import("lua.zig");
const ldebug = @import("ldebug.zig");
const lobject = @import("lobject.zig");

const Errorset = @import("errorset.zig");

extern "c" fn zig_luau_luaD_throw(L: *lua.State, errcode: i32) noreturn;

pub const MAX_STACK_SIZE = (1024 / @sizeOf(lobject.TValue)) * 1024 * 1024;

pub inline fn throw(L: *lua.State, errcode: lua.Status) noreturn {
    zig_luau_luaD_throw(L, @backingInt(errcode));
}

pub inline fn getgrownstacksize(L: *lua.State, n: usize) usize {
    return if (n <= L.stacksize) 2 * @as(u32, @intCast(L.stacksize)) else @as(u32, @intCast(L.stacksize)) + n;
}
pub inline fn stacklimitreached(L: *lua.State, n: usize) bool {
    return @intFromPtr(L.stack_last) - @intFromPtr(L.top) <= n * @sizeOf(lobject.TValue);
}

pub inline fn Dcheckstackfornewci(L: *lua.State, n: usize) Errorset.Memory!void {
    if (@intFromPtr(L.stack_last) - @intFromPtr(L.top) < n * @sizeOf(lobject.TValue))
        try Dreallocstack(L, getgrownstacksize(L, n), true)
    else
        try Dreallocstack(L, @as(u32, @intCast(L.stacksize - lstate.EXTRA_STACK)), true);
}

pub inline fn Dcheckstack(L: *lua.State, n: usize) Errorset.Memory!void {
    if (@intFromPtr(L.stack_last) - @intFromPtr(L.top) < n * @sizeOf(lobject.TValue))
        try Dgrowstack(L, n)
    else
        try Dreallocstack(L, @as(u32, @intCast(L.stacksize - lstate.EXTRA_STACK)), false);
}

pub inline fn incr_top(L: *lua.State) Errorset.Memory!void {
    try Dcheckstack(L, 1);
    L.top += 1;
}

pub inline fn expandstacklimit(L: *lua.State, p: *lobject.TValue) void {
    std.debug.assert(@intFromPtr(p) <= @intFromPtr(L.stack_last));
    if (@intFromPtr(L.ci.?[0].top) < @intFromPtr(p))
        L.ci.?[0].top = @ptrCast(p);
}

pub inline fn isyielded(L: *lua.State) bool {
    return L.curr_status == @backingInt(lua.Status.Yield) or L.curr_status == @backingInt(lua.Status.Break) or L.curr_status == SCHEDULED_REENTRY;
}

// results from luaD_precall
pub const PCRLUA = 0; // initiated a call to a Lua function
pub const PCRC = 1; // did a call to a C function
pub const PCRYIELD = 2; // C function yielded

/// return value for a yielded C call
pub const C_CALL_YIELD = -1;

/// luaD_call can 'yield' into an immediate reentry
/// reentry will remove extra call frames from C call stack and continue execution
/// this lua_State::status code is internal and should not be used by users
pub const SCHEDULED_REENTRY = 0x7f;

pub const FinallyResult = enum(c_int) {
    Finished = 0,
    Error = 1,
    Cancelled = 2,
};

pub fn Dpreparefinalizestate(L: *lua.State, co: *lua.State, finresult: FinallyResult) void {
    std.debug.assert(co.finalizers != null);

    L.top[0].sethvalue(L, co.finalizers.?);
    L.top += 1;
    L.top[0].setnvalue(@floatFromInt(ltable.Hgetn(co.finalizers.?)));
    L.top += 1;
    L.top[0].setnvalue(@floatFromInt(@as(c_int, @intCast(@backingInt(finresult)))));
    L.top += 1;

    co.finalizers = null; // we have taken the list for processing
}

pub fn Dpreparefinalize(L: *lua.State, co: *lua.State, finresult: FinallyResult) Errorset.Coroutine!void {
    const nres: u32 = if (finresult == .Finished) @intCast(co.top - co.base) else 1;
    if (!try lapi.checkstack(L, nres + 3))
        return error.@"too many results to invoke finalizer";

    Dpreparefinalizestate(L, co, finresult);
    lapi.xmove(co, L, nres);
}

pub fn Drunfinalizers(L: *lua.State, returnstatus: bool) Errorset.Coroutine!c_int {
    const results: i32 = @intCast(lapi.gettop(L) - 4);
    const position = lapi.tointeger(L, 3) orelse 0;
    const status = lapi.tointeger(L, 4) orelse 0;

    if (position != 0) {
        if (!try lapi.checkstack(L, @intCast(results + 2)))
            return error.@"too many results to invoke finalizer";

        // decrement the position
        lapi.pushinteger(L, position - 1);
        lapi.replace(L, 3);

        // take the finalizer from the end of the table
        _ = lapi.rawgeti(L, 2, position);

        // push status string
        const label: [:0]const u8 = if (status == @backingInt(FinallyResult.Cancelled))
            "cancelled"
        else if (status == @backingInt(FinallyResult.Finished))
            "finished"
        else
            "error";
        try lapi.pushstring(L, label);

        // copy results over
        var i: i32 = 0;
        while (i < results) : (i += 1)
            lapi.pushvalue(L, 5 + i);

        // pcall with no errfunc makes ourselves the handler for any errors
        return lapi.pcallyieldable(L, results + 1, 0, 0);
    }

    if (returnstatus) {
        L.base[3].setbvalue(status != @backingInt(FinallyResult.Error)); // Replace numerical status with a boolean
        return results + 1;
    }

    if (status == @backingInt(FinallyResult.Error))
        return error.Runtime;

    return results;
}

fn correctstack(L: *lua.State, oldstack: [*]lobject.TValue) void {
    L.top = L.stack + (L.top - oldstack);
    var up: ?*lobject.UpVal = L.openupval;
    while (up) |uv| : (up = uv.u.open.threadnext)
        uv.v = @ptrCast(L.stack + (@as([*]lobject.TValue, @ptrCast(uv.v)) - oldstack));
    var ci = L.base_ci.?;
    const top_bound = @intFromPtr(L.ci);
    while (@intFromPtr(ci) <= top_bound) : (ci += 1) {
        ci[0].top = L.stack + (ci[0].top - oldstack);
        ci[0].base = L.stack + (ci[0].base - oldstack);
        ci[0].func = L.stack + (ci[0].func - oldstack);
    }
    L.base = L.stack + (L.base - oldstack);
}

pub fn Dreallocstack(L: *lua.State, newsize: usize, fornewci: bool) Errorset.Memory!void {
    // throw 'out of memory' error because space for a custom error message cannot be guaranteed here
    if (newsize > MAX_STACK_SIZE) {
        // reallocation was performed to setup a new CallInfo frame, which we have to remove
        if (fornewci) {
            const cip = L.ci.? - 1;

            L.ci = cip;
            L.base = cip[0].base;
            L.top = cip[0].top;
        }

        return error.OutOfMemory;
    }

    const realsize = newsize + lstate.EXTRA_STACK;
    if (L.stacksize == realsize) {
        // fast path: skip reallocation
        return;
    }

    const oldstack = L.stack;
    std.debug.assert(L.stack_last - L.stack == L.stacksize - lstate.EXTRA_STACK);
    L.stack = try lmem.Mreallocarray(L, lobject.TValue, L.stack, @intCast(L.stacksize), realsize, L.header.memcat) orelse unreachable;
    const newstack = L.stack;
    var i: usize = @intCast(L.stacksize);
    while (i < realsize) : (i += 1)
        newstack[i].setnilvalue();
    L.stacksize = @intCast(realsize);
    L.stack_last = newstack + newsize;
    correctstack(L, oldstack);
}

pub fn DreallocCI(L: *lua.State, newsize: usize) Errorset.Memory!void {
    const oldci = L.base_ci;
    L.base_ci = try lmem.Mreallocarray(L, lstate.CallInfo, L.base_ci, @intCast(L.size_ci), newsize, L.header.memcat);
    L.size_ci = @intCast(newsize);
    L.ci = @ptrFromInt((@intFromPtr(L.ci) - @intFromPtr(oldci)) + @intFromPtr(L.base_ci));
    L.end_ci = L.base_ci.? + newsize - 1;
}

pub fn Dgrowstack(L: *lua.State, n: usize) Errorset.Memory!void {
    try Dreallocstack(L, getgrownstacksize(L, n), false);
}

pub inline fn @"resume"(L: *lua.State, from: ?*lua.State, narg: i32) lua.Status {
    return @fromBackingInt(@intCast(c.lua_resume(@ptrCast(L), @ptrCast(from), narg)));
}

pub inline fn resumeerror(L: *lua.State, from: ?*lua.State) lua.Status {
    return @fromBackingInt(@intCast(c.lua_resumeerror(@ptrCast(L), @ptrCast(from))));
}

pub fn yield(L: *lua.State, nresults: u32) !i32 {
    if (L.nCcalls > L.baseCcalls)
        try ldebug.GrunerrorL(L, "attempt to yield across metamethod/C-call boundary", .{});
    L.base = L.top - nresults;
    L.curr_status = @backingInt(lua.Status.Yield);
    return -1;
}

pub fn @"break"(L: *lua.State) !i32 {
    if (L.nCcalls > L.baseCcalls)
        try ldebug.GrunerrorL(L, "attempt to yield across metamethod/C-call boundary", .{});
    L.curr_status = @backingInt(lua.Status.Break);
    return -1;
}

pub fn isyieldable(L: *lua.State) bool {
    return L.nCcalls <= L.baseCcalls;
}
