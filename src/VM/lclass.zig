const std = @import("std");

const lua = @import("lua.zig");

const lobject = @import("lobject.zig");

const lgc = @import("lgc.zig");
const ltm = @import("ltm.zig");
const lmem = @import("lmem.zig");
const ltable = @import("ltable.zig");
const lstring = @import("lstring.zig");
const lfunc = @import("lfunc.zig");

const Errorset = @import("errorset.zig");

pub fn Rnewclass(
    L: *lua.State,
    name: *lobject.TString,
    memberstooffset: *lobject.LuaTable,
    offsettomember: [*]*lobject.TString,
    numberofinstancemembers: usize,
    numberofstaticmembers: u32,
) !*lobject.LuauClass {
    std.debug.assert(L.global.GCthreshold == std.math.maxInt(usize)); // GC must be paused
    const classobject = try lmem.Mnewgco(L, lobject.LuauClass, @sizeOf(lobject.LuauClass), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(classobject)), @intFromEnum(lua.Type.Class));
    classobject.name = name;

    classobject.staticmembers = try lmem.Mnewarray(L, lobject.TValue, numberofinstancemembers, classobject.header.memcat);
    for (0..numberofstaticmembers) |i|
        classobject.staticmembers[i].setnilvalue();

    classobject.memberstooffset = memberstooffset;
    classobject.offsettomember = offsettomember;

    classobject.metatable = try ltable.Hnew(L, 0, 1);

    const constructor = try lfunc.FnewCclosure(L, 0, L.gt.?);
    constructor.d.c.f = zig_luaR_createobject;
    constructor.d.c.debugname = "luaR_createobject";
    constructor.d.c.cont = null;
    const dest = try ltable.Hsetstr(L, classobject.metatable, L.global.tmname[@intFromEnum(ltm.TMS.TM_CALL)]);
    std.debug.assert(dest.ttisnil());
    dest.setclvalue(L, constructor);
    classobject.metatable.readonly = 1;
    classobject.instancemetatable = null;

    classobject.numberofinstancemembers = @intCast(numberofinstancemembers);
    classobject.numberofallmembers = @intCast(numberofinstancemembers + numberofstaticmembers);

    return classobject;
}

pub fn Raddclassmember(L: *lua.State, classobject: *lobject.LuauClass, name: *lobject.TString, value: *const lobject.TValue) !void {
    std.debug.assert(@as(?*anyopaque, @ptrCast(@alignCast(classobject.staticmembers))) != null);
    const offset = ltable.Hgetstr(classobject.memberstooffset, name);
    std.debug.assert(offset.ttisnumber());
    const offsetint: i32 = @intFromFloat(offset.nvalue());
    std.debug.assert(offsetint >= classobject.numberofinstancemembers and offsetint < classobject.numberofallmembers);
    std.debug.assert(value.ttisfunction() and value.value.gc.?.gch.ttype() == @intFromEnum(lua.Type.Function));
    classobject.staticmembers[@as(u32, @intCast(offsetint)) - @as(u32, @intCast(classobject.numberofinstancemembers))].setobj(L, value);
    lgc.Cbarrier(L, @ptrCast(@alignCast(classobject)), value);

    var isMetamethod: bool = name == lstring.Sassumelstr(L, "__tostring");
    var i: u32 = 0;
    while (!isMetamethod and i < ltm.N) : (i += 1)
        isMetamethod = name == L.global.tmname[i];

    if (isMetamethod) {
        if (classobject.instancemetatable == null) {
            classobject.instancemetatable = try ltable.Hnew(L, 0, 1);
            lgc.Cobjbarrier(L, @ptrCast(@alignCast(classobject)), @ptrCast(@alignCast(classobject.instancemetatable.?)));
        }
        const dest = try ltable.Hsetstr(L, classobject.instancemetatable.?, name);
        dest.setobj(L, value);
        lgc.Cbarrier(L, @ptrCast(@alignCast(classobject.instancemetatable.?)), value);
    }
}

extern "c" fn zig_luaR_createobject(L: *lua.State) c_int;

pub fn Rfreeclass(L: *lua.State, classobject: *lobject.LuauClass, page: *lmem.lua_Page) void {
    lmem.Mfreearray(L, lobject.TValue, classobject.staticmembers, @intCast(classobject.numberofallmembers - classobject.numberofinstancemembers), classobject.header.memcat);
    lmem.Mfreearray(L, *lobject.TString, classobject.offsettomember, @intCast(classobject.numberofallmembers), classobject.header.memcat);
    lmem.Mfreegco(L, @ptrCast(@alignCast(classobject)), @sizeOf(lobject.LuauClass), classobject.header.memcat, page);
}

pub fn Rfreeobject(L: *lua.State, classinstance: *lobject.LuauObject, page: *lmem.lua_Page) void {
    lmem.Mfreearray(L, lobject.TValue, classinstance.members, @intCast(classinstance.numberofmembers), classinstance.header.memcat);
    lmem.Mfreegco(L, @ptrCast(@alignCast(classinstance)), @sizeOf(lobject.LuauObject), classinstance.header.memcat, page);
}
