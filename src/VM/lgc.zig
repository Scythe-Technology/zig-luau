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
    return test2bits(x.gch.header.marked, WHITE0BIT, WHITE1BIT) != 0;
}
pub inline fn isblack(x: *lstate.GCObject) bool {
    return testbit(x.gch.header.marked, BLACKBIT) != 0;
}
pub inline fn isgray(x: *lstate.GCObject) bool {
    return testbits(x.gch.header.marked, WHITEBITS | bitmask(BLACKBIT)) == 0;
}
pub inline fn isfixed(x: *lstate.GCObject) bool {
    return testbit(x.gch.header.marked, FIXEDBIT) != 0;
}

pub inline fn otherwhite(g: *const lstate.global_State) u8 {
    return g.currentwhite ^ WHITEBITS;
}
pub inline fn isdead(g: *const lstate.global_State, v: *const lstate.GCObject) bool {
    return (v.gch.header.marked & (WHITEBITS | bitmask(FIXEDBIT))) == (otherwhite(g) & WHITEBITS);
}

pub inline fn changewhite(x: *lstate.GCObject) void {
    x.gch.header.marked ^= WHITEBITS;
}

pub inline fn black2gray(x: *lstate.GCObject) void {
    std.debug.assert(isblack(x));
    x.gch.header.marked &= ~(bitmask(BLACKBIT));
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
    if (isblack(@ptrCast(@alignCast(L)))) {
        Cbarrierback(L, @ptrCast(@alignCast(L)), &L.gclist.?);
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
