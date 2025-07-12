const std = @import("std");

const lua = @import("lua.zig");

const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");
const lcommon = @import("lcommon.zig");
const lobject = @import("lobject.zig");

pub inline fn sizeCclosure(n: u8) usize {
    return @offsetOf(lobject.Closure, "d") + @offsetOf(lobject.Closure.ValueUnion.C, "upvals") + (@sizeOf(lobject.TValue) * n);
}
pub inline fn sizeLclosure(n: u8) usize {
    return @offsetOf(lobject.Closure, "d") + @offsetOf(lobject.Closure.ValueUnion.L, "uprefs") + (@sizeOf(lobject.TValue) * n);
}

pub fn Ffreeupval(L: *lua.State, uv: *lobject.UpVal, page: *lmem.lua_Page) void {
    lmem.Mfreegco(L, @ptrCast(@alignCast(uv)), @sizeOf(lobject.UpVal), uv.header.memcat, page); // free upvalue
}

pub fn Fcloseupval(L: *lua.State, uv: *lobject.UpVal, dead: bool) void {
    // unlink value from all lists *before* closing it since value storage overlaps
    std.debug.assert(uv.u.open.next.?.u.open.prev == uv and uv.u.open.prev.?.u.open.next == uv);
    uv.u.open.next.?.u.open.prev = uv.u.open.prev;
    uv.u.open.prev.?.u.open.next = uv.u.open.next;

    if (dead)
        return;

    uv.u.value.setobj(L, uv.v);
    uv.v = &uv.u.value;
    lgc.Cupvalclosed(L, uv);
}

pub fn Ffreeproto(L: *lua.State, f: *lobject.Proto, page: *lmem.lua_Page) void {
    lmem.Mfreearray(L, lcommon.Instruction, f.code, @intCast(f.sizecode), f.header.memcat);
    lmem.Mfreearray(L, ?*lobject.Proto, f.p, @intCast(f.sizep), f.header.memcat);
    lmem.Mfreearray(L, lobject.TValue, f.k, @intCast(f.sizek), f.header.memcat);
    if (f.lineinfo) |li|
        lmem.Mfreearray(L, u8, li, @intCast(f.sizelineinfo), f.header.memcat);
    lmem.Mfreearray(L, lobject.LocVar, f.locvars, @intCast(f.sizelocvars), f.header.memcat);
    lmem.Mfreearray(L, ?*lobject.TString, f.upvalues, @intCast(f.sizeupvalues), f.header.memcat);
    if (f.debuginsn) |di|
        lmem.Mfreearray(L, u8, di, @intCast(f.sizecode), f.header.memcat);

    if (f.execdata) |_|
        L.global.ecb.destroy(L, @ptrCast(f));

    if (f.typeinfo) |ti|
        lmem.Mfreearray(L, u8, ti, @intCast(f.sizetypeinfo), f.header.memcat);

    lmem.Mfreegco(L, @ptrCast(@alignCast(f)), @sizeOf(lobject.Proto), f.header.memcat, page);
}

pub fn Ffreeclosure(L: *lua.State, c: *lobject.Closure, page: *lmem.lua_Page) void {
    const size = if (c.isC > 0) sizeCclosure(c.nupvalues) else sizeLclosure(c.nupvalues);
    lmem.Mfreegco(L, @ptrCast(@alignCast(c)), size, c.header.memcat, page);
}
