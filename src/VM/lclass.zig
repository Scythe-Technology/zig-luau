const std = @import("std");

const lua = @import("lua.zig");

const lobject = @import("lobject.zig");

const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");
const ltable = @import("ltable.zig");
const lfunc = @import("lfunc.zig");

const Errorset = @import("errorset.zig");

pub fn Rnewclassobject(
    L: *lua.State,
    name: *lobject.TString,
    memberstooffset: *lobject.LuaTable,
    offsettomember: [*]*lobject.TString,
    numberofinstancemembers: usize,
    numberofstaticmembers: c_int,
) !*lobject.ClassObject {
    std.debug.assert(L.global.GCthreshold == std.math.maxInt(usize)); // GC must be paused
    const classobject = try lmem.Mnewgco(L, lobject.ClassObject, @sizeOf(lobject.ClassObject), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(classobject)), @intFromEnum(lua.Type.ClassObject));
    classobject.name = name;

    classobject.staticmembers = try lmem.Mnewarray(L, lobject.TValue, numberofinstancemembers, classobject.memcat);
    for (0..numberofstaticmembers) |i|
        classobject.staticmembers[i].setnilvalue();

    classobject.memberstooffset = memberstooffset;
    classobject.offsettomember = offsettomember;

    classobject.metatable = try ltable.Hnew(L, 0, 1);

    const constructor = try lfunc.FnewCclosure(L, 0, L.gt);
    constructor.d.c.f = luaR_createclassinstance;
    constructor.d.c.debugname = "luaR_createclassinstance";
    constructor.d.c.cont = null;
    const dest = try ltable.Hsetstr(L, classobject.metatable, L.global.tmname[lua.TM_CALL]);
    std.debug.assert(dest.ttisnil());
    dest.setclvalue(L, constructor);
    classobject.metatable.readonly = 1;

    classobject.numberofinstancemembers = numberofinstancemembers;
    classobject.numberofallmembers = numberofinstancemembers + numberofstaticmembers;

    return classobject;
}

pub fn Raddclassmember(L: *lua.State, classobject: *lobject.ClassObject, name: *lobject.TString, value: *const lobject.TValue) void {
    std.debug.assert(@as(*allowzero anyopaque, @ptrCast(@alignCast(classobject.staticmembers))) != null);
    const offset = ltable.Hgetstr(classobject.memberstooffset, name);
    std.debug.assert(offset.ttisnumber());
    const offsetint: i32 = @intFromFloat(offset.nvalue());
    std.debug.assert(offsetint >= classobject.numberofinstancemembers and offsetint < classobject.numberofallmembers);
    std.debug.assert(value.ttisfunction() and value.value.gc.?.gch.ttype() == @intFromEnum(lua.Type.Function));
    classobject.staticmembers[@as(u32, @intCast(offsetint)) - @as(u32, @intCast(classobject.numberofinstancemembers))].setobj(value);
    lgc.Cbarrier(L, @ptrCast(@alignCast(classobject)), value);
}

extern "c" fn luaR_createclassinstance(L: *lua.State) c_int;

pub fn Rfreeclassobject(L: *lua.State, classobject: *lobject.ClassObject, page: *lmem.lua_Page) void {
    lmem.Mfreearray(L, lobject.TValue, classobject.staticmembers, @intCast(classobject.numberofallmembers - classobject.numberofinstancemembers), classobject.header.memcat);
    lmem.Mfreearray(L, *lobject.TString, classobject.offsettomember, @intCast(classobject.numberofallmembers), classobject.header.memcat);
    lmem.Mfreegco(L, @ptrCast(@alignCast(classobject)), @sizeOf(lobject.ClassObject), classobject.header.memcat, page);
}

pub fn Rfreeclassinstance(L: *lua.State, classinstance: *lobject.ClassInstance, page: *lmem.lua_Page) void {
    lmem.Mfreearray(L, lobject.TValue, classinstance.members, @intCast(classinstance.numberofmembers), classinstance.header.memcat);
    lmem.Mfreegco(L, @ptrCast(@alignCast(classinstance)), @sizeOf(lobject.ClassInstance), classinstance.header.memcat, page);
}
