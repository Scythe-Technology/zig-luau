const std = @import("std");

const lua = @import("lua.zig");
const lstate = @import("lstate.zig");
const lobject = @import("lobject.zig");

///
/// Possible states of the Garbage Collector
///
pub const GCSpause = 0;
pub const GCSpropagate = 1;
pub const GCSpropagateagain = 2;
pub const GCSatomic = 3;
pub const GCSsweep = 4;

pub inline fn keepinvariant(g: *const lstate.global_State) bool {
    return g.gcstate == GCSpropagate or g.gcstate == GCSpropagateagain or g.gcstate == GCSatomic;
}

pub inline fn testbits(x: u8, m: u8) u8 {
    return x & m;
}
pub inline fn bitmask(b: u8) u8 {
    return 1 << b;
}
pub inline fn bit2mask(b1: u8, b2: u8) u8 {
    return (1 << b1) | (1 << b2);
}
pub inline fn testbit(x: u8, b: u8) u8 {
    return testbits(x, bitmask(b));
}
pub inline fn test2bits(x: u8, b1: u8, b2: u8) u8 {
    return testbits(x, bit2mask(b1, b2));
}

///
/// Layout for bit use in `marked' field:
/// bit 0 - object is white (type 0)
/// bit 1 - object is white (type 1)
/// bit 2 - object is black
/// bit 3 - object is fixed (should not be collected)
///
pub const WHITE0BIT = 0;
pub const WHITE1BIT = 1;
pub const BLACKBIT = 2;
pub const FIXEDBIT = 3;
pub const WHITEBITS = bit2mask(WHITE0BIT, WHITE1BIT);

pub inline fn iswhite(x: *lstate.GCObject) bool {
    return test2bits(x.gch.marked, WHITE0BIT, WHITE1BIT) != 0;
}
pub inline fn isblack(x: *lstate.GCObject) bool {
    return testbit(x.gch.marked, BLACKBIT) != 0;
}
pub inline fn isgray(x: *lstate.GCObject) bool {
    return testbits(x.gch.marked, WHITEBITS | bitmask(BLACKBIT)) == 0;
}
pub inline fn isfixed(x: *lstate.GCObject) bool {
    return testbit(x.gch.marked, FIXEDBIT) != 0;
}

pub inline fn otherwhite(g: *const lstate.global_State) u8 {
    return g.currentwhite ^ WHITEBITS;
}
pub inline fn isdead(g: *const lstate.global_State, v: *const lstate.GCObject) bool {
    return (v.gch.marked & (WHITEBITS | bitmask(FIXEDBIT))) == (otherwhite(g) & WHITEBITS);
}

pub inline fn changewhite(x: *lstate.GCObject) void {
    x.gch.marked ^= WHITEBITS;
}

pub inline fn black2gray(x: *lstate.GCObject) void {
    std.debug.assert(isblack(x));
    x.gch.marked &= ~(bitmask(BLACKBIT));
}

pub inline fn Cwhite(g: *const lstate.global_State) u8 {
    return g.currentwhite & WHITEBITS;
}

pub inline fn CneedsGC(L: *const lua.State) bool {
    return L.global.totalbytes >= L.global.GCthreshold;
}

// pub inline fn CcheckGC(L: *lua.State) void {
//     if (CneedsGC(L)) {
//         Cstep(L);
//     }
// }

pub inline fn Cthreadbarrier(L: *lua.State) void {
    if (isblack(@ptrCast(L))) {
        Cbarrierback(L, @ptrCast(L), &L.gclist.?);
    }
}

pub fn Cbarrierback(L: *lua.State, o: *lstate.GCObject, gclist: **lstate.GCObject) void {
    const g = L.global;
    std.debug.assert(isblack(o) and !isdead(g, o));
    std.debug.assert(g.gcstate != GCSpause);

    black2gray(o);
    gclist.* = g.grayagain;
    g.grayagain = o;
}

fn validateobjref(g: *const lstate.global_State, f: *lstate.GCObject, t: *lstate.GCObject) void {
    std.debug.assert(!isdead(g, t));
    if (keepinvariant(g)) {
        // basic incremental invariant: black can't point to white
        std.debug.assert(!(isblack(f) and iswhite(t)));
    }
}

fn validateref(g: *const lstate.global_State, f: *lstate.GCObject, v: *lobject.TValue) void {
    if (v.iscollectable()) {
        std.debug.assert(v.ttype() == v.gcvalue().gch.tt);
        validateobjref(g, f, v.gcvalue());
    }
}

fn validatetable(g: *const lstate.global_State, h: *lobject.Table) void {
    const sizenode = 1 << h.lsizenode;

    std.debug.assert(h.bound.lastfree <= sizenode);

    if (h.metatable) |mt|
        validateobjref(g, @ptrCast(h), @ptrCast(mt));

    for (0..h.sizearray) |i|
        validateref(g, @ptrCast(h), &h.array[i]);

    for (0..sizenode) |i| {
        const n = &h.node[i];

        std.debug.assert(n.gkey().ttype() != @intFromEnum(lua.Type.Deadkey) or n.gval().ttisnil());
        std.debug.assert(i + n.gnext() >= 0 and i + n.gnext() < sizenode);

        if (!n.gval().ttisnil()) {
            var k: lobject.TValue = undefined;
            k.tt = n.gkey().ttype();
            k.value = n.gkey().value;

            validateref(g, @ptrCast(h), &k);
            validateref(g, @ptrCast(h), n.gval());
        }
    }
}

fn validateclosure(g: *const lstate.global_State, cl: *lobject.Closure) void {
    validateobjref(g, @ptrCast(cl), @ptrCast(cl.env));

    if (cl.isC) {
        for (0..cl.nupvalues) |i|
            validateobjref(g, @ptrCast(cl), @ptrCast(@as([*]lobject.TValue, @ptrCast(cl.d.c.upvals))[i]));
    } else {
        std.debug.assert(cl.nupvalues == cl.d.l.p.nups);

        validateobjref(g, @ptrCast(cl), @ptrCast(cl.d.l.p));

        for (0..cl.nupvalues) |i|
            validateobjref(g, @ptrCast(cl), @ptrCast(@as([*]lobject.TValue, @ptrCast(cl.d.l.uprefs))[i]));
    }
}

fn validatestack(g: *const lstate.global_State, l: *lua.State) void {
    validateobjref(g, @ptrCast(l), @ptrCast(l.gt.?));

    for (0..@intFromPtr(l.ci) - @intFromPtr(l.base_ci)) |i| {
        const ci = l.base_ci.?.add(i);
        std.debug.assert(@intFromPtr(l.stack.?) <= @intFromPtr(ci.base));
        std.debug.assert(@intFromPtr(ci.func) <= @intFromPtr(ci.base) and @intFromPtr(ci.base) <= @intFromPtr(ci.top));
        std.debug.assert(@intFromPtr(ci.top) <= @intFromPtr(l.stack_last));
    }

    // note: stack refs can violate gc invariant so we only check for liveness
    for (0..@intFromPtr(l.top) - @intFromPtr(l.stack)) |i|
        l.stack.?.add(i).checkliveness(g);

    if (l.namecall) |nc|
        validateobjref(g, @ptrCast(l), @ptrCast(nc));

    var upval: ?*lobject.UpVal = l.openupval;
    while (upval) |uv| : (upval = uv.u.open.threadnext) {
        std.debug.assert(uv.tt == @intFromEnum(lua.Type.UpVal));
        std.debug.assert(uv.upisopen());
        std.debug.assert(uv.u.open.next.?.u.open.prev == uv and uv.u.open.prev.?.u.open.next == uv);
        std.debug.assert(!isblack(@ptrCast(uv)));
    }
}

fn validateproto(g: *const lstate.global_State, f: *lobject.Proto) void {
    if (f.source) |src|
        validateobjref(g, @ptrCast(f), @ptrCast(src));

    if (f.debugname) |name|
        validateobjref(g, @ptrCast(f), @ptrCast(name));

    for (0..f.sizek) |i|
        validateref(g, @ptrCast(f), @ptrCast(&f.k[i]));

    for (0..f.sizeupvalues) |i|
        if (f.upvalues[i]) |uv|
            validateobjref(g, @ptrCast(f), @ptrCast(uv));

    for (0..f.sizep) |i|
        if (f.p[i]) |proto|
            validateobjref(g, @ptrCast(f), @ptrCast(proto));

    for (0..f.sizelocvars) |i|
        if (f.locvars[i].varname) |varname|
            validateobjref(g, @ptrCast(f), @ptrCast(varname));
}

fn validateobj(g: *const lstate.global_State, o: *lstate.GCObject) void {
    if (isdead(g, o)) {
        std.debug.assert(g.gcstate == GCSsweep);
        return;
    }

    switch (o.gch.tt) {
        @intFromEnum(lua.Type.String), @intFromEnum(lua.Type.Buffer) => {},
        @intFromEnum(lua.Type.Table) => validatetable(g, o.toh()),
        @intFromEnum(lua.Type.Function) => validateclosure(g, o.tocl()),
        @intFromEnum(lua.Type.Userdata) => {
            if (o.tou().metatable) |mt| {
                validateobjref(g, o, @ptrCast(mt));
            }
        },
        @intFromEnum(lua.Type.Thread) => validatestack(g, o.toth()),
        @intFromEnum(lua.Type.Proto) => validateproto(g, o.top()),
        @intFromEnum(lua.Type.UpVal) => validateref(g, o, o.touv().v),
        else => unreachable,
    }
}

fn validategraylist(g: *const lstate.global_State, obj: *lstate.GCObject) void {
    if (!keepinvariant(g))
        return;

    var so: ?*lstate.GCObject = obj;
    while (so) |o| {
        std.debug.assert(isgray(o));
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
    const L: *lua.State = @ptrCast(context.?);
    const g = L.global;

    validateobj(g, gco);
    return false;
}

pub fn Cvalidate(L: *lua.State) void {
    const g = L.global;

    std.debug.assert(!isdead(g, @ptrCast(g.mainthread)));
    g.registry.checkliveness(g);

    for (0..lua.Type.T_COUNT) |i|
        if (g.mt[i]) |mt|
            std.debug.assert(!isdead(g, @ptrCast(mt)));

    validategraylist(g, g.weak);
    validategraylist(g, g.gray);
    validategraylist(g, g.grayagain);

    validategco(@ptrCast(L), null, @ptrCast(g.mainthread));

    // TODO: implement luaM_visitgco
    // luaM_visitgco(L, L, validategco);

    var upval: ?*lobject.UpVal = g.uvhead.u.open.next.?;
    while (upval != &g.uvhead) : (upval = upval.?.u.open.next) {
        std.debug.assert(upval.?.tt == @intFromEnum(lua.Type.UpVal));
        std.debug.assert(upval.?.upisopen());
        std.debug.assert(upval.?.u.open.next.?.u.open.prev == upval and upval.?.u.open.prev.?.u.open.next == upval);
        std.debug.assert(!isblack(@ptrCast(upval.?)));
    }
}
