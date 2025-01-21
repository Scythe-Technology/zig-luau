const std = @import("std");

const lgc = @import("lgc.zig");
const lua = @import("lua.zig");
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
        std.debug.assert(v.ttype() == v.gcvalue().gch.tt);
        validateobjref(g, f, v.gcvalue());
    }
}

fn validatetable(g: *const lstate.global_State, h: *lobject.LuaTable) void {
    const sizenode = @as(u32, 1) << @intCast(h.lsizenode);

    std.debug.assert(h.bound.lastfree <= sizenode);

    if (h.metatable) |mt|
        validateobjref(g, @ptrCast(@alignCast(h)), @ptrCast(@alignCast(mt)));

    for (0..@intCast(h.sizearray)) |i|
        validateref(g, @ptrCast(@alignCast(h)), &h.array[i]);

    for (0..sizenode) |i| {
        const n = &h.node[i];

        std.debug.assert(n.gkey().ttype() != @intFromEnum(lua.Type.Deadkey) or n.gval().ttisnil());
        std.debug.assert(i + @as(usize, @intCast(n.gnext())) >= 0 and i + @as(usize, @intCast(n.gnext())) < sizenode);

        if (!n.gval().ttisnil()) {
            var k: lobject.TValue = undefined;
            k.tt = n.gkey().ttype();
            k.value = n.gkey().value;

            validateref(g, @ptrCast(@alignCast(h)), &k);
            validateref(g, @ptrCast(@alignCast(h)), n.gval());
        }
    }
}

fn validateclosure(g: *const lstate.global_State, cl: *lobject.Closure) void {
    validateobjref(g, @ptrCast(cl), @ptrCast(@alignCast(cl.env)));

    if (cl.isC != 0) {
        for (0..cl.nupvalues) |i|
            validateobjref(g, @ptrCast(cl), @ptrCast(&@as([*]lobject.TValue, @ptrCast(&cl.d.c.upvals))[i]));
    } else {
        std.debug.assert(cl.nupvalues == cl.d.l.p.nups);

        validateobjref(g, @ptrCast(cl), @ptrCast(@alignCast(cl.d.l.p)));

        for (0..cl.nupvalues) |i|
            validateobjref(g, @ptrCast(cl), @ptrCast(&@as([*]lobject.TValue, @ptrCast(&cl.d.l.uprefs))[i]));
    }
}

fn validatestack(g: *const lstate.global_State, l: *lua.State) void {
    validateobjref(g, @ptrCast(@alignCast(l)), @ptrCast(@alignCast(l.gt.?)));

    for (0..@intFromPtr(l.ci) - @intFromPtr(l.base_ci)) |i| {
        const ci = l.base_ci.?.add_num(i);
        std.debug.assert(@intFromPtr(l.stack.?) <= @intFromPtr(ci.base));
        std.debug.assert(@intFromPtr(ci.func) <= @intFromPtr(ci.base) and @intFromPtr(ci.base) <= @intFromPtr(ci.top));
        std.debug.assert(@intFromPtr(ci.top) <= @intFromPtr(l.stack_last));
    }

    // note: stack refs can violate gc invariant so we only check for liveness
    for (0..@intFromPtr(l.top) - @intFromPtr(l.stack)) |i|
        l.stack.?.add_num(i).checkliveness(g);

    if (l.namecall) |nc|
        validateobjref(g, @ptrCast(@alignCast(l)), @ptrCast(@alignCast(nc)));

    var upval: ?*lobject.UpVal = l.openupval;
    while (upval) |uv| : (upval = uv.u.open.threadnext) {
        std.debug.assert(uv.tt == @intFromEnum(lua.Type.UpVal));
        std.debug.assert(uv.upisopen());
        std.debug.assert(uv.u.open.next.?.u.open.prev == uv and uv.u.open.prev.?.u.open.next == uv);
        std.debug.assert(!lgc.isblack(@ptrCast(uv)));
    }
}

fn validateproto(g: *const lstate.global_State, f: *lobject.Proto) void {
    if (f.source) |src|
        validateobjref(g, @ptrCast(@alignCast(f)), @ptrCast(@alignCast(src)));

    if (f.debugname) |name|
        validateobjref(g, @ptrCast(@alignCast(f)), @ptrCast(@alignCast(name)));

    for (0..@intCast(f.sizek)) |i|
        validateref(g, @ptrCast(@alignCast(f)), @ptrCast(@alignCast(&f.k[i])));

    for (0..@intCast(f.sizeupvalues)) |i|
        if (f.upvalues[i]) |uv|
            validateobjref(g, @ptrCast(@alignCast(f)), @ptrCast(@alignCast(uv)));

    for (0..@intCast(f.sizep)) |i|
        if (f.p[i]) |proto|
            validateobjref(g, @ptrCast(@alignCast(f)), @ptrCast(@alignCast(proto)));

    for (0..@intCast(f.sizelocvars)) |i|
        if (f.locvars[i].varname) |varname|
            validateobjref(g, @ptrCast(@alignCast(f)), @ptrCast(@alignCast(varname)));
}

fn validateobj(g: *const lstate.global_State, o: *lstate.GCObject) void {
    if (lgc.isdead(g, o)) {
        std.debug.assert(g.gcstate == lgc.GCSsweep);
        return;
    }

    switch (o.gch.tt) {
        @intFromEnum(lua.Type.String), @intFromEnum(lua.Type.Buffer) => {},
        @intFromEnum(lua.Type.Table) => validatetable(g, o.toh()),
        @intFromEnum(lua.Type.Function) => validateclosure(g, o.tocl()),
        @intFromEnum(lua.Type.Userdata) => {
            if (o.tou().metatable) |mt| {
                validateobjref(g, o, @ptrCast(@alignCast(mt)));
            }
        },
        @intFromEnum(lua.Type.Thread) => validatestack(g, o.toth()),
        @intFromEnum(lua.Type.Proto) => validateproto(g, o.top()),
        @intFromEnum(lua.Type.UpVal) => validateref(g, o, o.touv().v),
        else => unreachable,
    }
}

fn validategraylist(g: *const lstate.global_State, obj: *lstate.GCObject) void {
    if (!lgc.keepinvariant(g))
        return;

    var so: ?*lstate.GCObject = obj;
    while (so) |o| {
        std.debug.assert(lgc.isgray(o));
        switch (o.gch.tt) {
            @intFromEnum(lua.Type.Table) => so = o.toh().gclist,
            @intFromEnum(lua.Type.Function) => so = o.tocl().gclist,
            @intFromEnum(lua.Type.Thread) => so = o.toth().gclist,
            @intFromEnum(lua.Type.Proto) => so = o.toth().gclist,
            else => unreachable,
        }
    }
}

fn validategco(context: ?*anyopaque, _: ?*anyopaque, gco: *lstate.GCObject) bool {
    const L: *lua.State = @ptrCast(@alignCast(context.?));
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
            std.debug.assert(!lgc.isdead(g, @ptrCast(@alignCast(mt))));

    validategraylist(g, g.weak);
    validategraylist(g, g.gray);
    validategraylist(g, g.grayagain);

    _ = validategco(@ptrCast(L), null, @ptrCast(@alignCast(g.mainthread)));

    // TODO: implement luaM_visitgco
    // luaM_visitgco(L, L, validategco);

    var upval: ?*lobject.UpVal = g.uvhead.u.open.next.?;
    while (upval != &g.uvhead) : (upval = upval.?.u.open.next) {
        std.debug.assert(upval.?.tt == @intFromEnum(lua.Type.UpVal));
        std.debug.assert(upval.?.upisopen());
        std.debug.assert(upval.?.u.open.next.?.u.open.prev == upval and upval.?.u.open.prev.?.u.open.next == upval);
        std.debug.assert(!lgc.isblack(@ptrCast(upval.?)));
    }
}
