const c = @import("c");
const std = @import("std");

const build_config = @import("config");

const lua = @import("lua.zig");

const lstring = @import("lstring.zig");
const lgc = @import("lgc.zig");
const ltm = @import("ltm.zig");
const ldo = @import("ldo.zig");
const lvm = @import("lvm.zig");
const lfunc = @import("lfunc.zig");
const ltable = @import("ltable.zig");
const ludata = @import("ludata.zig");
const lstate = @import("lstate.zig");
const lbuffer = @import("lbuffer.zig");
const lobject = @import("lobject.zig");
const lvmutils = @import("lvmutils.zig");

const Errorset = @import("errorset.zig");

const State = lua.State;

pub fn api_check(L: *State, cond: bool) void {
    _ = L;
    std.debug.assert(cond);
}

pub inline fn api_checknelems(L: *State, n: u32) void {
    api_check(L, n <= L.top - L.base);
}

pub inline fn api_checkvalidindex(L: *State, obj: *const lobject.TValue) void {
    api_check(L, obj != lobject.Onilobject);
}

pub inline fn api_incr_top(L: *State) void {
    api_check(L, @intFromPtr(L.top) < @intFromPtr(L.ci.?[0].top));
    L.top += 1;
}

pub inline fn api_update_top(L: *State, p: *lobject.TValue) void {
    api_check(L, @intFromPtr(p) >= @intFromPtr(L.base) and @intFromPtr(p) < @intFromPtr(L.ci.?[0].top));
    L.top = @ptrCast(p);
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

pub noinline fn pseudo2addr(L: *State, idx: i32) *lobject.TValue {
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
                &func.d.c.upvalues()[@intCast(i - 1)]
            else
                @constCast(lobject.Onilobject);
        },
    }
}

pub inline fn index2addr(L: *State, idx: i32) *lobject.TValue {
    if (idx > 0) {
        const o: usize = @intFromPtr(&L.base[@intCast(idx - 1)]);
        api_check(L, idx <= L.ci.?[0].top - L.base);
        if (o >= @intFromPtr(L.top))
            return @constCast(lobject.Onilobject)
        else
            return @ptrFromInt(o);
    } else if (idx > lua.REGISTRYINDEX) {
        api_check(L, idx != 0 and -idx <= L.top - L.base);
        return @ptrCast(L.top - @as(usize, @intCast(-idx)));
    } else {
        return pseudo2addr(L, idx);
    }
}

pub fn Atoobject(L: *lua.State, idx: i32) ?*const lobject.TValue {
    const p = index2addr(L, idx);
    return if (p == lobject.Onilobject) null else p;
}

pub fn Apushobject(L: *lua.State, o: *const lobject.TValue) void {
    L.top[0].setobj(L, o);
    api_incr_top(L);
}

pub fn checkstack(L: *lua.State, size: usize) Errorset.Memory!bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_checkstack(@ptrCast(L), @as(i32, @intCast(size))) != 0;
    }
    if (size > lua.config.I_MAXCSTACK or (L.top - L.base + size) > lua.config.I_MAXCSTACK)
        return false
    else {
        if (ldo.stacklimitreached(L, size)) {
            try ldo.Dgrowstack(L, size);
        } else {
            if (comptime build_config.hard_stack_tests)
                try ldo.Dreallocstack(L, L.stacksize - lua.config.EXTRA_SIZE, false);
        }
        ldo.expandstacklimit(L, &L.top[size]);
        return true;
    }
}
pub fn rawcheckstack(L: *lua.State, size: usize) Errorset.Memory!void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_rawcheckstack(@ptrCast(L), @as(i32, @intCast(size)));
    }
    try ldo.Dcheckstack(L, size);
    ldo.expandstacklimit(L, &L.top[size]);
}

pub fn xmove(from: *lua.State, to: *lua.State, n: u32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_xmove(@ptrCast(from), @ptrCast(to), @as(i32, @intCast(n)));
    }
    if (from == to)
        return;
    api_checknelems(from, n);
    api_check(from, from.global == to.global);
    api_check(from, to.ci.?[0].top - to.top >= n);
    lgc.Cthreadbarrier(to);

    const ttop = to.top;
    const ftop = from.top - n;
    for (0..@intCast(n)) |i|
        ttop[i].setobj(to, &ftop[i]);

    from.top = @ptrCast(ftop);
    to.top = ttop[n..];
}

pub fn xpush(from: *lua.State, to: *lua.State, idx: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_xpush(@ptrCast(from), @ptrCast(to), idx);
    }
    api_check(from, from.global == to.global);
    lgc.Cthreadbarrier(to);
    to.top[0].setobj(to, index2addr(from, idx));
    api_incr_top(to);
}

pub fn newthread(L: *lua.State) Errorset.Table!*lua.State {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_newthread(@ptrCast(L))));
    }
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const L1 = try lstate.Enewthread(L);
    L.top[0].setthvalue(L, L1);
    api_incr_top(L);
    const g = L.global;
    if (g.cb.userthread) |userthread|
        userthread(L, L1);
    return L1;
}

pub fn mainthread(L: *lua.State) *lua.State {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_mainthread(@ptrCast(L))));
    }
    return L.global.mainthread;
}

//
// basic stack manipulation
//

pub fn absindex(L: *lua.State, idx: i32) i32 {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_absindex(@ptrCast(L), idx);
    }
    api_check(L, (idx > 0 and idx <= L.top - L.base) or (idx < 0 and -idx <= L.top - L.base) or lua.ispseudo(idx));
    return if (idx > 0 or lua.ispseudo(idx))
        idx
    else
        @as(i32, @intCast(L.top - L.base)) + idx + 1;
}

pub fn gettop(L: *lua.State) usize {
    if (comptime !build_config.use_zig_backend) {
        return @intCast(c.lua_gettop(@ptrCast(L)));
    }
    return L.top - L.base;
}

pub fn settop(L: *lua.State, idx: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_settop(@ptrCast(L), idx);
    }
    if (idx >= 0) {
        api_check(L, idx <= L.stack_last - L.base);
        const t = L.base[@intCast(idx)..];
        while (@intFromPtr(L.top) < @intFromPtr(t)) : (L.top = L.top[1..])
            L.top[0].setnilvalue();
        L.top = t;
    } else {
        api_check(L, -(idx + 1) <= L.top - L.base);
        L.top -= @as(usize, @intCast(-(idx + 1))); // `subtract' index (index is negative)
    }
}
pub inline fn pop(L: *lua.State, n: i32) void {
    settop(L, -n - 1);
}

pub fn remove(L: *lua.State, idx: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_remove(@ptrCast(L), idx);
    }
    var p: [*]lobject.TValue = @ptrCast(index2addr(L, idx));
    api_checkvalidindex(L, @ptrCast(p));
    p += 1;
    while (@intFromPtr(p) < @intFromPtr(L.top)) : (p += 1)
        (p - 1)[0].setobj(L, @ptrCast(p));
    L.top -= 1;
}

pub fn insert(L: *lua.State, idx: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_insert(@ptrCast(L), idx);
    }
    lgc.Cthreadbarrier(L);
    const p = index2addr(L, idx);
    api_checkvalidindex(L, p);
    var q = L.top;
    while (@intFromPtr(q) > @intFromPtr(p)) {
        const n = q - 1;
        q[0].setobj(L, @ptrCast(n));
        q = n;
    }
    p.setobj(L, &L.top[0]);
}

pub fn replace(L: *lua.State, idx: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_replace(@ptrCast(L), idx);
    }
    api_checknelems(L, 1);
    lgc.Cthreadbarrier(L);
    const o = index2addr(L, idx);
    api_checkvalidindex(L, o);
    switch (idx) {
        lua.ENVIRONINDEX => {
            api_check(L, L.ci != L.base_ci);
            const func = L.curr_func();
            api_check(L, (L.top - 1)[0].ttistable());
            func.env = (L.top - 1)[0].hvalue();
            lgc.Cbarrier(L, @ptrCast(@alignCast(func)), @ptrCast(L.top - 1));
        },
        lua.GLOBALSINDEX => {
            api_check(L, (L.top - 1)[0].ttistable());
            L.gt = (L.top - 1)[0].hvalue();
        },
        else => {
            o.setobj(L, @ptrCast(L.top - 1));
            if (idx < lua.GLOBALSINDEX) // function upvalue?
                lgc.Cbarrier(L, @ptrCast(@alignCast(L.curr_func())), @ptrCast(L.top - 1));
        },
    }
    L.top -= 1;
}

pub fn pushvalue(L: *lua.State, idx: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushvalue(@ptrCast(L), idx);
    }
    lgc.Cthreadbarrier(L);
    const o = index2addr(L, idx);
    L.top[0].setobj(L, o);
    api_incr_top(L);
}

//
// access functions (stack -> C)
//

pub fn @"type"(L: *lua.State, idx: i32) i32 {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_type(@ptrCast(L), idx);
    }
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
    if (comptime !build_config.use_zig_backend) {
        return @enumFromInt(c.lua_type(@ptrCast(L), idx));
    }
    return index2addr(L, idx).typeOf();
}

pub fn typename(t: lua.Type) [:0]const u8 {
    return if (t == .None) "no value" else ltm.typenames[@intCast(@intFromEnum(t))];
}

pub fn iscfunction(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_iscfunction(@ptrCast(L), idx) != 0;
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.iscfunction();
}

pub fn isLfunction(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_isLfunction(@ptrCast(L), idx) != 0;
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.isLfunction();
}

pub fn isnumber(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_isnumber(@ptrCast(L), idx) != 0;
    }
    var n: lobject.TValue = undefined;
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.ttisnumber() and lvmutils.Vtonumber(o, &n) != null;
}

pub fn isstring(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_isstring(@ptrCast(L), idx) != 0;
    }
    const t = @"type"(L, idx);
    return t == @intFromEnum(lua.Type.String) or t == @intFromEnum(lua.Type.Number);
}

pub fn isuserdata(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_isuserdata(@ptrCast(L), idx) != 0;
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return o.ttisuserdata() or o.ttislightuserdata();
}

pub fn rawequal(L: *lua.State, index1: i32, index2: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_rawequal(@ptrCast(L), index1, index2) != 0;
    }
    const o1 = index2addr(L, index1);
    const o2 = index2addr(L, index2);
    return if (o1 == lobject.Onilobject or o2 == lobject.Onilobject) false else lobject.OrawequalObj(o1, o2);
}

pub inline fn equal(L: *lua.State, index1: i32, index2: i32) !bool {
    return c.lua_equal(@ptrCast(L), index1, index2) != 0;
    // const o1 = index2addr(L, index1);
    // const o2 = index2addr(L, index2);
    // return if (o1 == lobject.Onilobject or o2 == lobject.Onilobject) false else lvm.equalobj(L, o1, o2);
}

pub inline fn lessthan(L: *lua.State, index1: i32, index2: i32) !bool {
    return c.lua_lessthan(@ptrCast(L), index1, index2) != 0;
}

pub fn tonumberx(L: *lua.State, idx: i32) ?f64 {
    if (comptime !build_config.use_zig_backend) {
        var isnum: i32 = 0;
        const v = c.lua_tonumberx(@ptrCast(L), idx, &isnum);
        if (isnum != 0)
            return v;
        return null;
    }
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
    if (comptime !build_config.use_zig_backend) {
        var isnum: i32 = 0;
        const v = c.lua_tointegerx(@ptrCast(L), idx, &isnum);
        if (isnum != 0)
            return v;
        return null;
    }
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
    if (comptime !build_config.use_zig_backend) {
        var isnum: i32 = 0;
        const v = c.lua_tounsignedx(@ptrCast(L), idx, &isnum);
        if (isnum != 0)
            return v;
        return null;
    }
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
    if (comptime !build_config.use_zig_backend) {
        return c.lua_toboolean(@ptrCast(L), idx) != 0;
    }
    const o = index2addr(L, idx);
    return !o.l_isfalse();
}

pub fn tolstring(L: *lua.State, idx: i32) ?[:0]const u8 {
    if (comptime !build_config.use_zig_backend) {
        var len: usize = 0;
        return if (c.lua_tolstring(@ptrCast(L), idx, &len)) |str| str[0..len :0] else null;
    }
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
    if (comptime !build_config.use_zig_backend) {
        var len: usize = 0;
        var atomptr: c_int = 0;
        return if (c.lua_tolstringatom(@ptrCast(L), idx, &len, &atomptr)) |str| {
            if (atom) |a|
                a.* = @intCast(atomptr);
            return str[0..len :0];
        } else null;
    }
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
    if (comptime !build_config.use_zig_backend) {
        var atomptr: c_int = 0;
        return if (c.lua_namecallatom(@ptrCast(L), &atomptr)) |str| {
            if (atom) |a|
                a.* = @intCast(atomptr);
            return std.mem.span(str);
        } else null;
    }
    const s = L.namecall orelse return null;
    if (atom) |a| {
        updateatom(L, s);
        a.* = s.atom;
    }
    return s.toSlice();
}

pub fn namecallstr(L: *lua.State) ?[]const u8 {
    if (comptime !build_config.use_zig_backend) {
        return if (c.lua_namecallatom(@ptrCast(L), null)) |str| std.mem.span(str) else null;
    }
    const s = L.namecall;
    if (s) |str|
        return str.toSlice();
    return null;
}

pub fn tovector(L: *lua.State, idx: i32) ?[]const f32 {
    if (comptime !build_config.use_zig_backend) {
        return if (c.lua_tovector(@ptrCast(L), idx)) |vec| vec[0..lua.config.VECTOR_SIZE] else null;
    }
    const o = index2addr(L, idx);
    return if (!o.ttisvector())
        null
    else
        o.vvalue();
}

pub fn objlen(L: *lua.State, idx: i32) usize {
    if (comptime !build_config.use_zig_backend) {
        return @intCast(c.lua_objlen(@ptrCast(L), idx));
    }
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
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_tocfunction(@ptrCast(L), idx)));
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.iscfunction())
        null
    else
        o.clvalue().d.c.f;
}

pub fn tolightuserdata(L: *lua.State, comptime T: type, idx: i32) ?*T {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_tolightuserdata(@ptrCast(L), idx)));
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttislightuserdata())
        null
    else
        @ptrCast(@alignCast(o.pvalue()));
}

pub fn tolightuserdatatagged(L: *lua.State, comptime T: type, idx: i32, tag: i32) ?*T {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_tolightuserdatatagged(@ptrCast(L), idx, @intCast(tag))));
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttislightuserdata() or o.lightuserdatatag() != tag)
        null
    else
        @ptrCast(@alignCast(o.pvalue()));
}

pub fn touserdata(L: *lua.State, comptime T: type, idx: i32) ?*T {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_touserdata(@ptrCast(L), idx)));
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    if (o.ttisuserdata())
        return @ptrCast(@alignCast(&o.uvalue().data))
    else if (o.ttislightuserdata())
        return @ptrCast(@alignCast(o.pvalue()))
    else
        return null;
}

pub fn touserdatatagged(L: *lua.State, comptime T: type, idx: i32, tag: u8) ?*T {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_touserdatatagged(@ptrCast(L), idx, @intCast(tag))));
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttisuserdata() or o.uvalue().tag != tag)
        null
    else
        @ptrCast(@alignCast(&o.uvalue().data));
}

pub fn userdatatag(L: *lua.State, idx: i32) ?u8 {
    if (comptime !build_config.use_zig_backend) {
        const tag = c.lua_userdatatag(@ptrCast(L), idx);
        return if (tag >= 0) @intCast(tag) else null;
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (o.ttisuserdata())
        @intCast(o.uvalue().tag)
    else
        null;
}

pub fn lightuserdatatag(L: *lua.State, idx: i32) ?u8 {
    if (comptime !build_config.use_zig_backend) {
        const tag = c.lua_lightuserdatatag(@ptrCast(L), idx);
        return if (tag >= 0) @intCast(tag) else null;
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (o.ttislightuserdata())
        o.lightuserdatatag()
    else
        null;
}

pub fn tothread(L: *lua.State, idx: i32) ?*lua.State {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_tothread(@ptrCast(L), idx)));
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    return if (!o.ttisthread())
        null
    else
        o.thvalue();
}

pub fn tobuffer(L: *lua.State, idx: i32) ?[]u8 {
    if (comptime !build_config.use_zig_backend) {
        var len: usize = 0;
        return if (c.lua_tobuffer(@ptrCast(L), idx, &len)) |buf| @as([*]u8, @ptrCast(@alignCast(buf)))[0..len] else null;
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    if (!o.ttisbuffer())
        return null;
    const b = o.bufvalue();
    return @as([*]u8, @ptrCast(&b.data))[0..@intCast(b.len)];
}

pub fn topointer(L: *lua.State, idx: i32) ?*const anyopaque {
    if (comptime !build_config.use_zig_backend) {
        return if (c.lua_topointer(@ptrCast(L), idx)) |ptr| ptr else null;
    }
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
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushnil(@ptrCast(L));
    }
    L.top[0].setnilvalue();
    api_incr_top(L);
}

pub fn pushnumber(L: *lua.State, n: f64) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushnumber(@ptrCast(L), n);
    }
    L.top[0].setnvalue(n);
    api_incr_top(L);
}

pub fn pushinteger(L: *lua.State, n: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushinteger(@ptrCast(L), n);
    }
    L.top[0].setnvalue(@floatFromInt(n));
    api_incr_top(L);
}

pub fn pushunsigned(L: *lua.State, n: u32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushunsigned(@ptrCast(L), n);
    }
    L.top[0].setnvalue(@floatFromInt(n));
    api_incr_top(L);
}

pub fn pushvector(L: *lua.State, x: f32, y: f32, z: f32, w: ?f32) void {
    if (comptime !build_config.use_zig_backend) {
        if (comptime lua.config.VECTOR_SIZE == 4)
            @compileError("use zig backend for 4D vectors");
        return c.lua_pushvector(@ptrCast(L), x, y, z);
    }
    L.top[0].setvvalue(x, y, z, w);
    api_incr_top(L);
}

pub fn pushlstring(L: *lua.State, s: []const u8) Errorset.Table!void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushlstring(@ptrCast(L), s.ptr, s.len);
    }
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    L.top[0].setsvalue(L, try lstring.Snewlstr(L, s));
    api_incr_top(L);
}

pub inline fn pushstring(L: *lua.State, str: ?[:0]const u8) Errorset.Table!void {
    if (str) |s| {
        try pushlstring(L, std.mem.span(@as([*c]const u8, @ptrCast(s.ptr))));
    } else pushnil(L);
}

pub fn pushvfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) Errorset.Table!void {
    try lobject.Opushvfstring(L, fmt, args);
}
pub inline fn pushfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) Errorset.Table!void {
    try pushvfstring(L, fmt, args);
}

pub fn pushcclosurek(
    L: *lua.State,
    f: lua.CFunction,
    debugname: [:0]const u8,
    nup: u8,
    cont: ?lua.Continuation,
) Errorset.Table!void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushcclosurek(@ptrCast(L), @ptrCast(@alignCast(f)), debugname, nup, @ptrCast(@alignCast(cont)));
    }
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    api_checknelems(L, nup);
    const cl = try lfunc.FnewCclosure(L, nup, getcurrenv(L));
    cl.d.c.f = f;
    cl.d.c.cont = cont;
    cl.d.c.debugname = debugname;
    L.top -= nup;
    var n: u8 = nup;
    while (n > 0) : (n -= 1) {
        const nu = n - 1;
        cl.d.c.upvalues()[nu].setobj(L, @ptrCast(L.top + nu));
    }
    L.top[0].setclvalue(L, cl);
    std.debug.assert(lgc.iswhite(cl.obj2gco()));
    api_incr_top(L);
}
pub inline fn pushcfunction(L: *lua.State, f: lua.CFunction, debugname: [:0]const u8) Errorset.Table!void {
    try pushcclosurek(L, f, debugname, 0, null);
}
pub inline fn pushcclosure(L: *lua.State, f: lua.CFunction, debugname: [:0]const u8, nup: u8) Errorset.Table!void {
    try pushcclosurek(L, f, debugname, nup, null);
}

pub fn pushboolean(L: *lua.State, b: bool) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushboolean(@ptrCast(L), if (b) 1 else 0);
    }
    L.top[0].setbvalue(b);
    api_incr_top(L);
}

pub fn pushlightuserdatatagged(L: *lua.State, p: ?*anyopaque, tag: u8) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushlightuserdatatagged(@ptrCast(L), p, @intCast(tag));
    }
    api_check(L, tag < lua.config.LUTAG_LIMIT);
    L.top[0].setpvalue(p, tag);
    api_incr_top(L);
}
pub inline fn pushlightuserdata(L: *lua.State, p: ?*anyopaque) void {
    pushlightuserdatatagged(L, p, 0);
}

pub fn pushthread(L: *lua.State) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_pushthread(@ptrCast(L)) != 0;
    }
    lgc.Cthreadbarrier(L);
    L.top[0].setthvalue(L, L);
    api_incr_top(L);
    return L.global.mainthread == L;
}

//
// get functions (Lua -> stack)
//

pub inline fn gettable(L: *lua.State, idx: i32) !lua.Type {
    return @enumFromInt(c.lua_gettable(@ptrCast(L), idx));
}

pub inline fn getfield(L: *lua.State, idx: i32, k: [:0]const u8) !lua.Type {
    return @enumFromInt(c.lua_getfield(@ptrCast(L), idx, k.ptr));
}
pub inline fn getglobal(L: *lua.State, k: [:0]const u8) !lua.Type {
    return getfield(L, lua.GLOBALSINDEX, k);
}

pub fn rawgetfield(L: *lua.State, idx: i32, k: []const u8) lua.Type {
    if (comptime !build_config.use_zig_backend) {
        // small static buffer for field because the 'k' type
        // does not require a zero sentinel, but the C api does.
        var static: [256:0]u8 = undefined;
        if (k.len > static.len)
            @panic("key too long, use zig backend");
        @memcpy(static[0..k.len], k);
        static[k.len] = 0;
        return @enumFromInt(c.lua_rawgetfield(@ptrCast(L), idx, &static));
    }
    lgc.Cthreadbarrier(L);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    var ttype: lua.Type = .Nil;
    if (lstring.Sassumelstr(L, k)) |ts| {
        const o = ltable.Hgetstr(t.hvalue(), ts);
        L.top[0].setobj(L, ltable.Hgetstr(t.hvalue(), ts));
        ttype = o.typeOf();
    } else L.top[0].setobj(L, lobject.Onilobject);
    api_incr_top(L);
    return ttype;
}
pub inline fn rawgetglobal(L: *lua.State, k: []const u8) lua.Type {
    return rawgetfield(L, lua.GLOBALSINDEX, k);
}

/// get value from table value at `idx`
/// * gets value from index at `top`
/// * stores value at `top`
/// * expects value at `idx` to be *table*
pub fn rawget(L: *lua.State, idx: i32) lua.Type {
    if (comptime !build_config.use_zig_backend) {
        return @enumFromInt(c.lua_rawget(@ptrCast(L), idx));
    }
    lgc.Cthreadbarrier(L);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    (L.top - 1)[0].setobj(L, ltable.Hget(t.hvalue(), @ptrCast(L.top - 1)));
    return (L.top - 1)[0].typeOf();
}

/// get value from table value at `idx` with number key `n`
/// * pushes value to stack
/// * expects value at `idx` to be *table*
pub fn rawgeti(L: *lua.State, idx: i32, n: i32) lua.Type {
    if (comptime !build_config.use_zig_backend) {
        return @enumFromInt(c.lua_rawgeti(@ptrCast(L), idx, n));
    }
    lgc.Cthreadbarrier(L);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    L.top[0].setobj(L, ltable.Hgetnum(t.hvalue(), n));
    api_incr_top(L);
    return (L.top - 1)[0].typeOf();
}
pub inline fn getref(L: *State, idx: i32) lua.Type {
    return rawgeti(L, lua.REGISTRYINDEX, idx);
}

/// create a new table and push it to the stack
pub fn createtable(L: *lua.State, narray: u32, nrec: u32) !void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_createtable(@ptrCast(L), @intCast(narray), @intCast(nrec));
    }
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    L.top[0].sethvalue(L, try ltable.Hnew(L, narray, nrec));
    api_incr_top(L);
}
/// create a new table and push it to the stack
pub inline fn newtable(L: *lua.State) !void {
    try createtable(L, 0, 0);
}

/// set readonly flag for table at `idx`
pub fn setreadonly(L: *lua.State, idx: i32, enabled: bool) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_setreadonly(@ptrCast(L), idx, if (enabled) 1 else 0);
    }
    const o = index2addr(L, idx);
    api_check(L, o.ttistable());
    const t = o.hvalue();
    api_check(L, t != L.registry().hvalue());
    t.readonly = if (enabled) 1 else 0;
}

/// get readonly flag for table at `idx`
pub fn getreadonly(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_getreadonly(@ptrCast(L), idx) != 0;
    }
    const o: *const lobject.TValue = index2addr(L, idx);
    api_check(L, o.ttistable());
    return o.hvalue().readonly != 0;
}

/// set safeenv flag for table at `idx`
pub fn setsafeenv(L: *lua.State, idx: i32, enabled: bool) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_setsafeenv(@ptrCast(L), idx, if (enabled) 1 else 0);
    }
    const o = index2addr(L, idx);
    api_check(L, o.ttistable());
    o.hvalue().safeenv = if (enabled) 1 else 0;
}

/// get metatable from `idx`
/// * returns **true** if metatable is found
///   * pushes metatable to stack
pub fn getmetatable(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_getmetatable(@ptrCast(L), idx) != 0;
    }
    lgc.Cthreadbarrier(L);
    var mt: ?*lobject.LuaTable = null;
    const o: *const lobject.TValue = index2addr(L, idx);
    switch (o.tt) {
        @intFromEnum(lua.Type.Table) => mt = o.hvalue().metatable,
        @intFromEnum(lua.Type.Userdata) => mt = o.uvalue().metatable,
        else => mt = L.global.mt[@intCast(o.tt)],
    }
    if (mt) |ptr| {
        L.top[0].sethvalue(L, ptr);
        api_incr_top(L);
    }
    return mt != null;
}

pub fn getfenv(L: *lua.State, idx: i32) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_getfenv(@ptrCast(L), idx);
    }
    lgc.Cthreadbarrier(L);
    const o: *const lobject.TValue = index2addr(L, idx);
    api_checkvalidindex(L, o);
    switch (o.tt) {
        @intFromEnum(lua.Type.Function) => L.top[0].sethvalue(L, o.clvalue().env),
        @intFromEnum(lua.Type.Thread) => L.top[0].sethvalue(L, o.thvalue().gt.?),
        else => L.top[0].setnilvalue(),
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
/// <not recommended> use `rawset` instead
pub inline fn settable(L: *lua.State, idx: i32) !void {
    c.lua_settable(@ptrCast(L), idx);
}

/// set table value at `idx` with value:**top** and `k`
/// * pops **top**
/// * throws lua error if *table* is readonly
/// <not recommended> use `rawsetfield` instead
pub inline fn setfield(L: *lua.State, idx: i32, k: [:0]const u8) !void {
    c.lua_setfield(@ptrCast(L), idx, k.ptr);
}
pub inline fn setglobal(L: *lua.State, k: [:0]const u8) !void {
    try setfield(L, lua.GLOBALSINDEX, k);
}

/// set table value at `idx` with value:**top** and `k`
/// ignoring metamethods.
/// * pops **top**
pub fn rawsetfield(L: *lua.State, idx: i32, k: []const u8) Errorset.Table!void {
    if (comptime !build_config.use_zig_backend) {
        // small static buffer for field because the 'k' type
        // does not require a zero sentinel, but the C api does.
        var static: [256:0]u8 = undefined;
        if (k.len > static.len)
            @panic("key too long, use zig backend");
        @memcpy(static[0..k.len], k);
        static[k.len] = 0;
        return c.lua_rawsetfield(@ptrCast(L), idx, &static);
    }
    api_checknelems(L, 1);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    if (t.hvalue().readonly != 0)
        return Errorset.TableReadonly;
    (try ltable.Hsetstr(L, t.hvalue(), try lstring.Snew(L, k))).setobj(L, @ptrCast(L.top - 1));
    lgc.Cbarriert(L, t.hvalue(), @ptrCast(L.top - 1));
    L.top -= 1;
}
pub inline fn rawsetglobal(L: *lua.State, k: []const u8) !void {
    return rawsetfield(L, lua.GLOBALSINDEX, k);
}

/// set table value at `idx` with value:**top** and key:**top-1**
/// ignoring metamethods.
/// * pops **top** x2
/// * returns error "readonly" if *table* is readonly
/// * returns error index if key is *nil*/*NaN*/*NaN vector*
pub fn rawset(L: *lua.State, idx: i32) Errorset.Table!void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_rawset(@ptrCast(L), idx);
    }
    api_checknelems(L, 2);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    if (t.hvalue().readonly != 0)
        return Errorset.TableReadonly;
    (try ltable.Hset(L, t.hvalue(), @ptrCast(L.top - 2))).setobj(L, @ptrCast(L.top - 1));
    lgc.Cbarriert(L, t.hvalue(), @ptrCast(L.top - 1));
    L.top -= 2;
}

/// set table value at `idx` with **top**
/// ignoring metamethods.
/// * pops **top**
/// * throws lua error if *table* is readonly
pub fn rawseti(L: *lua.State, idx: i32, n: i32) Errorset.Table!void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_rawseti(@ptrCast(L), idx, n);
    }
    api_checknelems(L, 2);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    if (t.hvalue().readonly != 0)
        return Errorset.TableReadonly;
    (try ltable.Hsetnum(L, t.hvalue(), n)).setobj(L, @ptrCast(L.top - 1));
    lgc.Cbarriert(L, t.hvalue(), @ptrCast(L.top - 1));
    L.top -= 1;
}

/// set metatable for `idx` with **top**
/// * pops **top**
/// * expects **top** to be *table* or *nil*
/// * always returns `1`
pub fn setmetatable(L: *lua.State, idx: i32) Errorset.Table!u1 {
    if (comptime !build_config.use_zig_backend) {
        return @intCast(c.lua_setmetatable(@ptrCast(L), idx));
    }
    api_checknelems(L, 1);
    const obj = index2addr(L, idx);
    api_checkvalidindex(L, obj);
    var mt: ?*lobject.LuaTable = null;
    if (!(L.top - 1)[0].ttisnil()) {
        api_check(L, (L.top - 1)[0].ttistable());
        mt = (L.top - 1)[0].hvalue();
    }
    switch (obj.ttype()) {
        @intFromEnum(lua.Type.Table) => {
            if (obj.hvalue().readonly != 0)
                return Errorset.TableReadonly;
            obj.hvalue().metatable = mt;
            if (mt) |m|
                lgc.Cobjbarrier(L, @ptrCast(@alignCast(obj.hvalue())), @ptrCast(@alignCast(m)));
        },
        @intFromEnum(lua.Type.Userdata) => {
            obj.uvalue().metatable = mt;
            if (mt) |m|
                lgc.Cobjbarrier(L, @ptrCast(@alignCast(obj.uvalue())), @ptrCast(@alignCast(m)));
        },
        else => L.global.mt[@intCast(obj.ttype())] = mt,
    }
    L.top -= 1;
    return 1;
}

pub fn setfenv(L: *lua.State, idx: i32) bool {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_setfenv(@ptrCast(L), idx) != 0;
    }
    api_checknelems(L, 1);
    const o = index2addr(L, idx);
    api_checkvalidindex(L, o);
    api_check(L, (L.top - 1)[0].ttistable());
    defer L.top -= 1;
    switch (o.tt) {
        @intFromEnum(lua.Type.Function) => o.clvalue().env = (L.top - 1)[0].hvalue(),
        @intFromEnum(lua.Type.Thread) => o.thvalue().gt = (L.top - 1)[0].hvalue(),
        else => return false,
    }
    lgc.Cobjbarrier(L, @ptrCast(@alignCast(&o.gcvalue().gch)), @ptrCast(L.top - 1));
    return true;
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

pub fn status(L: *lua.State) lua.Status {
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
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_getthreaddata(@ptrCast(L))));
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
    if (comptime !build_config.use_zig_backend) {
        return c.lua_setthreaddata(@ptrCast(L), @ptrCast(@alignCast(data)));
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
    if (comptime !build_config.use_zig_backend) {
        return c.lua_error(@ptrCast(L));
    }
    api_checknelems(L, 1);
    ldo.throw(L, .ErrRun);
    unreachable;
}

pub fn next(L: *lua.State, idx: i32) !bool {
    return c.lua_next(@ptrCast(L), idx) != 0;
}

pub fn rawiter(L: *lua.State, idx: i32, _iter: i32) i32 {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_rawiter(@ptrCast(L), idx, _iter);
    }
    std.debug.assert(_iter >= 0);
    var iter: usize = @intCast(_iter);
    lgc.Cthreadbarrier(L);
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    api_check(L, iter >= 0);

    const h = t.hvalue();
    const sizearray: usize = @intCast(h.sizearray);

    // first we advance iter through the array portion
    while (iter < sizearray) : (iter += 1) {
        const e = &h.array.?[iter];

        if (!e.ttisnil()) {
            const top = L.top;
            top[0].setnvalue(@floatFromInt(iter + 1));
            top[1].setobj(L, e);
            api_update_top(L, &top[2]);
            return @intCast(iter + 1);
        }
    }

    const sizenode = lobject.sizenode(h);

    // then we advance iter through the hash portion
    while (iter - sizearray < sizenode) : (iter += 1) {
        const n = &h.node[iter - sizearray];

        if (!n.gval().ttisnil()) {
            const top = L.top;
            lobject.getnodekey(L, @ptrCast(top), n);
            top[1].setobj(L, n.gval());
            api_update_top(L, &top[2]);
            return @intCast(iter + 1);
        }
    }

    // traversal finished
    return -1;
}

pub inline fn concat(L: *lua.State, idx: i32) !void {
    c.lua_concat(@ptrCast(L), idx);
}

pub fn newuserdatatagged(L: *lua.State, comptime T: type, tag: u8) Errorset.Table!*T {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_newuserdatatagged(@ptrCast(L), @sizeOf(T), @intCast(tag)).?));
    }
    api_check(L, tag < lua.config.UTAG_LIMIT or tag == ludata.UTAG_PROXY);
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const u = try ludata.Unewudata(L, @sizeOf(T), tag);
    L.top[0].setuvalue(L, u);
    api_incr_top(L);
    return @ptrCast(@alignCast(&u.data));
}
pub inline fn newuserdata(L: *lua.State, comptime T: type) Errorset.Table!*T {
    return newuserdatatagged(L, T, 0);
}

pub fn newuserdatataggedwithmetatable(L: *lua.State, comptime T: type, tag: u8) Errorset.Table!*T {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_newuserdatataggedwithmetatable(@ptrCast(L), @sizeOf(T), @intCast(tag)).?));
    }
    api_check(L, tag < lua.config.UTAG_LIMIT);
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const u = try ludata.Unewudata(L, @sizeOf(T), tag);

    // currently, we always allocate unmarked objects, so forward barrier can be skipped
    std.debug.assert(!lgc.isblack(u.obj2gco()));

    const h = L.global.udatamt[tag];
    api_check(L, h != null);

    u.metatable = h;

    L.top[0].setuvalue(L, u);
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
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_newuserdatadtor(@ptrCast(L), sz, dtor).?));
    }

    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    // make sure sz + sizeof(dtor) doesn't overflow; luaU_newdata will reject SIZE_MAX correctly
    const as = if (sz < std.math.maxInt(usize) - @sizeOf(@TypeOf(dtor))) sz + @sizeOf(@TypeOf(dtor)) else std.math.maxInt(usize);
    const u = try ludata.Unewudata(L, as, ludata.UTAG_IDTOR);
    @memcpy(@as([*]u8, &u.data)[sz..], &@as([@sizeOf(usize)]u8, @bitCast(@intFromPtr(dtor))));
    L.top[0].setuvalue(L, u);
    api_incr_top(L);
    return @ptrCast(@alignCast(&u.data));
}

pub fn newbuffer(L: *lua.State, sz: usize) Errorset.Table![]u8 {
    if (comptime !build_config.use_zig_backend) {
        return @as([*]u8, @ptrCast(@alignCast(c.lua_newbuffer(@ptrCast(L), sz).?)))[0..sz];
    }
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const b = try lbuffer.Bnewbuffer(L, sz);
    L.top[0].setbufvalue(L, b);
    api_incr_top(L);
    return @as([*]u8, @ptrCast(@alignCast(&b.data)))[0..sz];
}

fn aux_upvalue(fi: *lobject.TValue, n: u32, val: **lobject.TValue) ?[:0]const u8 {
    if (!fi.ttisfunction())
        return null;
    const f = fi.clvalue();
    if (f.isC != 0) {
        if (!(1 <= n and n <= f.nupvalues))
            return null;
        val.* = &f.d.c.upvalues()[n - 1];
        return "";
    } else {
        const p = f.d.l.p;
        if (!(1 <= n and n <= p.nups)) // not a valid upvalue
            return null;
        const r = &f.d.l.upreferences()[n - 1];
        val.* = if (r.ttisupval()) r.upvalue().v else r;
        if (!(1 <= n and n <= p.sizeupvalues)) // don't have a name for this upvalue
            return "";
        return p.upvalues.?[n - 1].?.toSlice();
    }
}

pub fn getupvalue(L: *lua.State, funcindex: i32, n: u32) ?[:0]const u8 {
    if (comptime !build_config.use_zig_backend) {
        const name = c.lua_getupvalue(@ptrCast(L), funcindex, @intCast(n));
        if (name != null)
            return std.mem.span(name);
        return null;
    }
    lgc.Cthreadbarrier(L);
    var val: *lobject.TValue = undefined;
    if (aux_upvalue(index2addr(L, funcindex), n, &val)) |name| {
        L.top[0].setobj(L, val);
        api_incr_top(L);
        return name;
    } else return null;
}

pub fn setupvalue(L: *lua.State, funcidx: i32, n: u32) ?[:0]const u8 {
    if (comptime !build_config.use_zig_backend) {
        const name = c.lua_setupvalue(@ptrCast(L), funcidx, @intCast(n));
        if (name != null)
            return std.mem.span(name);
        return null;
    }
    api_checknelems(L, 1);
    const fi = index2addr(L, funcidx);
    var val: *lobject.TValue = undefined;
    if (aux_upvalue(fi, n, &val)) |name| {
        L.top -= 1;
        val.setobj(L, @ptrCast(L.top));
        lgc.Cbarrier(L, @ptrCast(@alignCast(fi.clvalue())), @ptrCast(L.top));
        return name;
    } else return null;
}

pub fn encodepointer(L: *lua.State, p: usize) usize {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_encodepointer(@ptrCast(L), p);
    }
    const g = L.global;
    return @intCast(g.ptrenckey[0] * p + g.ptrenckey[2] ^ (g.ptrenckey[1] * p + g.ptrenckey[3]));
}

pub fn ref(L: *lua.State, idx: i32) Errorset.Table!?i32 {
    if (comptime !build_config.use_zig_backend) {
        const r = c.lua_ref(@ptrCast(L), idx);
        if (r == lua.REFNIL)
            return null;
        return @intCast(r);
    }
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
    if (comptime !build_config.use_zig_backend) {
        return c.lua_unref(@ptrCast(L), r);
    }
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
    if (comptime !build_config.use_zig_backend) {
        return c.lua_setuserdatatag(@ptrCast(L), idx, @intCast(tag));
    }
    api_check(L, tag < lua.config.UTAG_LIMIT);
    const o = index2addr(L, idx);
    api_check(L, o.ttisuserdata());
    o.uvalue().tag = tag;
}

pub fn setuserdatadtor(L: *lua.State, comptime T: type, tag: u8, comptime dtorfn: ?*const fn (L: *lua.State, ptr: *T) void) void {
    const dtor: ?*const fn (L: *lua.State, ptr: ?*anyopaque) callconv(.c) void = if (dtorfn) |dtor| struct {
        fn inner(state: *lua.State, ptr: ?*anyopaque) callconv(.c) void {
            @call(.always_inline, dtor, .{
                state,
                @as(*T, @ptrCast(@alignCast(ptr.?))),
            });
        }
    }.inner else null;
    if (comptime !build_config.use_zig_backend) {
        return c.lua_setuserdatadtor(@ptrCast(L), @intCast(tag), @ptrCast(@alignCast(dtor)));
    }
    api_check(L, tag < lua.config.UTAG_LIMIT);
    L.global.udatagc[tag] = dtor;
}

pub fn getuserdatadtor(L: *lua.State, tag: u8) ?lua.Destructor {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_getuserdatadtor(@ptrCast(L), @intCast(tag))));
    }
    api_check(L, tag < lua.config.UTAG_LIMIT);
    return L.global.udatagc[tag];
}

pub fn setuserdatametatable(L: *lua.State, tag: u8) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_setuserdatametatable(@ptrCast(L), @intCast(tag));
    }
    api_check(L, tag < lua.config.UTAG_LIMIT);
    api_check(L, L.global.udatamt[tag] == null); // reassignment not supported
    const n = L.top - 1;
    api_check(L, n[0].ttistable());
    L.global.udatamt[tag] = n[0].hvalue();
    L.top = n;
}

pub fn getuserdatametatable(L: *lua.State, tag: u8) void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_getuserdatametatable(@ptrCast(L), @intCast(tag));
    }
    api_check(L, tag < lua.config.UTAG_LIMIT);
    lgc.Cthreadbarrier(L);

    if (L.global.udatamt[tag]) |h|
        L.top[0].sethvalue(L, h)
    else
        L.top[0].setnilvalue();

    api_incr_top(L);
}

pub fn setlightuserdataname(L: *lua.State, tag: u8, name: []const u8) Errorset.Memory!void {
    if (comptime !build_config.use_zig_backend) {
        // small static buffer for name because the 'name' type
        // does not require a zero sentinel, but the C api does.
        var static: [256:0]u8 = undefined;
        if (name.len > static.len)
            @panic("name too long, use zig backend");
        @memcpy(static[0..name.len], name);
        static[name.len] = 0;
        return c.lua_setlightuserdataname(@ptrCast(L), @intCast(tag), &static);
    }
    api_check(L, tag < lua.config.LUTAG_LIMIT);
    api_check(L, L.global.lightuserdataname[tag] == null); // renaming not supported
    L.global.lightuserdataname[tag] = try lstring.Snew(L, name);
    lstring.Sfix(L.global.lightuserdataname[tag].?); // never collect these names
}

pub fn getlightuserdataname(L: *lua.State, tag: u8) ?[:0]const u8 {
    if (comptime !build_config.use_zig_backend) {
        const name = c.lua_getlightuserdataname(@ptrCast(L), @intCast(tag));
        if (name != null)
            return std.mem.span(name);
        return null;
    }
    api_check(L, tag < lua.config.LUTAG_LIMIT);
    const name = L.global.lightuserdataname[tag];
    return if (name) |s|
        s.toSlice()
    else
        null;
}

pub fn clonefunction(L: *lua.State, idx: i32) !void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_clonefunction(@ptrCast(L), idx);
    }
    try lgc.CcheckGC(L);
    lgc.Cthreadbarrier(L);
    const p = index2addr(L, idx);
    api_check(L, p.isLfunction());
    const cl = p.clvalue();
    const newcl = try lfunc.FnewLclosure(L, cl.nupvalues, L.gt.?, cl.d.l.p);
    for (0..cl.nupvalues) |i|
        newcl.d.l.upreferences()[i].setobj(L, &cl.d.l.upreferences()[i]);
    L.top[0].setclvalue(L, newcl);
    api_incr_top(L);
}

pub fn cleartable(L: *lua.State, idx: i32) Errorset.Table!void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_cleartable(@ptrCast(L), idx);
    }
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());
    const tt = t.hvalue();
    if (tt.readonly != 0)
        return Errorset.TableReadonly;
    ltable.Hclear(tt);
}

pub fn clonetable(L: *lua.State, idx: i32) Errorset.Table!void {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_clonetable(@ptrCast(L), idx);
    }
    const t = index2addr(L, idx);
    api_check(L, t.ttistable());

    const tt = try ltable.Hclone(L, t.hvalue());
    L.top[0].sethvalue(L, tt);
    api_incr_top(L);
}

pub fn callbacks(L: *lua.State) *lua.Callbacks {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_callbacks(@ptrCast(L))));
    }
    return &L.global.cb;
}

pub fn setmemcat(L: *lua.State, category: u8) void {
    if (comptime !build_config.use_zig_backend) {
        c.lua_setmemcat(@ptrCast(L), @intCast(category));
        return;
    }
    api_check(L, category < lua.config.MEMORY_CATEGORIES);
    L.activememcat = category;
}

pub fn totalbytes(L: *lua.State, category: u8) usize {
    if (comptime !build_config.use_zig_backend) {
        return c.lua_totalbytes(@ptrCast(L), @intCast(category));
    }
    api_check(L, category < lua.config.MEMORY_CATEGORIES);
    return if (category < 0)
        L.global.totalbytes
    else
        L.global.memcatbytes[@intCast(category)];
}

pub fn getallocf(L: *lua.State, ud: ?*?*anyopaque) ?lua.Alloc {
    if (comptime !build_config.use_zig_backend) {
        return @ptrCast(@alignCast(c.lua_getallocf(@ptrCast(L), @ptrCast(ud))));
    }
    const f = L.global.frealloc;
    if (ud) |ptr|
        ptr.* = L.global.ud;
    return f;
}
