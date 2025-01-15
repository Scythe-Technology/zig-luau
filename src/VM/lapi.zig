const c = @import("c");
const std = @import("std");

const lgc = @import("lgc.zig");
const ltm = @import("ltm.zig");
const lua = @import("lua.zig");
const lobject = @import("lobject.zig");
const lvmutils = @import("lvmutils.zig");

const State = lua.State;

pub inline fn check(L: *State, cond: bool) void {
    _ = L;
    std.debug.assert(cond);
}

pub inline fn incr_top(L: *State) void {
    check(L, @intFromPtr(L.top) <= @intFromPtr(L.stack_last));
    L.top = L.top.add_num(1);
}

pub inline fn checknelems(L: *State, n: u32) void {
    check(L, n <= @intFromPtr(L.top) - @intFromPtr(L.base));
}

pub inline fn checkvalidindex(L: *State, obj: lobject.StkId) void {
    check(L, obj != lobject.nilobject);
}

pub fn getcurrenv(L: *lua.State) *lobject.Table {
    if (L.ci == L.base_ci) // no enclosing function?
        return L.gt.? // use global table as environment
    else
        return L.curr_func().env;
}

pub noinline fn pseudo2addr(L: *State, idx: i32) lobject.StkId {
    check(L, lua.ispseudo(idx));
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
                &func.d.c.upvals[@intCast(i - 1)]
            else
                @constCast(lobject.nilobject);
        },
    }
}

pub inline fn index2addr(L: *State, idx: i32) lobject.StkId {
    if (idx > 0) {
        const o: usize = @intFromPtr(L.base.add_num(@intCast(idx - 1)));
        check(L, idx <= L.ci.?.top.sub(L.base));
        if (o >= @intFromPtr(L.top))
            return @constCast(lobject.nilobject)
        else
            return @ptrFromInt(o);
    } else if (idx > lua.REGISTRYINDEX) {
        check(L, idx != 0 and -idx <= L.top.sub(L.base));
        if (idx < 0)
            return L.top.sub_num(@abs(idx))
        else
            return L.top.add_num(@intCast(idx));
    } else {
        return pseudo2addr(L, idx);
    }
}

pub fn Atoobject(L: *lua.State, idx: i32) ?*const lobject.TValue {
    const p = index2addr(L, idx);
    return if (p == lobject.nilobject) null else p;
}

pub fn Apushobject(L: *lua.State, o: *const lobject.TValue) void {
    L.top.setobj(L, o);
    incr_top(L);
}

pub inline fn checkstack(L: *lua.State, size: i32) bool {
    return c.lua_checkstack(@ptrCast(L), size) != 0;
}
pub inline fn rawcheckstack(L: *lua.State, size: i32) void {
    c.lua_rawcheckstack(@ptrCast(L), size);
}

pub fn xmove(from: *lua.State, to: *lua.State, n: u32) void {
    if (from == to)
        return;
    checknelems(from, n);
    check(from, from.global == to.global);
    check(from, to.ci.?.top.sub(to.top) >= n);
    lgc.Cthreadbarrier(to);

    const ttop = to.top;
    const ftop = from.top.sub_num(n);
    for (0..@intCast(n)) |i|
        ttop.add_num(i).setobj(to, ftop.add_num(i));

    from.top = ftop;
    to.top = ttop.add_num(n);
}

pub fn xpush(from: *lua.State, to: *lua.State, idx: i32) void {
    check(from, from.global == to.global);
    lgc.Cthreadbarrier(to);
    to.top.setobj(to, index2addr(from, idx));
    incr_top(to);
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

pub inline fn absindex(L: *lua.State, idx: i32) i32 {
    return c.lua_absindex(@ptrCast(L), idx);
}

pub fn gettop(L: *lua.State) usize {
    return L.top.sub(L.base);
}

pub inline fn settop(L: *lua.State, idx: i32) void {
    c.lua_settop(@ptrCast(L), idx);
}
pub inline fn pop(L: *lua.State, n: i32) void {
    settop(L, -n - 1);
}

pub inline fn remove(L: *lua.State, idx: i32) void {
    c.lua_remove(@ptrCast(L), idx);
}

pub inline fn insert(L: *lua.State, idx: i32) void {
    c.lua_insert(@ptrCast(L), idx);
}

pub inline fn replace(L: *lua.State, idx: i32) void {
    c.lua_replace(@ptrCast(L), idx);
}

pub inline fn pushvalue(L: *lua.State, idx: i32) void {
    c.lua_pushvalue(@ptrCast(L), idx);
}

//
// access functions (stack -> C)
//

pub fn @"type"(L: *lua.State, idx: i32) i32 {
    const o = index2addr(L, idx);
    return if (o == lobject.nilobject) @intFromEnum(lua.Type.None) else o.ttype();
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
    const o = index2addr(L, idx);
    return o.iscfunction();
}

pub fn isLfunction(L: *lua.State, idx: i32) bool {
    const o = index2addr(L, idx);
    return o.isLfunction();
}

pub inline fn isnumber(L: *lua.State, idx: i32) bool {
    return c.lua_isnumber(@ptrCast(L), idx) != 0;
}

pub fn isstring(L: *lua.State, idx: i32) bool {
    const t = @"type"(L, idx);
    return t == @intFromEnum(lua.Type.String) or t == @intFromEnum(lua.Type.Number);
}

pub fn isuserdata(L: *lua.State, idx: i32) bool {
    const o = index2addr(L, idx);
    return o.ttisuserdata() or o.ttislightuserdata();
}

pub inline fn rawequal(L: *lua.State, index1: i32, index2: i32) bool {
    return c.lua_rawequal(@ptrCast(L), index1, index2) != 0;
}

pub inline fn equal(L: *lua.State, index1: i32, index2: i32) bool {
    return c.lua_equal(@ptrCast(L), index1, index2) != 0;
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
        return @truncate(@as(i52, @intFromFloat(obj.nvalue())))
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
        return @truncate(@as(u64, @intFromFloat(obj.nvalue())))
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

pub inline fn tolstring(L: *lua.State, idx: i32) ?[:0]const u8 {
    var len: usize = undefined;
    if (c.lua_tolstring(@ptrCast(L), idx, &len)) |str|
        return str[0..len :0];
    return null;
}
pub inline fn tostring(L: *lua.State, idx: i32) ?[:0]const u8 {
    return tolstring(L, idx);
}

pub inline fn namecallatom(L: *lua.State, atom: ?[*c]c_int) [*c]const u8 {
    return c.lua_namecallatom(@ptrCast(L), atom);
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

pub inline fn objlen(L: *lua.State, idx: i32) usize {
    return @intCast(c.lua_objlen(@ptrCast(L), idx));
}
pub inline fn strlen(L: *lua.State, idx: i32) usize {
    return objlen(L, idx);
}

pub fn tocfunction(L: *lua.State, idx: i32) ?lua.CFunction {
    const o = index2addr(L, idx);
    return if (!o.iscfunction())
        null
    else
        o.clvalue().d.c.f;
}

pub fn tolightuserdata(L: *lua.State, comptime T: type, idx: i32) ?*T {
    const o = index2addr(L, idx);
    return if (!o.ttislightuserdata())
        null
    else
        @ptrCast(o.pvalue());
}

pub fn tolightuserdatatagged(L: *lua.State, comptime T: type, idx: i32, tag: i32) ?*T {
    const o = index2addr(L, idx);
    return if (!o.ttislightuserdata() or o.lightuserdatatag() != tag)
        null
    else
        @ptrCast(o.pvalue());
}

pub fn touserdata(L: *lua.State, comptime T: type, idx: i32) ?*T {
    const o = index2addr(L, idx);
    if (o.ttisuserdata())
        return @ptrCast(&o.uvalue().data)
    else if (o.ttislightuserdata())
        return @ptrCast(@alignCast(o.pvalue()))
    else
        return null;
}

pub fn touserdatatagged(L: *lua.State, comptime T: type, idx: i32, tag: i32) ?*T {
    const o = index2addr(L, idx);
    return if (o.ttisuserdata() and @as(i32, @intCast(o.uvalue().tag)) != tag)
        @ptrCast(o.uvalue().data)
    else
        null;
}

pub fn userdatatag(L: *lua.State, idx: i32) i32 {
    const o = index2addr(L, idx);
    return if (o.ttisuserdata())
        @intCast(o.uvalue().tag)
    else
        -1;
}

pub fn lightuserdatatag(L: *lua.State, idx: i32) i32 {
    const o = index2addr(L, idx);
    return if (o.ttislightuserdata())
        o.lightuserdatatag()
    else
        -1;
}

pub fn tothread(L: *lua.State, idx: i32) ?*lua.State {
    const o = index2addr(L, idx);
    return if (!o.ttisthread())
        null
    else
        o.thvalue();
}

pub fn tobuffer(L: *lua.State, idx: i32) ?[]u8 {
    const o = index2addr(L, idx);
    if (!o.ttisbuffer())
        return null;
    const b = o.bufvalue();
    return @as([*]u8, @ptrCast(&b.data))[0..@intCast(b.len)];
}

pub fn topointer(L: *lua.State, idx: i32) ?*const anyopaque {
    const o = index2addr(L, idx);
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
    incr_top(L);
}

pub fn pushnumber(L: *lua.State, n: f64) void {
    L.top.setnvalue(n);
    incr_top(L);
}

pub fn pushinteger(L: *lua.State, n: i32) void {
    L.top.setnvalue(@floatFromInt(n));
    incr_top(L);
}

pub fn pushunsigned(L: *lua.State, n: u32) void {
    L.top.setnvalue(@floatFromInt(n));
    incr_top(L);
}

pub fn pushvector(L: *lua.State, x: f32, y: f32, z: f32, w: ?f32) void {
    L.top.setvvalue(x, y, z, w);
    incr_top(L);
}

pub inline fn pushlstring(L: *lua.State, s: []const u8) void {
    c.lua_pushlstring(@ptrCast(L), s.ptr, s.len);
}

pub inline fn pushstring(L: *lua.State, str: ?[:0]const u8) void {
    c.lua_pushstring(@ptrCast(L), if (str) |s| s.ptr else null);
}

pub fn pushvfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) void {
    lobject.Opushvfstring(L, fmt, args);
}
pub inline fn pushfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) void {
    pushvfstring(L, fmt, args);
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
    incr_top(L);
}

pub fn pushlightuserdatatagged(L: *lua.State, p: ?*anyopaque, tag: u32) void {
    check(L, tag < lua.config.LUTAG_LIMIT);
    L.top.setpvalue(p, tag);
    incr_top(L);
}
pub inline fn pushlightuserdata(L: *lua.State, p: ?*anyopaque) void {
    pushlightuserdatatagged(L, p, 0);
}

pub fn pushthread(L: *lua.State) bool {
    lgc.Cthreadbarrier(L);
    L.top.setthvalue(L, L);
    incr_top(L);
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

pub inline fn rawgetfield(L: *lua.State, idx: i32, k: [:0]const u8) lua.Type {
    return @enumFromInt(c.lua_rawgetfield(@ptrCast(L), idx, k.ptr));
}

pub inline fn rawget(L: *lua.State, idx: i32) lua.Type {
    return @enumFromInt(c.lua_rawget(@ptrCast(L), idx));
}

pub inline fn rawgeti(L: *lua.State, idx: i32, n: i32) lua.Type {
    return @enumFromInt(c.lua_rawgeti(@ptrCast(L), idx, n));
}

pub inline fn createtable(L: *lua.State, narray: i32, nrec: i32) void {
    c.lua_createtable(@ptrCast(L), narray, nrec);
}
pub inline fn newtable(L: *lua.State) void {
    c.lua_createtable(@ptrCast(L), 0, 0);
}

pub fn setreadonly(L: *lua.State, idx: i32, enabled: bool) void {
    const o = index2addr(L, idx);
    check(L, o.ttistable());
    const t = o.hvalue();
    check(L, t != L.registry().hvalue());
    t.readonly = if (enabled) 1 else 0;
}

pub fn getreadonly(L: *lua.State, idx: i32) bool {
    const o = index2addr(L, idx);
    check(L, o.ttistable());
    return o.hvalue().readonly != 0;
}

pub fn setsafeenv(L: *lua.State, idx: i32, enabled: bool) void {
    const o: *const lobject.TValue = index2addr(L, idx);
    check(L, o.ttistable());
    o.hvalue().safeenv = if (enabled) 1 else 0;
}

pub fn getmetatable(L: *lua.State, idx: i32) bool {
    gc.Cthreadbarrier(L);
    var mt: ?*lobject.Table = null;
    const o: *const lobject.TValue = index2addr(L, idx);
    switch (o.tt) {
        @intFromEnum(lua.Type.Table) => mt = o.hvalue().metatable,
        @intFromEnum(lua.Type.Userdata) => mt = o.uvalue().metatable,
        else => mt = L.global.mt[o.tt],
    }
    if (mt) |ptr| {
        L.top.sethvalue(L, ptr);
        incr_top(L);
    }
    return mt != null;
}

pub fn getfenv(L: *lua.State, idx: i32) bool {
    gc.Cthreadbarrier(L);
    const o: *const lobject.TValue = index2addr(L, idx);
    checkvalidindex(L, o);
    switch (o.tt) {
        @intFromEnum(lua.Type.Function) => L.top.sethvalue(o.clvalue().env),
        @intFromEnum(lua.Type.Thread) => L.top.sethvalue(o.thvalue().gt),
        else => L.top.setnilvalue(),
    }
    incr_top(L);
}

//
// set functions (stack -> Lua)
//

pub inline fn settable(L: *lua.State, idx: i32) void {
    c.lua_settable(@ptrCast(L), idx);
}

pub inline fn setfield(L: *lua.State, idx: i32, k: [:0]const u8) void {
    c.lua_setfield(@ptrCast(L), idx, k.ptr);
}
pub inline fn setglobal(L: *lua.State, k: [:0]const u8) void {
    setfield(L, lua.GLOBALSINDEX, k);
}

pub inline fn rawsetfield(L: *lua.State, idx: i32, k: [:0]const u8) void {
    c.lua_rawsetfield(@ptrCast(L), idx, k.ptr);
}

pub inline fn rawset(L: *lua.State, idx: i32) void {
    c.lua_rawset(@ptrCast(L), idx);
}

pub inline fn rawseti(L: *lua.State, idx: i32, n: i32) void {
    c.lua_rawseti(@ptrCast(L), idx, n);
}

pub inline fn setmetatable(L: *lua.State, idx: i32) i32 {
    return c.lua_setmetatable(@ptrCast(L), idx);
}

pub inline fn setfenv(L: *lua.State, idx: i32) void {
    return c.lua_setfenv(@ptrCast(L), idx);
}

//
// `load' and `call' functions (run Lua code)
//

pub inline fn call(L: *lua.State, nargs: i32, nresults: i32) void {
    c.lua_call(@ptrCast(L), nargs, nresults);
}

pub inline fn pcall(L: *lua.State, nargs: i32, nresults: i32, msgh: i32) lua.Status {
    return @enumFromInt(c.lua_pcall(@ptrCast(L), nargs, nresults, msgh));
}

pub inline fn status(L: *lua.State) lua.Status {
    return @enumFromInt(L.tstatus);
}

pub inline fn costatus(L: *lua.State, co: *lua.State) lua.CoStatus {
    return @enumFromInt(c.lua_costatus(@ptrCast(L), @ptrCast(co)));
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

pub inline fn @"error"(L: *lua.State) noreturn {
    return c.lua_error(@ptrCast(L));
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

pub inline fn newuserdatatagged(L: *lua.State, comptime T: type, tag: i32) *T {
    return @ptrCast(@alignCast(c.lua_newuserdatatagged(@ptrCast(L), @sizeOf(T), tag)));
}
pub inline fn newuserdata(L: *lua.State, comptime T: type) *T {
    return newuserdatatagged(L, T, 0);
}

pub inline fn newuserdatataggedwithmetatable(L: *lua.State, comptime T: type, tag: i32) *T {
    return c.lua_newuserdatataggedwithmetatable(@ptrCast(L), @sizeOf(T), tag);
}

pub inline fn newuserdatadtor(L: *lua.State, comptime T: type, dtorFn: *const fn (dtor: *T) void) *T {
    return @ptrCast(@alignCast(c.lua_newuserdatadtor(@ptrCast(L), @sizeOf(T), struct {
        fn inner(dtor: ?*anyopaque) callconv(.c) void {
            @call(.always_inline, dtorFn, .{@as(*T, @ptrCast(@alignCast(dtor.?)))});
        }
    }.inner)));
}

pub inline fn newbuffer(L: *lua.State, sz: usize) []u8 {
    return @as([*]u8, @ptrCast(c.lua_newbuffer(@ptrCast(L), sz).?))[0..sz];
}

pub inline fn getupvalue(L: *lua.State, funcidx: i32, n: i32) ?[]const u8 {
    return c.lua_getupvalue(@ptrCast(L), funcidx, n);
}

pub inline fn setupvalue(L: *lua.State, funcidx: i32, n: i32) ?[]const u8 {
    return c.lua_setupvalue(@ptrCast(L), funcidx, n);
}

pub fn ref(L: *lua.State, idx: i32) ?i32 {
    const ref_id = c.lua_ref(@ptrCast(L), idx);
    if (ref_id == lua.REFNIL)
        return null;
    return ref_id;
}

pub inline fn unref(L: *lua.State, r: i32) void {
    c.lua_unref(@ptrCast(L), r);
}

pub inline fn setuserdatatag(L: *lua.State, idx: i32, tag: i32) void {
    c.lua_setuserdatatag(@ptrCast(L), idx, tag);
}

pub inline fn setuserdatadtor(L: *lua.State, comptime T: type, tag: i32, comptime dtorfn: ?*const fn (L: *lua.State, ptr: *T) void) void {
    if (dtorfn) |dtor| {
        c.lua_setuserdatadtor(@ptrCast(L), tag, struct {
            fn inner(state: ?*c.lua_State, ptr: ?*anyopaque) callconv(.C) void {
                @call(.always_inline, dtor, .{
                    @as(*lua.State, @ptrCast(state.?)),
                    @as(*T, @ptrCast(ptr.?)),
                });
            }
        }.inner);
    } else c.lua_setuserdatadtor(@ptrCast(L), tag, null);
}

pub inline fn getuserdatadtor(L: *lua.State, tag: i32) ?lua.Destructor {
    return c.lua_getuserdatadtor(@ptrCast(L), tag);
}

pub inline fn setuserdatametatable(L: *lua.State, tag: i32, idx: i32) void {
    c.lua_setuserdatametatable(@ptrCast(L), tag, idx);
}

pub inline fn getuserdatametatable(L: *lua.State, tag: i32) void {
    c.lua_getuserdatametatable(@ptrCast(L), tag);
}

pub inline fn setlightuserdataname(L: *lua.State, tag: i32, name: [:0]const u8) void {
    c.lua_setlightuserdataname(@ptrCast(L), tag, name.ptr);
}

pub inline fn getlightuserdataname(L: *lua.State, tag: i32) ?[:0]const u8 {
    const name = c.lua_getlightuserdataname(@ptrCast(L), tag);
    return if (name != null)
        std.mem.span(name)
    else
        null;
}

pub inline fn clonefunction(L: *lua.State, idx: i32) void {
    c.lua_clonefunction(@ptrCast(L), idx);
}

pub inline fn cleartable(L: *lua.State, idx: i32) void {
    c.lua_cleartable(@ptrCast(L), idx);
}

pub inline fn callbacks(L: *lua.State) *lua.Callbacks {
    return c.lua_callbacks(@ptrCast(L));
}

pub inline fn setmemcat(L: *lua.State, category: i32) void {
    c.lua_setmemcat(@ptrCast(L), category);
}

pub inline fn totalbytes(L: *lua.State, category: i32) usize {
    return c.lua_totalbytes(@ptrCast(L), category);
}

pub inline fn getallocf(L: *lua.State, ud: ?**anyopaque) ?lua.Alloc {
    return c.lua_getallocf(@ptrCast(L), @ptrCast(ud));
}
