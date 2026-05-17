const std = @import("std");
const builtin = @import("builtin");

const lua = @import("lua.zig");

const lobject = @import("lobject.zig");

const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");

const Errorset = @import("errorset.zig");

/// special tag value is used for user data with inline dtors
pub const UTAG_IDTOR = lua.config.UTAG_LIMIT;

/// special tag value is used for newproxy-created user data (all other user data objects are host-exposed)
pub const UTAG_PROXY = (lua.config.UTAG_LIMIT + 1);

/// must be updated if more internal tags are added
pub const UTAG_INTERNAL_LIMIT = UTAG_PROXY + 1;

pub inline fn sizeudata(len: usize) usize {
    return @offsetOf(lobject.Udata, "data") + (if (len > 16) ((len + 15) & ~@as(usize, 15)) else len);
}

pub fn Unewudata(L: *lua.State, s: usize, tag: u8) Errorset.Memory!*lobject.Udata {
    if (s > std.math.maxInt(i32) - @sizeOf(lobject.Udata))
        return error.BlockTooBig;

    const u = try lmem.Mnewgco(L, lobject.Udata, sizeudata(s), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(u)), @intFromEnum(lua.Type.Userdata));
    u.metatable = null;
    u.len = @intCast(s);
    u.tag = tag;
    return u;
}

pub fn Ufreeudata(L: *lua.State, u: *lobject.Udata, page: *lmem.lua_Page) void {
    if (u.tag < lua.config.UTAG_LIMIT) {
        // TODO: access to L here is highly unsafe since this is called during internal GC traversal
        // certain operations such as lua_getthreaddata are okay, but by and large this risks crashes on improper use
        if (L.global.udatagc[u.tag]) |dtor|
            dtor(L, @ptrCast(@alignCast(&u.data)));
    } else if (u.tag == UTAG_IDTOR) {
        const InlineDtor = *const fn (data: ?*anyopaque) callconv(.c) void;
        var dtor: ?InlineDtor = null;
        dtor = @ptrFromInt(std.mem.readVarInt(
            usize,
            (@as([*]u8, @ptrCast(&u.data)) + @as(u32, @intCast(u.len)) - @sizeOf(InlineDtor))[0..@sizeOf(InlineDtor)],
            builtin.cpu.arch.endian(),
        ));
        if (dtor) |d|
            d(@ptrCast(@alignCast(&u.data)));
    }

    lmem.Mfreegco(L, u.obj2gco(), sizeudata(@intCast(u.len)), u.header.memcat, page);
}
