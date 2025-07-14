const std = @import("std");

const lua = @import("lua.zig");

const lobject = @import("lobject.zig");

const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");

const Errorset = @import("errorset.zig");

// buffer size limit
pub const MAX_BUFFER_SIZE = 1 << 30;

// GCObject size has to be at least 16 bytes, so a minimum of 8 bytes is always reserved
pub inline fn sizebuffer(len: usize) usize {
    return @offsetOf(lobject.Buffer, "data") + (if (len < 8) 8 else len);
}

pub fn Bnewbuffer(L: *lua.State, s: usize) Errorset.Memory!*lobject.Buffer {
    if (s > MAX_BUFFER_SIZE)
        return error.BlockTooBig;

    const b = try lmem.Mnewgco(L, lobject.Buffer, sizebuffer(s), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(b)), @intFromEnum(lua.Type.Buffer));
    b.len = @intCast(s);
    @memset(@as([*]u8, @ptrCast(@alignCast(&b.data)))[0..s], 0);
    return b;
}

pub fn Bfreebuffer(L: *lua.State, b: *lobject.Buffer, page: *lmem.lua_Page) void {
    lmem.Mfreegco(L, @ptrCast(@alignCast(b)), sizebuffer(b.len), b.header.memcat, page);
}
