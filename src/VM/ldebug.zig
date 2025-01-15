const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");
const state = @import("lstate.zig");
const object = @import("lobject.zig");

pub fn currentpc(ci: *state.CallInfo) usize {
    if (ci.savedpc) |pc| {
        return @intFromPtr(pc) - @intFromPtr(ci.ci_func().d.l.p.code) - 1;
    } else return 0;
}

pub fn currentline(ci: *state.CallInfo) i32 {
    std.debug.assert(ci.isLua());
    return Ggetline(ci.ci_func().d.l.p, currentpc(ci));
}

pub fn getluaproto(ci: *state.CallInfo) ?*object.Proto {
    return if (ci.isLua())
        ci.ci_func().d.l.p
    else
        null;
}

pub inline fn getargument(L: *lua.State, level: i32, n: i32) bool {
    return c.lua_getargument(@ptrCast(L), level, n) != 0;
}

pub inline fn getlocal(L: *lua.State, level: i32, n: i32) [:0]const u8 {
    return std.mem.span(c.lua_getlocal(@ptrCast(L), level, n));
}

pub inline fn setlocal(L: *lua.State, level: i32, n: i32) [:0]const u8 {
    return std.mem.span(c.lua_setlocal(@ptrCast(L), level, n));
}

pub inline fn stackdepth(L: *lua.State) usize {
    return L.ci.?.sub(@intFromPtr(L.base_ci.?));
}

pub fn getinfo(L: *lua.State, level: i32, what: [:0]const u8) ?lua.Debug {
    var ar: c.lua_Debug = undefined;
    if (c.lua_getinfo(@ptrCast(L), level, what.ptr, &ar) == 0)
        return null;
    return lua.Debug.fromLua(ar, what);
}

fn pusherror(L: *lua.State, msg: [:0]const u8) void {
    const ci = L.ci.?;
    if (ci.isLua()) {
        const source = getluaproto(ci).?.source;
        // var chunkbuf: [lua.config.IDSIZE]u8 = undefined;
        const line = currentline(ci);
        if (source) |src| {
            L.pushfstring("{s}:{d}: {s}", .{ std.mem.span(src.getstr()), line, msg });
        } else {
            L.pushfstring(":{d}: {s}", .{ line, msg });
        }
    } else {
        L.pushstring(msg);
    }
}

pub fn GrunerrorL(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    L.pushvfstring(fmt, args);
    L.rawcheckstack(1);
    L.raiseerror();
}

pub fn Ggetline(p: *object.Proto, pc: usize) i32 {
    std.debug.assert(pc >= 0 and pc < p.sizecode);

    if (p.lineinfo) |lineinfo| {
        return p.abslineinfo.?[pc >> p.linegaplog2] + lineinfo[pc];
    } else return 0;
}

pub fn Gisnative(L: *lua.State, level: usize) bool {
    if (level >= L.ci.?.sub(L.base_ci.?))
        return false;
    const ci = L.ci.?.sub_num(level);
    return (ci.flags & state.CALLINFO_NATIVE) != 0;
}

pub inline fn singlestep(L: *lua.State, enabled: bool) void {
    L.tsinglestep = enabled;
}

pub inline fn breakpoint(L: *lua.State, funcindex: i32, line: i32, enabled: bool) void {
    c.lua_breakpoint(@ptrCast(L), funcindex, line, enabled);
}

pub fn getcoverage(
    L: *lua.State,
    comptime T: type,
    funcindex: i32,
    context: *T,
    callback: *const fn (
        ctx: *T,
        func: [:0]const u8,
        line: i32,
        depth: i32,
        hits: []const i32,
    ) void,
) void {
    c.lua_getcoverage(@ptrCast(L), funcindex, context, struct {
        fn inner(
            ctx: ?*anyopaque,
            func: [*]const u8,
            line: c_int,
            depth: c_int,
            hits: [*c]const c_int,
            size: usize,
        ) callconv(.C) void {
            @call(.always_inline, callback, .{
                @as(*T, @ptrCast(ctx.?)),
                std.mem.span(func),
                line,
                depth,
                hits[0..size],
            });
        }
    }.inner);
}

pub inline fn debugtrace(L: *lua.State) [:0]const u8 {
    return std.mem.span(c.lua_debugtrace(@ptrCast(L)));
}
