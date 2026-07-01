const std = @import("std");

const lgc = @import("lgc.zig");
const lua = @import("lua.zig");
const lmem = @import("lmem.zig");
const lstate = @import("lstate.zig");
const lobject = @import("lobject.zig");

fn validateobjref(g: *const lstate.global_State, f: *lstate.GCObject, t: *lstate.GCObject) void {
    std.debug.assert(!lgc.isdead(g, t));
    if (lgc.keepinvariant(g)) {
        // basic incremental invariant: black can't point to white
        std.debug.assert(!(lgc.isblack(f) and lgc.iswhite(t)));
    }
}

fn validateref(g: *const lstate.global_State, f: *lstate.GCObject, v: *lobject.TValue) void {
    if (v.iscollectable()) {
        std.debug.assert(v.ttype() == v.gcvalue().gch.header.tt);
        validateobjref(g, f, v.gcvalue());
    }
}

fn validatetable(g: *const lstate.global_State, h: *lobject.LuaTable) void {
    const sizenode = @as(u32, 1) << @intCast(h.lsizenode);

    std.debug.assert(h.bound.lastfree <= sizenode);

    if (h.metatable) |mt|
        validateobjref(g, h.obj2gco(), mt.obj2gco());

    for (0..@intCast(h.sizearray)) |i|
        validateref(g, h.obj2gco(), &h.array.?[i]);

    for (0..sizenode) |i| {
        const n = &h.node[i];

        std.debug.assert(n.gkey().ttype() != @intFromEnum(lua.Type.Deadkey) or n.gval().ttisnil());
        std.debug.assert(@as(isize, @intCast(i)) + n.gnext() >= 0 and @as(isize, @intCast(i)) + n.gnext() < sizenode);

        if (!n.gval().ttisnil()) {
            var k: lobject.TValue = undefined;
            k.tt = n.gkey().ttype();
            k.value = n.gkey().value;

            validateref(g, h.obj2gco(), &k);
            validateref(g, h.obj2gco(), n.gval());
        }
    }
}

fn validateclosure(g: *const lstate.global_State, cl: *lobject.Closure) void {
    validateobjref(g, cl.obj2gco(), cl.env.obj2gco());

    if (cl.isC != 0) {
        for (cl.d.c.upvalues()[0..cl.nupvalues]) |*upval|
            validateref(g, cl.obj2gco(), upval);
    } else {
        std.debug.assert(cl.nupvalues == cl.d.l.p.nups);

        validateobjref(g, cl.obj2gco(), cl.d.l.p.obj2gco());

        for (cl.d.l.upreferences()[0..cl.nupvalues]) |*upref|
            validateref(g, cl.obj2gco(), upref);
    }
}

fn validatestack(g: *const lstate.global_State, l: *lua.State) void {
    validateobjref(g, @ptrCast(@alignCast(l)), l.gt.?.obj2gco());

    for (l.base_ci.?[0 .. (l.ci.? - l.base_ci.?) + 1]) |*ci| {
        std.debug.assert(@intFromPtr(l.stack) <= @intFromPtr(ci.base));
        std.debug.assert(@intFromPtr(ci.func) <= @intFromPtr(ci.base) and @intFromPtr(ci.base) <= @intFromPtr(ci.top));
        std.debug.assert(@intFromPtr(ci.top) <= @intFromPtr(l.stack_last));
    }

    // note: stack refs can violate gc invariant so we only check for liveness
    for (l.stack[0..(l.top - l.stack)]) |*o|
        o.checkliveness(g);

    if (l.namecall) |nc|
        validateobjref(g, @ptrCast(@alignCast(l)), nc.obj2gco());

    var upval: ?*lobject.UpVal = l.openupval;
    while (upval) |uv| : (upval = uv.u.open.threadnext) {
        std.debug.assert(uv.header.tt == @intFromEnum(lua.Type.UpVal));
        std.debug.assert(uv.upisopen());
        std.debug.assert(uv.u.open.next.?.u.open.prev == uv and uv.u.open.prev.?.u.open.next == uv);
        std.debug.assert(!lgc.isblack(uv.obj2gco()));
    }
}

fn validateproto(g: *const lstate.global_State, f: *lobject.Proto) void {
    if (f.source) |src|
        validateobjref(g, f.obj2gco(), src.obj2gco());

    if (f.debugname) |name|
        validateobjref(g, f.obj2gco(), name.obj2gco());

    for (0..@intCast(f.sizek)) |i|
        validateref(g, f.obj2gco(), &f.k.?[i]);

    for (0..@intCast(f.sizeupvalues)) |i|
        if (f.upvalues.?[i]) |uv|
            validateobjref(g, f.obj2gco(), uv.obj2gco());

    for (0..@intCast(f.sizep)) |i|
        if (f.p.?[i]) |proto|
            validateobjref(g, f.obj2gco(), proto.obj2gco());

    for (0..@intCast(f.sizelocvars)) |i|
        if (f.locvars.?[i].varname) |varname|
            validateobjref(g, f.obj2gco(), varname.obj2gco());
}

fn validateclass(g: *const lstate.global_State, lco: *lobject.LuauClass) void {
    const obj = lco.obj2gco();
    validateobjref(g, obj, lco.name.obj2gco());
    validateobjref(g, obj, lco.memberstooffset.obj2gco());
    for (0..@intCast(lco.numberofallmembers)) |i| {
        validateobjref(g, obj, lco.offsettomember[i].obj2gco());
        if (i >= lco.numberofinstancemembers)
            validateref(g, obj, &lco.staticmembers[i - @as(u32, @intCast(lco.numberofinstancemembers))]);
    }
    validateobjref(g, obj, lco.metatable.obj2gco());
    if (lco.instancemetatable) |mt|
        validateobjref(g, obj, mt.obj2gco());
}

fn validateclassinstance(g: *const lstate.global_State, inst: *lobject.LuauObject) void {
    const obj = inst.obj2gco();
    validateobjref(g, obj, inst.lclass.obj2gco());
    for (0..@intCast(inst.numberofmembers)) |i|
        validateref(g, obj, &inst.members[i]);
}

fn validateobj(g: *const lstate.global_State, o: *lstate.GCObject) void {
    if (lgc.isdead(g, o)) {
        std.debug.assert(g.gcstate == lgc.GCSsweep);
        return;
    }

    switch (o.gch.header.tt) {
        @intFromEnum(lua.Type.String), @intFromEnum(lua.Type.Buffer) => {},
        @intFromEnum(lua.Type.Table) => validatetable(g, o.toh()),
        @intFromEnum(lua.Type.Function) => validateclosure(g, o.tocl()),
        @intFromEnum(lua.Type.Userdata) => if (o.tou().metatable) |mt|
            validateobjref(g, o, mt.obj2gco()),
        @intFromEnum(lua.Type.Thread) => validatestack(g, o.toth()),
        @intFromEnum(lua.Type.Proto) => validateproto(g, o.top()),
        @intFromEnum(lua.Type.UpVal) => validateref(g, o, o.touv().v),
        @intFromEnum(lua.Type.Class) => validateclass(g, o.toclass()),
        @intFromEnum(lua.Type.Object) => validateclassinstance(g, o.toobject()),
        else => unreachable,
    }
}

fn validategraylist(g: *const lstate.global_State, obj: ?*lstate.GCObject) void {
    if (!lgc.keepinvariant(g))
        return;

    var so: ?*lstate.GCObject = obj;
    while (so) |o| {
        std.debug.assert(lgc.isgray(o));
        switch (o.gch.header.tt) {
            @intFromEnum(lua.Type.Table) => so = o.toh().gclist,
            @intFromEnum(lua.Type.Function) => so = o.tocl().gclist,
            @intFromEnum(lua.Type.Thread) => so = o.toth().gclist,
            @intFromEnum(lua.Type.Class) => so = o.toclass().gclist,
            @intFromEnum(lua.Type.Object) => so = o.toobject().gclist,
            @intFromEnum(lua.Type.Proto) => so = o.top().gclist,
            else => unreachable,
        }
    }
}

fn validategco(L: *lua.State, _: ?*lmem.lua_Page, gco: *lstate.GCObject) bool {
    const g = L.global;

    validateobj(g, gco);
    return false;
}

pub fn Cvalidate(L: *lua.State) void {
    const g = L.global;

    std.debug.assert(!lgc.isdead(g, @ptrCast(@alignCast(g.mainthread))));
    g.registry.checkliveness(g);

    for (0..lua.Type.T_COUNT) |i|
        if (g.mt[i]) |mt|
            std.debug.assert(!lgc.isdead(g, mt.obj2gco()));

    for (0..lua.config.UTAG_LIMIT) |i|
        if (g.udatamt[i]) |mt|
            std.debug.assert(!lgc.isdead(g, mt.obj2gco()));

    validategraylist(g, g.weak);
    validategraylist(g, g.gray);
    validategraylist(g, g.grayagain);

    _ = validategco(@ptrCast(L), null, @ptrCast(@alignCast(g.mainthread)));

    lmem.Mvisitgco(L, *lua.State, L, validategco);

    var upval: ?*lobject.UpVal = g.uvhead.u.open.next.?;
    while (upval != &g.uvhead) : (upval = upval.?.u.open.next) {
        std.debug.assert(upval.?.header.tt == @intFromEnum(lua.Type.UpVal));
        std.debug.assert(upval.?.upisopen());
        std.debug.assert(upval.?.u.open.next.?.u.open.prev == upval and upval.?.u.open.prev.?.u.open.next == upval);
        std.debug.assert(!lgc.isblack(upval.?.obj2gco()));
    }
}
