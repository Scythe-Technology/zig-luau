const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");
const lapi = @import("lapi.zig");
const lobject = @import("lobject.zig");

pub const Reg = struct {
    name: [:0]const u8,
    func: ?lua.CFunction,
};

pub fn OptionalValue(comptime T: type, L: *lua.State, check: anytype, narg: i32, d: T) T {
    if (L.isnoneornil(narg))
        return d
    else
        return check(L, narg);
}

fn currfuncname(L: *lua.State) ?[:0]const u8 {
    const cl: ?*lobject.Closure = if (@intFromPtr(L.ci) > @intFromPtr(L.base_ci))
        L.curr_func()
    else
        null;
    const debugname: ?[:0]const u8 = if (cl != null and cl.?.isC != 0)
        std.mem.span(cl.?.d.c.debugname)
    else
        null;

    if (debugname != null and std.mem.eql(u8, debugname.?, "__namecall")) {
        return if (L.namecall) |namecall|
            std.mem.span(namecall.getstr())
        else
            null;
    } else return debugname;
}

pub inline fn LargerrorL(L: *lua.State, narg: i32, extramsg: [:0]const u8) noreturn {
    const fname = currfuncname(L);

    if (fname) |name|
        LerrorL(L, "invalid argument #{d} to '{s}' ({s})", .{ narg, name, extramsg })
    else
        LerrorL(L, "invalid argument #{d} ({s})", .{ narg, extramsg });
}
pub inline fn Largerror(L: *lua.State, narg: i32, extramsg: [:0]const u8) noreturn {
    LargerrorL(L, narg, extramsg);
}
pub inline fn Largcheck(L: *lua.State, cond: bool, narg: i32, extramsg: [:0]const u8) noreturn {
    if (!cond) LargerrorL(L, narg, extramsg);
}

pub inline fn LtypeerrorL(L: *lua.State, narg: i32, tname: [:0]const u8) noreturn {
    c.luaL_typeerror(@as(*c.lua_State, @ptrCast(L)), narg, tname);
}

inline fn tag_error(L: *lua.State, narg: i32, tag: lua.Type) void {
    LtypeerrorL(L, narg, lapi.typename(tag));
}

pub fn Lwhere(L: *lua.State, level: i32) void {
    var info: lua.Debug = undefined;
    if (L.getinfo(level, "sl", &info)) {
        if (info.currentline) |line| {
            L.pushfstring("{s}:{d}: ", .{ info.short_src.?, line });
            return;
        }
    }
    L.pushstring("");
}

pub fn LerrorL(L: *lua.State, comptime fmt: []const u8, args: anytype) noreturn {
    Lwhere(L, 1);
    L.pushvfstring(fmt, args);
    L.concat(2);
    L.raiseerror();
}

pub inline fn Lcheckoption(L: *lua.State, comptime T: type, narg: i32, def: ?T) T {
    const name = blk: {
        if (def) |d|
            break :blk Loptstring(narg, @tagName(d))
        else
            break :blk L.checkstring(narg);
    };

    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, name))
            return @enumFromInt(field.value);
    }

    var buf: [128]u8 = undefined;
    return LargerrorL(L, narg, std.fmt.bufPrintZ(&buf, "invalid option '{s}'", .{name}) catch "");
}

/// Returns true if metatable was created, false if it already exists.
pub inline fn Lnewmetatable(L: *lua.State, tname: [:0]const u8) bool {
    return c.luaL_newmetatable(@ptrCast(L), tname.ptr) != 0;
}

pub inline fn Lgetmetatable(L: *lua.State, tname: [:0]const u8) lua.Type {
    return L.getfield(lua.REGISTRYINDEX, tname);
}

pub inline fn Lcheckudata(L: *lua.State, comptime T: type, ud: i32, tname: [:0]const u8) ?*T {
    return @ptrCast(c.luaL_checkudata(@ptrCast(L), ud, tname).?);
}

pub fn Lcheckbuffer(L: *lua.State, idx: i32) []u8 {
    if (L.tobuffer(idx)) |b|
        return b
    else
        return tag_error(L, idx, .Buffer);
}

pub fn Lcheckstack(L: *lua.State, space: i32, msg: ?[]const u8) void {
    if (!L.checkstack(space))
        if (msg) |m|
            LerrorL(L, "stack overflow ({s})", .{m})
        else
            LerrorL(L, "stack overflow", .{});
}

pub fn Lchecktype(L: *lua.State, narg: i32, t: lua.Type) void {
    if (L.typeOf(narg) != t)
        tag_error(L, narg, t);
}

pub fn Lcheckany(L: *lua.State, narg: i32) void {
    if (L.typeOf(narg) == .None)
        LerrorL(L, "missing argument #{d}", .{narg});
}

pub fn Lchecklstring(L: *lua.State, narg: i32) []const u8 {
    if (L.tolstring(narg)) |s|
        return s
    else
        tag_error(L, narg, .String);
}
pub fn Lcheckstring(L: *lua.State, narg: i32) [:0]const u8 {
    if (L.tolstring(narg)) |s|
        return s
    else
        tag_error(L, narg, .String);
}

pub fn Loptlstring(L: *lua.State, narg: i32, d: []const u8) []const u8 {
    return OptionalValue([]const u8, L, Lchecklstring, narg, d);
}
pub fn Loptstring(L: *lua.State, narg: i32, d: [:0]const u8) [:0]const u8 {
    return OptionalValue([:0]const u8, L, Lcheckstring, narg, d);
}

pub fn Lchecknumber(L: *lua.State, narg: i32) f64 {
    return L.tonumberx(narg) orelse tag_error(L, narg, .Number);
}

pub fn Loptnumber(L: *lua.State, narg: i32, d: f64) f64 {
    return OptionalValue(f64, L, Lchecknumber, narg, d);
}

pub fn Lcheckboolean(L: *lua.State, narg: i32) bool {
    if (!L.isboolean(narg))
        return L.toboolean(narg)
    else
        tag_error(L, narg, .Boolean);
}

pub fn Loptboolean(L: *lua.State, narg: i32, d: bool) bool {
    return OptionalValue(bool, L, Lcheckboolean, narg, d);
}

pub fn Lcheckinteger(L: *lua.State, narg: i32) i32 {
    return L.tointegerx(narg) orelse tag_error(L, narg, .Number);
}

pub fn Loptinteger(L: *lua.State, narg: i32, d: i32) i32 {
    return OptionalValue(i32, L, Lcheckinteger, narg, d);
}

pub fn Lcheckunsigned(L: *lua.State, narg: i32) u32 {
    return L.tounsignedx(narg) orelse tag_error(L, narg, .Number);
}

pub fn Loptunsigned(L: *lua.State, narg: i32, d: u32) u32 {
    return OptionalValue(u32, L, Lcheckunsigned, narg, d);
}

pub fn Lcheckvector(L: *lua.State, narg: i32) []const f32 {
    return L.tovector(narg) orelse tag_error(L, narg, .Vector);
}

pub fn Loptvector(L: *lua.State, narg: i32, d: []const f32) []const f32 {
    return OptionalValue([]const f32, L, Lcheckvector, narg, d);
}

pub fn Lgetmetafield(L: *lua.State, obj: i32, event: [:0]const u8) bool {
    if (!L.getmetatable(obj)) // no metatable?
        return false;
    L.pushstring(event);
    _ = L.rawget(-2);
    if (L.isnil(-1)) {
        L.pop(2); // remove metatable and metafield
        return false;
    }
    L.remove(-2); // remove only metatable
    return true;
}

pub fn Lcallmeta(L: *lua.State, obj: i32, event: [:0]const u8) bool {
    const idx = lapi.absindex(L, obj);
    if (!Lgetmetafield(L, idx, event))
        return false;
    L.pushvalue(idx);
    L.call(1, 1);
    return true;
}

pub fn Lregister(L: *lua.State, libname: ?[:0]const u8, funcs: []const Reg) void {
    if (libname) |name| {
        _ = Lfindtable(L, lua.REGISTRYINDEX, "_LOADED", 1);
        _ = L.getfield(-1, name);
        if (!L.istable(-1)) {
            L.pop(1);
            if (Lfindtable(L, lua.GLOBALSINDEX, name, funcs.len)) |_|
                LerrorL(L, "name conflict for module '{s}'", .{name});
            L.pushvalue(-1);
            L.setfield(-3, name);
        }
        L.remove(-2);
        L.insert(-1);
    }
    for (funcs) |f| {
        if (f.func) |func| {
            L.pushcfunction(func, f.name);
            L.setfield(-2, f.name);
        }
    }
}

pub inline fn Lfindtable(L: *lua.State, idx: i32, fname: [:0]const u8, szhint: usize) ?[]const u8 {
    const p = c.luaL_findtable(@ptrCast(L), idx, fname, @truncate(@as(isize, @intCast(szhint))));
    if (p != null)
        return std.mem.span(p)
    else
        return null;
}

pub inline fn Ltypename(L: *lua.State, idx: i32) [:0]const u8 {
    return std.mem.span(c.luaL_typename(@ptrCast(L), idx));
}

pub inline fn Ltolstring(L: *lua.State, idx: i32) ?[:0]const u8 {
    return std.mem.span(c.luaL_tolstring(@ptrCast(L), idx));
}
