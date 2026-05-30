const std = @import("std");

const lua = @import("lua.zig");

const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");
const lstate = @import("lstate.zig");
const lcommon = @import("lcommon.zig");
const lobject = @import("lobject.zig");

pub inline fn sizeCclosure(n: u8) usize {
    return @offsetOf(lobject.Closure, "d") + @offsetOf(lobject.Closure.ValueUnion.C, "upvals") + (@sizeOf(lobject.TValue) * @as(usize, @intCast(n)));
}
pub inline fn sizeLclosure(n: u8) usize {
    return @offsetOf(lobject.Closure, "d") + @offsetOf(lobject.Closure.ValueUnion.L, "uprefs") + (@sizeOf(lobject.TValue) * @as(usize, @intCast(n)));
}

pub fn Fnewproto(L: *lua.State) !*lobject.Proto {
    const f = try lmem.Mnewgco(L, lobject.Proto, @sizeOf(lobject.Proto), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(f)), @intFromEnum(lua.Type.Proto));

    f.nups = 0;
    f.numparams = 0;
    f.is_vararg = 0;
    f.maxstacksize = 0;
    f.flags = 0;

    f.k = null;
    f.code = null;
    f.p = null;
    f.codeentry = null;

    f.execdata = null;
    f.exectarget = 0;

    f.lineinfo = null;
    f.abslineinfo = null;
    f.locvars = null;
    f.upvalues = null;
    f.source = null;

    f.debugname = null;
    f.debuginsn = null;

    f.typeinfo = null;

    f.userdata = null;

    f.gclist = null;

    f.sizecode = 0;
    f.sizep = 0;
    f.sizelocvars = 0;
    f.sizeupvalues = 0;
    f.sizek = 0;
    f.sizelineinfo = 0;
    f.linegaplog2 = 0;
    f.linedefined = 0;
    f.bytecodeid = 0;
    f.sizetypeinfo = 0;

    f.feedbackvec = null;
    f.feedbackvecsize = 0;
    f.funid = 0;

    return f;
}

pub fn FnewLclosure(L: *lua.State, nelems: u8, e: *lobject.LuaTable, p: *lobject.Proto) !*lobject.Closure {
    const c = try lmem.Mnewgco(L, lobject.Closure, sizeCclosure(nelems), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(c)), @intFromEnum(lua.Type.Function));
    c.isC = 0;
    c.env = e;
    c.nupvalues = nelems;
    c.stacksize = p.maxstacksize;
    c.preload = 0;
    c.usage = 0;
    c.d.l.p = p;
    for (0..nelems) |i|
        c.d.l.upreferences()[i].setnilvalue();
    return c;
}

pub fn FnewCclosure(L: *lua.State, nelems: u8, e: *lobject.LuaTable) !*lobject.Closure {
    const c = try lmem.Mnewgco(L, lobject.Closure, sizeCclosure(nelems), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(c)), @intFromEnum(lua.Type.Function));
    c.isC = 1;
    c.env = e;
    c.nupvalues = nelems;
    c.stacksize = lua.config.MINSTACK;
    c.preload = 0;
    c.usage = 0;
    c.d.c.f = null;
    c.d.c.cont = null;
    c.d.c.debugname = null;
    return c;
}

pub fn Ffreeupval(L: *lua.State, uv: *lobject.UpVal, page: *lmem.lua_Page) void {
    lmem.Mfreegco(L, uv.obj2gco(), @sizeOf(lobject.UpVal), uv.header.memcat, page); // free upvalue
}

pub fn Fclose(L: *lua.State, level: *lobject.TValue) void {
    const g = L.global;
    var uv: ?*lobject.UpVal = L.openupval;
    const lvl_num = @intFromPtr(level);
    while (uv != null and @intFromPtr(uv.?.v) >= lvl_num) : (uv = L.openupval) {
        const u = uv.?;
        const o: *lstate.GCObject = u.obj2gco();
        std.debug.assert(!lgc.isblack(o) and u.upisopen());
        std.debug.assert(!lgc.isdead(g, o));

        // unlink value *before* closing it since value storage overlaps
        L.openupval = u.u.open.threadnext;

        Fcloseupval(L, u, false);
    }
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
        L.global.ecb.destroy.?(L, @ptrCast(f));

    if (f.typeinfo) |ti|
        lmem.Mfreearray(L, u8, ti, @intCast(f.sizetypeinfo), f.header.memcat);

    if (f.feedbackvec) |fv|
        lmem.Mfreearray(L, lobject.FeedbackVectorSlot, fv, f.feedbackvecsize, f.header.memcat);

    lmem.Mfreegco(L, f.obj2gco(), @sizeOf(lobject.Proto), f.header.memcat, page);
}

pub fn Ffreeclosure(L: *lua.State, c: *lobject.Closure, page: *lmem.lua_Page) void {
    const size = if (c.isC != 0) sizeCclosure(c.nupvalues) else sizeLclosure(c.nupvalues);
    lmem.Mfreegco(L, c.obj2gco(), size, c.header.memcat, page);
}
