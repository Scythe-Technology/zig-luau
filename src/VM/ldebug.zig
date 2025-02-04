const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");
const ltm = @import("ltm.zig");
const lstate = @import("lstate.zig");
const lobject = @import("lobject.zig");

pub fn currentpc(ci: *lstate.CallInfo) usize {
    if (ci.savedpc) |pc| {
        return @intFromPtr(pc) - @intFromPtr(ci.ci_func().d.l.p.code) - 1;
    } else return 0;
}

pub fn currentline(ci: *lstate.CallInfo) i32 {
    std.debug.assert(ci.isLua());
    return Ggetline(ci.ci_func().d.l.p, currentpc(ci));
}

pub fn getluaproto(ci: *lstate.CallInfo) ?*lobject.Proto {
    return if (ci.isLua())
        ci.ci_func().d.l.p
    else
        null;
}

pub inline fn getargument(L: *lua.State, level: i32, n: i32) bool {
    return c.lua_getargument(@ptrCast(L), level, n) != 0;
}

pub inline fn getlocal(L: *lua.State, level: i32, n: i32) ?[:0]const u8 {
    const name = c.lua_getlocal(@ptrCast(L), level, n);
    if (name != null)
        return std.mem.span(name);
    return null;
}

pub inline fn setlocal(L: *lua.State, level: i32, n: i32) ?[:0]const u8 {
    const name = c.lua_setlocal(@ptrCast(L), level, n);
    if (name != null)
        return std.mem.span(name);
    return null;
}

pub inline fn stackdepth(L: *lua.State) usize {
    return L.ci.?.sub(L.base_ci.?);
}

pub fn getinfo(L: *lua.State, level: i32, what: [:0]const u8, ar: *lua.Debug) bool {
    var info: c.lua_Debug = undefined;
    if (c.lua_getinfo(@ptrCast(L), level, what.ptr, &info) == 0)
        return false;
    ar.fromLua(info, what);
    return true;
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

pub fn Ggetline(p: *lobject.Proto, pc: usize) i32 {
    std.debug.assert(pc >= 0 and pc < p.sizecode);

    if (p.lineinfo) |lineinfo| {
        return p.abslineinfo.?[pc >> @intCast(p.linegaplog2)] + lineinfo[pc];
    } else return 0;
}

pub fn Gisnative(L: *lua.State, level: usize) bool {
    if (level >= L.ci.?.sub(L.base_ci.?))
        return false;
    const ci = L.ci.?.sub_num(level);
    return (ci.flags & lstate.CALLINFO_NATIVE) != 0;
}

pub inline fn singlestep(L: *lua.State, enabled: bool) void {
    L.singlestep_on = enabled;
}

pub inline fn breakpoint(L: *lua.State, funcindex: i32, line: i32, enabled: bool) i32 {
    return c.lua_breakpoint(@ptrCast(L), funcindex, line, if (enabled) 1 else 0);
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
