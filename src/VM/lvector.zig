const std = @import("std");

const lua = @import("lua.zig");

const lobject = @import("lobject.zig");

const lgc = @import("lgc.zig");
const ltm = @import("ltm.zig");
const lmem = @import("lmem.zig");
const lstate = @import("lstate.zig");
const ltable = @import("ltable.zig");
const lstring = @import("lstring.zig");
const lfunc = @import("lfunc.zig");

const Errorset = @import("errorset.zig");

pub fn sizevector() usize {
    return @sizeOf(lobject.Vector);
}

pub fn Vecnewvector(L: *lua.State, x: lua.config.VECTOR_TYPE, y: lua.config.VECTOR_TYPE, z: lua.config.VECTOR_TYPE, w: ?lua.config.VECTOR_TYPE) !*lstate.GCObject {
    const v = try lmem.Mnewgcofixed_(L, lobject.Vector, sizevector(), L.activememcat);
    lgc.Cinit(L, v, @intFromEnum(lua.Type.Vector));
    v.v[0] = @as(f32, x);
    v.v[1] = @as(f32, y);
    v.v[2] = @as(f32, z);
    if (w) |w_val| {
        v.v[3] = @as(f32, w_val);
    }
    return v;
}

pub fn Vecfreevector(L: *lua.State, v: *lobject.Vector, page: *lmem.lua_Page) void {
    lmem.Mfreegcofixed_(L, @ptrCast(@alignCast(v)), sizevector(), v.header.memcat, page);
}
