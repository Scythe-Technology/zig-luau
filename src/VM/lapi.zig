const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");

const lstring = @import("lstring.zig");
const lgc = @import("lgc.zig");
const ltm = @import("ltm.zig");
const ldo = @import("ldo.zig");
const lvm = @import("lvm.zig");
const ltable = @import("ltable.zig");
const ludata = @import("ludata.zig");
const lbuffer = @import("lbuffer.zig");
const lobject = @import("lobject.zig");
const lvmutils = @import("lvmutils.zig");

const State = lua.State;

pub fn api_check(L: *State, cond: bool) void {
    _ = L;
    std.debug.assert(cond);
}

pub inline fn api_checknelems(L: *State, n: u32) void {
    api_check(L, n <= L.top.sub(L.base));
}

pub inline fn api_checkvalidindex(L: *State, obj: *const lobject.TValue) void {
    api_check(L, obj != lobject.Onilobject);
}

pub inline fn api_incr_top(L: *State) void {
    api_check(L, @intFromPtr(L.top) <= @intFromPtr(L.stack_last));
    L.top = L.top.add_num(1);
}

pub inline fn updateatom(L: *State, ts: *lobject.TString) void {
    if (ts.atom == lstring.ATOM_UNDEF)
        ts.atom = if (L.global.cb.useratom) |useratom| useratom(@ptrCast(@alignCast(&ts.data)), @intCast(ts.len)) else -1;
}

pub fn getcurrenv(L: *lua.State) *lobject.LuaTable {
    if (L.ci == L.base_ci) // no enclosing function?
        return L.gt.? // use global table as environment
    else
        return L.curr_func().env;
}

pub noinline fn pseudo2addr(L: *State, idx: i32) lobject.StkId {
    api_check(L, lua.ispseudo(idx));
    switch (idx) {
        lua.REGISTRYINDEX => return L.registry(),
        lua.ENVIRONINDEX => {
            const pt = &L.global.pseudotemp;
            pt.sethvalue(L, getcurrenv(L));
            return &L.global.pseudotemp;
        },
        lua.GLOBALSINDEX => {
            const pt = &L.global.pseudotemp;
            pt.sethvalue(L, L.gt.?);
            return &L.global.pseudotemp;
        },
        else => {
            const func = L.curr_func();
            const i = lua.GLOBALSINDEX - idx;
            return if (i <= @as(i32, @intCast(func.nupvalues)))
                &@as([*]lobject.TValue, &func.d.c.upvals)[@intCast(i - 1)]
            else
                @constCast(lobject.Onilobject);
        },
    }
}

pub inline fn index2addr(L: *State, idx: i32) lobject.StkId {
    if (idx > 0) {
        const o: usize = @intFromPtr(L.base.add_num(idx - 1));
        api_check(L, idx <= L.ci.?.top.sub(L.base));
        if (o >= @intFromPtr(L.top))
            return @constCast(lobject.Onilobject)
        else
            return @ptrFromInt(o);
    } else if (idx > lua.REGISTRYINDEX) {
        api_check(L, idx != 0 and -idx <= L.top.sub(L.base));
        return L.top.add_num(idx);
    } else {
        return pseudo2addr(L, idx);
    }
}

pub fn Atoobject(L: *lua.State, idx: i32) ?*const lobject.TValue {
    const p = index2addr(L, idx);
    return if (p == lobject.Onilobject) null else p;
}

pub fn Apushobject(L: *lua.State, o: *const lobject.TValue) void {
    L.top.setobj(L, o);
    api_incr_top(L);
}

pub fn checkstack(L: *lua.State, size: usize) !bool {
    if (size > lua.config.I_MAXCSTACK or (L.top.sub(L.base) + size) > lua.config.I_MAXCSTACK)
        return false
    else {
        try @call(.always_inline, rawcheckstack, .{ L, size });
        return true;
    }
}
pub fn rawcheckstack(L: *lua.State, size: usize) !void {
    try ldo.Dcheckstack(L, size);
    ldo.expandstacklimit(L, L.top.add_num(size));
}

pub fn xmove(from: *lua.State, to: *lua.State, n: u32) void {
    if (from == to)
        return;
    api_checknelems(from, n);
    api_check(from, from.global == to.global);
    api_check(from, to.ci.?.top.sub(to.top) >= n);
    lgc.Cthreadbarrier(to);

    const ttop = to.top;
    const ftop = from.top.sub_num(n);
    for (0..@intCast(n)) |i|
        ttop.add_num(i).setobj(to, ftop.add_num(i));

    from.top = ftop;
    to.top = ttop.add_num(n);
}

pub fn xpush(from: *lua.State, to: *lua.State, idx: i32) void {
    api_check(from, from.global == to.global);
    lgc.Cthreadbarrier(to);
    to.top.setobj(to, index2addr(from, idx));
    api_incr_top(to);
}

pub inline fn newthread(L: *lua.State) *lua.State {
    return @ptrCast(@alignCast(c.lua_newthread(@ptrCast(L))));
}

pub fn mainthread(L: *lua.State) *lua.State {
    return L.global.mainthread;
}

//
// basic stack manipulation
//

pub fn absindex(L: *lua.State, idx: i32) i32 {
    api_check(L, (idx > 0 and idx <= L.top.sub(L.base)) or (idx < 0 and -idx <= L.top.sub(L.base)) or lua.ispseudo(idx));
    return if (idx > 0 or lua.ispseudo(idx))
        idx
    else
        @as(i32, @intCast(L.top.sub(L.base))) + idx + 1;
}

pub fn gettop(L: *lua.State) usize {
    return L.top.sub(L.base);
}

pub fn settop(L: *lua.State, idx: i32) void {
    if (idx >= 0) {
        api_check(L, idx <= L.stack_last.sub(L.base));
        const t = L.base.add_num(idx);
        while (@intFromPtr(L.top) < @intFromPtr(t)) : (L.top = L.top.add_num(1))
            L.top.setnilvalue();
        L.top = t;
    } else {
        api_check(L, -(idx + 1) <= L.top.sub(L.base));
        L.top = L.top.add_num(idx + 1); // `subtract' index (index is negative)
    }
}
pub inline fn pop(L: *lua.State, n: i32) void {
    settop(L, -n - 1);
}

pub fn remove(L: *lua.State, idx: i32) void {
    var p = index2addr(L, idx);
    api_checkvalidindex(L, p);
    p = p.add_num(1);
    while (@intFromPtr(p) < @intFromPtr(L.top)) : (p = p.add_num(1)) {
        p.sub_num(1).setobj(L, p);
    }
    L.top = L.top.sub_num(1);
}

pub fn insert(L: *lua.State, idx: i32) void {
    lgc.Cthreadbarrier(L);
    const p = index2addr(L, idx);
    api_checkvalidindex(L, p);
    var q = L.top;
    while (@intFromPtr(q) > @intFromPtr(p)) {
        const n = q.sub_num(1);
        q.setobj(L, n);
        q = n;
    }
    p.setobj(L, L.top);
}

pub fn replace(L: *lua.State, idx: i32) void {
    api_checknelems(L, 1);
    lgc.Cthreadbarrier(L);
    const o = index2addr(L, idx);
    api_checkvalidindex(L, o);
    switch (idx) {
        lua.ENVIRONINDEX => {
            api_check(L, L.ci != L.base_ci);
            const func = L.curr_func();
            api_check(L, L.top.sub_num(1).ttistable());
            func.env = L.top.sub_num(1).hvalue();
            lgc.Cbarrier(L, @ptrCast(@alignCast(func)), L.top.sub_num(1));
        },
        lua.GLOBALSINDEX => {
            api_check(L, L.top.sub_num(1).ttistable());
            L.gt = L.top.sub_num(1).hvalue();
        },
        else => {
            o.setobj(L, L.top.sub_num(1));
            if (idx < lua.GLOBALSINDEX) // function upvalue?
                lgc.Cbarrier(L, @ptrCast(@alignCast(L.curr_func())), L.top.sub_num(1));
        },
    }
    L.top = L.top.sub_num(1);
}

pub fn pushvalue(L: *lua.State, idx: i32) void {
    lgc.Cthreadbarrier(L);
    const o = index2addr(L, idx);
    L.top.setobj(L, o);
    api_incr_top(L);
}

//
// access functions (stack -> C)
//

pub fn @"type"(L: *lua.State, idx: i32) i32 {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (o == lobject.Onilobject) @intFromEnum(lua.Type.None) else o.ttype();
}
pub inline fn isfunction(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.Function);
}
pub inline fn istable(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.Table);
}
pub inline fn islightuserdata(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.LightUserdata);
}
pub inline fn isnil(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.Nil);
}
pub inline fn isboolean(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.Boolean);
}
pub inline fn isvector(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.Vector);
}
pub inline fn isthread(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.Thread);
}
pub inline fn isbuffer(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.Buffer);
}
pub inline fn isnone(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) == @intFromEnum(lua.Type.None);
}
pub inline fn isnoneornil(L: *lua.State, idx: i32) bool {
    return @"type"(L, idx) <= @intFromEnum(lua.Type.Nil);
}

pub fn typeOf(L: *lua.State, idx: i32) lua.Type {
    return index2addr(L, idx).typeOf();
}

pub fn typename(t: lua.Type) [:0]const u8 {
    return if (t == .None) "no value" else ltm.typenames[@intCast(@intFromEnum(t))];
}

pub fn iscfunction(L: *lua.State, idx: i32) bool {
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.iscfunction();
}

pub fn isLfunction(L: *lua.State, idx: i32) bool {
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.isLfunction();
}

pub fn isnumber(L: *lua.State, idx: i32) bool {
    var n: lobject.TValue = undefined;
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.ttisnumber() and lvmutils.Vtonumber(o, &n) != null;
}

pub fn isstring(L: *lua.State, idx: i32) bool {
    const t = @"type"(L, idx);
    return t == @intFromEnum(lua.Type.String) or t == @intFromEnum(lua.Type.Number);
}

pub fn isuserdata(L: *lua.State, idx: i32) bool {
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.ttisuserdata() or o.ttislightuserdata();
}

pub fn rawequal(L: *lua.State, index1: i32, index2: i32) bool {
    const o1 = index2addr(L, index1);
    const o2 = index2addr(L, index2);
    return if (o1 == lobject.Onilobject or o2 == lobject.Onilobject) false else lobject.OrawequalObj(o1, o2);
}

pub inline fn equal(L: *lua.State, index1: i32, index2: i32) bool {
    return c.lua_equal(@ptrCast(L), index1, index2) != 0;
    // const o1 = index2addr(L, index1);
    // const o2 = index2addr(L, index2);
    // return if (o1 == lobject.Onilobject or o2 == lobject.Onilobject) false else lvm.equalobj(L, o1, o2);
}

pub inline fn lessthan(L: *lua.State, index1: i32, index2: i32) bool {
    return c.lua_lessthan(@ptrCast(L), index1, index2) != 0;
}

pub fn tonumberx(L: *lua.State, idx: i32) ?f64 {
    var n: lobject.TValue = undefined;
    const o: *const lobject.TValue = index2addr(L, idx);
    if (lvmutils.Vtonumber(o, &n)) |obj|
        return obj.nvalue()
    else
        return null;
}
pub inline fn tonumber(L: *lua.State, idx: i32) ?f64 {
    return tonumberx(L, idx);
}

pub fn tointegerx(L: *lua.State, idx: i32) ?i32 {
    var n: lobject.TValue = undefined;
    const o: *const lobject.TValue = index2addr(L, idx);
    if (lvmutils.Vtonumber(o, &n)) |obj|
        return @truncate(@as(isize, @intFromFloat(obj.nvalue())))
    else
        return null;
}
pub fn tointeger(L: *lua.State, idx: i32) ?i32 {
    return tointegerx(L, idx);
}

pub fn tounsignedx(L: *lua.State, idx: i32) ?u32 {
    var n: lobject.TValue = undefined;
    const o: *const lobject.TValue = index2addr(L, idx);
    if (lvmutils.Vtonumber(o, &n)) |obj|
        return @bitCast(@as(i32, @truncate(@as(isize, @intFromFloat(obj.nvalue())))))
    else
        return null;
}
pub fn tounsigned(L: *lua.State, idx: i32) ?u32 {
    return tounsignedx(L, idx);
}

pub fn toboolean(L: *lua.State, idx: i32) bool {
    const o = index2addr(L, idx);
    return !o.l_isfalse();
}

pub fn tolstring(L: *lua.State, idx: i32) ?[:0]const u8 {
    var o = index2addr(L, idx);
    if (!o.ttisstring()) {
        lgc.Cthreadbarrier(L);
        if (!lvmutils.Vtostring(L, o))
            return null; // conversion failed?
        lgc.CcheckGC(L) catch return null;
        o = index2addr(L, idx);
    }
    return o.tsvalue().toSlice();
}
pub fn tostring(L: *lua.State, idx: i32) ?[:0]const u8 {
    return std.mem.span(@as([*c]const u8, @ptrCast((tolstring(L, idx) orelse return null).ptr)));
}

pub fn tolstringatom(L: *lua.State, idx: i32, atom: ?*i16) ?[:0]const u8 {
    const o = index2addr(L, idx);
    if (!o.ttisstring())
        return null;
    const s = o.tsvalue();
    if (atom) |a| {
        updateatom(L, s);
        a.* = s.atom;
    }
    return s.toSlice();
}

pub inline fn tostringatom(L: *lua.State, idx: i32, atom: ?*i16) ?[:0]const u8 {
    return tolstringatom(L, idx, atom);
}

pub fn namecallatom(L: *lua.State, atom: ?*i16) ?[:0]const u8 {
    const s = L.namecall orelse return null;
    if (atom) |a| {
        updateatom(L, s);
        a.* = s.atom;
    }
    return s.toSlice();
}

pub fn namecallstr(L: *lua.State) ?[]const u8 {
    const s = L.namecall;
    if (s) |str|
        return std.mem.span(str.getstr());
    return null;
}

pub fn tovector(L: *lua.State, idx: i32) ?[]const f32 {
    const o = index2addr(L, idx);
    return if (!o.ttisvector())
        null
    else
        o.vvalue();
}

pub fn objlen(L: *lua.State, idx: i32) usize {
    const o = index2addr(L, idx);
    switch (o.ttype()) {
        @intFromEnum(lua.Type.String) => return @intCast(o.tsvalue().len),
        @intFromEnum(lua.Type.Userdata) => return @intCast(o.uvalue().len),
        @intFromEnum(lua.Type.Buffer) => return @intCast(o.bufvalue().len),
        @intFromEnum(lua.Type.Table) => return ltable.Hgetn(o.hvalue()),
        else => return 0,
    }
}
pub inline fn strlen(L: *lua.State, idx: i32) usize {
    return objlen(L, idx);
}

pub fn tocfunction(L: *lua.State, idx: i32) ?lua.CFunction {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.iscfunction())
        null
    else
        o.clvalue().d.c.f;
}

pub fn tolightuserdata(L: *lua.State, comptime T: type, idx: i32) ?*T {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttislightuserdata())
        null
    else
        @ptrCast(@alignCast(o.pvalue()));
}

pub fn tolightuserdatatagged(L: *lua.State, comptime T: type, idx: i32, tag: i32) ?*T {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttislightuserdata() or o.lightuserdatatag() != tag)
        null
    else
        @ptrCast(@alignCast(o.pvalue()));
}

pub fn touserdata(L: *lua.State, comptime T: type, idx: i32) ?*T {
    const o: *const lobject.TValue = index2addr(L, idx);
    if (o.ttisuserdata())
        return @ptrCast(@alignCast(&o.uvalue().data))
    else if (o.ttislightuserdata())
        return @ptrCast(@alignCast(o.pvalue()))
    else
        return null;
}

pub fn touserdatatagged(L: *lua.State, comptime T: type, idx: i32, tag: i32) ?*T {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttisuserdata() or @as(i32, @intCast(o.uvalue().tag)) != tag)
        null
    else
        @ptrCast(@alignCast(&o.uvalue().data));
}

pub fn userdatatag(L: *lua.State, idx: i32) i32 {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (o.ttisuserdata())
        @intCast(o.uvalue().tag)
    else
        -1;
}

pub fn lightuserdatatag(L: *lua.State, idx: i32) i32 {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (o.ttislightuserdata())
        o.lightuserdatatag()
    else
        -1;
}

pub fn tothread(L: *lua.State, idx: i32) ?*lua.State {
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttisthread())
        null
    else
        o.thvalue();
}

pub fn tobuffer(L: *lua.State, idx: i32) ?[]u8 {
    const o: *const lobject.TValue = index2addr(L, idx);
    if (!o.ttisbuffer())
        return null;
    const b = o.bufvalue();
    return @as([*]u8, @ptrCast(&b.data))[0..@intCast(b.len)];
}

pub fn topointer(L: *lua.State, idx: i32) ?*const anyopaque {
    const o: *const lobject.TValue = index2addr(L, idx);
    switch (o.tt) {
        @intFromEnum(lua.Type.Userdata) => return @ptrCast(&o.uvalue().data),
        @intFromEnum(lua.Type.LightUserdata) => return @ptrCast(o.pvalue()),
        else => return if (o.iscollectable())
            @ptrCast(o.gcvalue())
        else
            null,
    }
}

//
// push functions (C -> stack)
//
pub fn pushnil(L: *lua.State) void {
    L.top.setnilvalue();
    api_incr_top(L);
}

pub fn pushnumber(L: *lua.State, n: f64) void {
    L.top.setnvalue(n);
    api_incr_top(L);
}

pub fn pushinteger(L: *lua.State, n: i32) void {
    L.top.setnvalue(@floatFromInt(n));
    api_incr_top(L);
}

pub fn pushunsigned(L: *lua.State, n: u32) void {
    L.top.setnvalue(@floatFromInt(n));
    api_incr_top(L);
}

pub fn pushvector(L: *lua.State, x: f32, y: f32, z: f32, w: ?f32) void {
    L.top.setvvalue(x, y, z, w);
    api_incr_top(L);
}

pub fn pushlstring(L: *lua.State, s: []const u8) !void {
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    L.top.setsvalue(L, try lstring.Snewlstr(L, s));
    api_incr_top(L);
}

pub inline fn pushstring(L: *lua.State, str: ?[:0]const u8) !void {
    if (str) |s| {
        try pushlstring(L, std.mem.span(@as([*c]const u8, @ptrCast(s.ptr))));
    } else pushnil(L);
}

pub fn pushvfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) !void {
    try lobject.Opushvfstring(L, fmt, args);
}
pub inline fn pushfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) !void {
    try pushvfstring(L, fmt, args);
}

pub inline fn pushcclosurek(
    L: *lua.State,
    f: lua.CFunction,
    debugname: [:0]const u8,
    n: i32,
    cont: ?lua.Continuation,
) void {
    c.lua_pushcclosurek(@ptrCast(L), @ptrCast(f), debugname, n, @ptrCast(cont));
}
pub inline fn pushcfunction(L: *lua.State, f: lua.CFunction, debugname: [:0]const u8) void {
    pushcclosurek(L, f, debugname, 0, null);
}
pub inline fn pushcclosure(L: *lua.State, f: lua.CFunction, debugname: [:0]const u8, nup: i32) void {
    pushcclosurek(L, f, debugname, nup, null);
}

pub fn pushboolean(L: *lua.State, b: bool) void {
    L.top.setbvalue(b);
    api_incr_top(L);
}

pub fn pushlightuserdatatagged(L: *lua.State, p: ?*anyopaque, tag: u32) void {
    api_check(L, tag < lua.config.LUTAG_LIMIT);
    L.top.setpvalue(p, tag);
    api_incr_top(L);
}
pub inline fn pushlightuserdata(L: *lua.State, p: ?*anyopaque) void {
    pushlightuserdatatagged(L, p, 0);
}

pub fn pushthread(L: *lua.State) bool {
    lgc.Cthreadbarrier(L);
    L.top.setthvalue(L, L);
    api_incr_top(L);
    return L.global.mainthread == L;
}

//
// get functions (Lua -> stack)
//

pub inline fn gettable(L: *lua.State, idx: i32) lua.Type {
    return @enumFromInt(c.lua_gettable(@ptrCast(L), idx));
}

pub inline fn getfield(L: *lua.State, idx: i32, k: [:0]const u8) lua.Type {
    return @enumFromInt(c.lua_getfield(@ptrCast(L), idx, k.ptr));
}
pub inline fn getglobal(L: *lua.State, k: [:0]const u8) lua.Type {
    return getfield(L, lua.GLOBALSINDEX, k);
}

pub fn rawgetfield(L: *lua.State, idx: i32, k: [:0]const u8) lua.Type {
    lgc.Cthreadbarrier(L);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    var ttype: lua.Type = .Nil;
    if (lstring.Sassumelstr(L, k)) |ts| {
        const o = ltable.Hgetstr(t.hvalue(), ts);
        L.top.setobj(L, ltable.Hgetstr(t.hvalue(), ts));
        ttype = o.typeOf();
    } else L.top.setobj(L, lobject.Onilobject);
    api_incr_top(L);
    return ttype;
}

/// get value from table value at `idx`
/// * pushes value to stack
/// * expects value at `idx` to be *table*
pub inline fn rawget(L: *lua.State, idx: i32) lua.Type {
    return @enumFromInt(c.lua_rawget(@ptrCast(L), idx));
}

/// get value from table value at `idx` with number key `n`
/// * pushes value to stack
/// * expects value at `idx` to be *table*
pub inline fn rawgeti(L: *lua.State, idx: i32, n: i32) lua.Type {
    return @enumFromInt(c.lua_rawgeti(@ptrCast(L), idx, n));
}

/// create a new table and push it to the stack
pub inline fn createtable(L: *lua.State, narray: i32, nrec: i32) void {
    c.lua_createtable(@ptrCast(L), narray, nrec);
}
/// create a new table and push it to the stack
pub inline fn newtable(L: *lua.State) void {
    c.lua_createtable(@ptrCast(L), 0, 0);
}

/// set readonly flag for table at `idx`
pub fn setreadonly(L: *lua.State, idx: i32, enabled: bool) void {
    const o = index2addr(L, idx);
    api_check(L, o.ttistable());
    const t = o.hvalue();
    api_check(L, t != L.registry().hvalue());
    t.readonly = if (enabled) 1 else 0;
}

/// get readonly flag for table at `idx`
pub fn getreadonly(L: *lua.State, idx: i32) bool {
    const o: *const lobject.TValue = index2addr(L, idx);
    api_check(L, o.ttistable());
    return o.hvalue().readonly != 0;
}

/// set safeenv flag for table at `idx`
pub fn setsafeenv(L: *lua.State, idx: i32, enabled: bool) void {
    const o = index2addr(L, idx);
    api_check(L, o.ttistable());
    o.hvalue().safeenv = if (enabled) 1 else 0;
}

/// get metatable from `idx`
/// * returns **true** if metatable is found
///   * pushes metatable to stack
pub fn getmetatable(L: *lua.State, idx: i32) bool {
    lgc.Cthreadbarrier(L);
    var mt: ?*lobject.LuaTable = null;
    const o: *const lobject.TValue = index2addr(L, idx);
    switch (o.tt) {
        @intFromEnum(lua.Type.Table) => mt = o.hvalue().metatable,
        @intFromEnum(lua.Type.Userdata) => mt = o.uvalue().metatable,
        else => mt = L.global.mt[@intCast(o.tt)],
    }
    if (mt) |ptr| {
        L.top.sethvalue(L, ptr);
        api_incr_top(L);
    }
    return mt != null;
}

pub fn getfenv(L: *lua.State, idx: i32) void {
    lgc.Cthreadbarrier(L);
    const o: *const lobject.TValue = index2addr(L, idx);
    api_checkvalidindex(L, o);
    switch (o.tt) {
        @intFromEnum(lua.Type.Function) => L.top.sethvalue(L, o.clvalue().env),
        @intFromEnum(lua.Type.Thread) => L.top.sethvalue(L, o.thvalue().gt.?),
        else => L.top.setnilvalue(),
    }
    api_incr_top(L);
}

//
// set functions (stack -> Lua)
//

/// set table value at `idx` with value:**top** and key:**top-1**
/// * pops **top** x2
/// * throws lua error if *table* is readonly
/// * throws lua error if key is *nil*/*NaN*/*NaN vector*
pub inline fn settable(L: *lua.State, idx: i32) void {
    c.lua_settable(@ptrCast(L), idx);
}

/// set table value at `idx` with value:**top** and `k`
/// * pops **top**
/// * throws lua error if *table* is readonly
pub inline fn setfield(L: *lua.State, idx: i32, k: [:0]const u8) void {
    c.lua_setfield(@ptrCast(L), idx, k.ptr);
}
pub inline fn setglobal(L: *lua.State, k: [:0]const u8) void {
    setfield(L, lua.GLOBALSINDEX, k);
}

/// set table value at `idx` with value:**top** and `k`
/// ignoring metamethods.
/// * pops **top**
/// * throws lua error if *table* is readonly
pub inline fn rawsetfield(L: *lua.State, idx: i32, k: [:0]const u8) void {
    c.lua_rawsetfield(@ptrCast(L), idx, k.ptr);
}

/// set table value at `idx` with value:**top** and key:**top-1**
/// ignoring metamethods.
/// * pops **top** x2
/// * throws lua error if *table* is readonly
/// * throws lua error if key is *nil*/*NaN*/*NaN vector*
pub inline fn rawset(L: *lua.State, idx: i32) void {
    c.lua_rawset(@ptrCast(L), idx);
}

/// set table value at `idx` with **top**
/// ignoring metamethods.
/// * pops **top**
/// * throws lua error if *table* is readonly
pub inline fn rawseti(L: *lua.State, idx: i32, n: i32) void {
    c.lua_rawseti(@ptrCast(L), idx, n);
}

/// set metatable for `idx` with **top**
/// * pops **top**
/// * expects **top** to be *table* or *nil*
/// * always returns `1`
/// * throws lua error if `idx` is *table* and readonly
pub inline fn setmetatable(L: *lua.State, idx: i32) i32 {
    return c.lua_setmetatable(@ptrCast(L), idx);
}

pub inline fn setfenv(L: *lua.State, idx: i32) bool {
    return c.lua_setfenv(@ptrCast(L), idx) != 0;
}

//
// `load' and `call' functions (run Lua code)
//

pub inline fn call(L: *lua.State, nargs: i32, nresults: i32) void {
    c.lua_call(@ptrCast(L), nargs, nresults);
}

pub fn pcall(L: *lua.State, nargs: i32, nresults: i32, msgh: i32) lua.Status {
    return @enumFromInt(c.lua_pcall(@ptrCast(L), nargs, nresults, msgh));
}

pub inline fn status(L: *lua.State) lua.Status {
    return @enumFromInt(L.curr_status);
}

pub fn costatus(L: *lua.State, co: *lua.State) lua.CoStatus {
    if (co == L)
        return .Running;
    switch (co.status()) {
        .Yield => return .Suspended,
        .Break => return .Normal,
        .Ok => {},
        else => return .FinishedErr, // some error occurred
    }
    if (co.ci != co.base_ci) // does it have frames?
        return .Normal;
    if (co.top == co.base) // is it empty?
        return .Finished;
    return .Suspended; // initial state
}

pub fn getthreaddata(L: *lua.State, comptime T: type) T {
    switch (@typeInfo(T)) {
        .pointer => {},
        .optional => |opt| {
            if (@typeInfo(opt.child) != .pointer)
                @compileError("T optional type must be a pointer type");
        },
        else => @compileError("T must be optional or a pointer type"),
    }
    return @ptrCast(@alignCast(L.userdata));
}

pub fn setthreaddata(L: *lua.State, comptime T: type, data: T) void {
    switch (@typeInfo(T)) {
        .pointer => {},
        .optional => |opt| {
            if (@typeInfo(opt.child) != .pointer)
                @compileError("T optional type must be a pointer type");
        },
        else => @compileError("T must be optional or a pointer type"),
    }
    L.userdata = @ptrCast(data);
}

//
// Garbage-collection function
//

pub inline fn gc(L: *lua.State, what: lua.GCOp, data: i32) i32 {
    return c.lua_gc(@ptrCast(L), @intFromEnum(what), data);
}

pub fn @"error"(L: *lua.State) noreturn {
    api_checknelems(L, 1);
    ldo.throw(L, .ErrRun);
    unreachable;
}

pub inline fn next(L: *lua.State, idx: i32) bool {
    return c.lua_next(@ptrCast(L), idx) != 0;
}

pub inline fn rawiter(L: *lua.State, idx: i32, iter: i32) i32 {
    return c.lua_rawiter(@ptrCast(L), idx, iter);
}

pub inline fn concat(L: *lua.State, idx: i32) void {
    c.lua_concat(@ptrCast(L), idx);
}

pub fn newuserdatatagged(L: *lua.State, comptime T: type, tag: u8) !*T {
    api_check(L, tag < lua.config.UTAG_LIMIT or tag == ludata.UTAG_PROXY);
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const u = try ludata.Unewudata(L, @sizeOf(T), tag);
    L.top.setuvalue(L, u);
    api_incr_top(L);
    return @ptrCast(@alignCast(&u.data));
}
pub inline fn newuserdata(L: *lua.State, comptime T: type) !*T {
    return newuserdatatagged(L, T, 0);
}

pub fn newuserdatataggedwithmetatable(L: *lua.State, comptime T: type, tag: i32) !*T {
    api_check(L, tag < lua.config.UTAG_LIMIT);
    lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const u = try ludata.Unewudata(L, @sizeOf(T), tag);

    // currently, we always allocate unmarked objects, so forward barrier can be skipped
    std.debug.assert(!lgc.isblack(@ptrCast(@alignCast(u))));

    const h = L.global.udatamt[tag];
    api_check(L, h != null);

    u.metatable = h;

    L.top.setuvalue(L, u);
    api_incr_top(L);
    return @ptrCast(@alignCast(&u.data));
}

pub fn newuserdatadtor(L: *lua.State, comptime T: type, comptime dtorFn: *const fn (dtor: *T) void) !*T {
    const dtor: *const fn (?*anyopaque) callconv(.c) void = struct {
        fn inner(dtor: ?*anyopaque) callconv(.c) void {
            @call(.always_inline, dtorFn, .{@as(*T, @ptrCast(@alignCast(dtor.?)))});
        }
    }.inner;
    const sz = @sizeOf(T);

    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    // make sure sz + sizeof(dtor) doesn't overflow; luaU_newdata will reject SIZE_MAX correctly
    const as = if (sz < std.math.maxInt(usize) - @sizeOf(@TypeOf(dtor))) sz + @sizeOf(@TypeOf(dtor)) else std.math.maxInt(usize);
    const u = try ludata.Unewudata(L, as, ludata.UTAG_IDTOR);
    @memcpy(@as([*]u8, &u.data)[sz..], &@as([@sizeOf(usize)]u8, @bitCast(@intFromPtr(dtor))));
    L.top.setuvalue(L, u);
    api_incr_top(L);
    return @ptrCast(@alignCast(&u.data));
}

pub fn newbuffer(L: *lua.State, sz: usize) ![]u8 {
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const b = try lbuffer.Bnewbuffer(L, sz);
    L.top.setbufvalue(L, b);
    api_incr_top(L);
    return @as([*]u8, @ptrCast(@alignCast(&b.data)))[0..sz];
}

pub inline fn getupvalue(L: *lua.State, funcidx: i32, n: i32) ?[:0]const u8 {
    const name = c.lua_getupvalue(@ptrCast(L), funcidx, n);
    if (name != null)
        return std.mem.span(name);
    return null;
}

pub inline fn setupvalue(L: *lua.State, funcidx: i32, n: i32) ?[:0]const u8 {
    const name = c.lua_setupvalue(@ptrCast(L), funcidx, n);
    if (name != null)
        return std.mem.span(name);
    return null;
}

pub fn encodepointer(L: *lua.State, p: usize) usize {
    const g = L.global;
    return @intCast(g.ptrenckey[0] * p + g.ptrenckey[2] ^ (g.ptrenckey[1] * p + g.ptrenckey[3]));
}

pub fn ref(L: *lua.State, idx: i32) !?i32 {
    api_check(L, idx != lua.REGISTRYINDEX); // idx is a stack index for value

    const g = L.global;
    const p = index2addr(L, idx);
    if (!p.ttisnil()) {
        const reg = L.registry().hvalue();
        var r: i32 = undefined;
        if (g.registryfree != 0) { // reuse existing slot
            r = g.registryfree;
        } else { // no free elements
            r = @intCast(ltable.Hgetn(reg));
            r += 1; // create new reference
        }

        const slot = try ltable.Hsetnum(L, reg, r);
        if (g.registryfree != 0)
            g.registryfree = @intFromFloat(slot.nvalue());
        slot.setobj(L, p);
        lgc.Cbarriert(L, reg, p);
        return r;
    } else return null; // no value to reference
}

pub fn unref(L: *lua.State, r: i32) void {
    if (r <= lua.REFNIL)
        return;

    const g = L.global;
    const reg = L.registry().hvalue();

    const slot = ltable.Hgetnum(reg, r);
    api_check(L, slot != lobject.Onilobject);

    // similar to how 'luaH_setnum' makes non-nil slot value mutable
    const mutableSlot: *lobject.TValue = @constCast(slot);

    // NB: no barrier needed because value isn't collectable
    mutableSlot.setnvalue(@floatFromInt(g.registryfree));

    g.registryfree = r;
}

pub fn setuserdatatag(L: *lua.State, idx: i32, tag: u8) void {
    api_check(L, tag < lua.config.UTAG_LIMIT);
    const o = index2addr(L, idx);
    api_check(L, o.ttisuserdata());
    o.uvalue().tag = tag;
}

pub fn setuserdatadtor(L: *lua.State, comptime T: type, tag: u32, comptime dtorfn: ?*const fn (L: *lua.State, ptr: *T) void) void {
    api_check(L, tag < lua.config.UTAG_LIMIT);
    L.global.udatagc[tag] = if (dtorfn) |dtor| struct {
        fn inner(state: *lua.State, ptr: ?*anyopaque) callconv(.c) void {
            @call(.always_inline, dtor, .{
                state,
                @as(*T, @ptrCast(@alignCast(ptr.?))),
            });
        }
    }.inner else null;
}

pub fn getuserdatadtor(L: *lua.State, tag: u32) ?lua.Destructor {
    api_check(L, tag < lua.config.UTAG_LIMIT);
    return L.global.udatagc[tag];
}

pub fn setuserdatametatable(L: *lua.State, tag: u32) void {
    api_check(L, tag < lua.config.UTAG_LIMIT);
    api_check(L, L.global.udatamt[tag] == null); // reassignment not supported
    api_check(L, L.top.sub_num(1).ttistable());
    const n = L.top.sub_num(1);
    L.global.udatamt[tag] = n.hvalue();
    L.top = n;
}

pub fn getuserdatametatable(L: *lua.State, tag: u8) void {
    api_check(L, tag < lua.config.UTAG_LIMIT);
    lgc.Cthreadbarrier(L);

    if (L.global.udatamt[tag]) |h|
        L.top.sethvalue(L, h)
    else
        L.top.setnilvalue();

    api_incr_top(L);
}

pub fn setlightuserdataname(L: *lua.State, tag: u8, name: [:0]const u8) !void {
    api_check(L, tag < lua.config.LUTAG_LIMIT);
    api_check(L, L.global.lightuserdataname[tag] == null); // renaming not supported
    L.global.lightuserdataname[tag] = try lstring.Snewlstr(L, name);
    lstring.Sfix(L.global.lightuserdataname[tag].?); // never collect these names
}

pub fn getlightuserdataname(L: *lua.State, tag: u32) ?[:0]const u8 {
    api_check(L, tag < lua.config.LUTAG_LIMIT);
    const name = L.global.lightuserdataname[tag];
    return if (name) |s|
        std.mem.span(s.getstr())
    else
        null;
}

pub inline fn clonefunction(L: *lua.State, idx: i32) void {
    c.lua_clonefunction(@ptrCast(L), idx);
}

pub inline fn cleartable(L: *lua.State, idx: i32) void {
    c.lua_cleartable(@ptrCast(L), idx);
}

pub inline fn clonetable(L: *lua.State, idx: i32) void {
    c.lua_clonetable(@ptrCast(L), idx);
}

pub fn callbacks(L: *lua.State) *lua.Callbacks {
    return &L.global.cb;
}

pub fn setmemcat(L: *lua.State, category: u8) void {
    api_check(L, category < lua.config.MEMORY_CATEGORIES);
    L.activememcat = category;
}

pub fn totalbytes(L: *lua.State, category: i32) usize {
    api_check(L, category < lua.config.MEMORY_CATEGORIES);
    return if (category < 0)
        L.global.totalbytes
    else
        L.global.memcatbytes[@intCast(category)];
}

pub fn getallocf(L: *lua.State, ud: ?**anyopaque) ?lua.Alloc {
    const f = L.global.frealloc;
    if (ud) |ptr|
        ptr.* = L.global.ud;
    return f;
}
