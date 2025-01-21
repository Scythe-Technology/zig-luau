const c = @import("c");
const std = @import("std");

const lgc = @import("lgc.zig");
const lua = @import("lua.zig");
const lstate = @import("lstate.zig");
const config = @import("luaconf.zig");
const lcommon = @import("lcommon.zig");

pub const GCheader = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    pub inline fn ttype(this: *const GCheader) c_int {
        return this.tt;
    }
};

pub const Value = extern union {
    gc: ?*lstate.GCObject,
    p: ?*anyopaque,
    n: f64,
    b: c_int,
    /// v[0], v[1] live here; v[2] lives in TValue::extra
    v: [2]f32,
};

///
/// Tagged Values
///
pub const TValue = extern struct {
    value: Value,
    extra: [config.EXTRA_SIZE]c_int,
    tt: c_int,

    // helper api
    pub inline fn add(this: *TValue, n: void) *TValue {
        return @ptrFromInt(@intFromPtr(this) + n);
    }
    pub inline fn add_num(this: *TValue, n: usize) *TValue {
        return @ptrFromInt(@intFromPtr(this) + (n * @sizeOf(TValue)));
    }
    pub inline fn sub(this: *TValue, ptr: *TValue) usize {
        return @divExact(@intFromPtr(this) - @intFromPtr(ptr), @sizeOf(TValue));
    }
    pub inline fn sub_num(this: *TValue, n: usize) *TValue {
        return @ptrFromInt(@intFromPtr(this) - (n * @sizeOf(TValue)));
    }

    pub inline fn ttype(this: *const TValue) c_int {
        return this.tt;
    }

    pub inline fn typeOf(obj: *const TValue) lua.Type {
        return @enumFromInt(obj.ttype());
    }

    pub inline fn ttisnil(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Nil);
    }
    pub inline fn ttisnumber(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Number);
    }
    pub inline fn ttisstring(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.String);
    }
    pub inline fn ttistable(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Table);
    }
    pub inline fn ttisfunction(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Function);
    }
    pub inline fn ttisboolean(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Boolean);
    }
    pub inline fn ttisuserdata(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Userdata);
    }
    pub inline fn ttisthread(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Thread);
    }
    pub inline fn ttisbuffer(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Buffer);
    }
    pub inline fn ttislightuserdata(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.LightUserdata);
    }
    pub inline fn ttisvector(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Vector);
    }
    pub inline fn ttisupval(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.UpVal);
    }

    pub inline fn gcvalue(obj: *const TValue) *lstate.GCObject {
        std.debug.assert(obj.iscollectable());
        return obj.value.gc.?;
    }
    pub inline fn pvalue(obj: *const TValue) *anyopaque {
        std.debug.assert(obj.ttislightuserdata());
        return obj.value.p.?;
    }
    pub inline fn nvalue(obj: *const TValue) f64 {
        std.debug.assert(obj.ttisnumber());
        return obj.value.n;
    }
    pub inline fn vvalue(obj: *TValue) []const f32 {
        std.debug.assert(obj.ttisvector());
        return @as([*]f32, @ptrCast(&obj.value.v))[0..config.VECTOR_SIZE];
    }
    pub inline fn tsvalue(obj: *const TValue) *TString {
        std.debug.assert(obj.ttisstring());
        return &obj.value.gc.?.ts;
    }
    pub inline fn uvalue(obj: *const TValue) *Udata {
        std.debug.assert(obj.ttisuserdata());
        return &obj.value.gc.?.u;
    }
    pub inline fn clvalue(obj: *const TValue) *Closure {
        std.debug.assert(obj.ttisfunction());
        return &obj.value.gc.?.cl;
    }
    pub inline fn hvalue(obj: *const TValue) *LuaTable {
        std.debug.assert(obj.ttistable());
        return &obj.value.gc.?.h;
    }
    pub inline fn bvalue(obj: *const TValue) bool {
        std.debug.assert(obj.ttisboolean());
        return obj.value.b != 0;
    }
    pub inline fn thvalue(obj: *const TValue) *lstate.lua_State {
        std.debug.assert(obj.ttisthread());
        return &obj.value.gc.?.th;
    }
    pub inline fn bufvalue(obj: *const TValue) *Buffer {
        std.debug.assert(obj.ttisbuffer());
        return &obj.value.gc.?.buf;
    }
    pub inline fn upvalue(obj: *TValue) *UpVal {
        std.debug.assert(obj.ttisupval());
        return &obj.value.gc.?.uv;
    }
    pub inline fn svalue(obj: *const TValue) [*c]const u8 {
        return obj.tsvalue().getstr();
    }

    pub inline fn l_isfalse(obj: *const TValue) bool {
        return obj.ttisnil() or (obj.ttisboolean() and !obj.bvalue());
    }

    pub inline fn lightuserdatatag(obj: *const TValue) c_int {
        std.debug.assert(obj.ttislightuserdata());
        return obj.extra[0];
    }

    pub inline fn checkliveness(obj: *const TValue, g: *const lstate.global_State) void {
        std.debug.assert(!obj.iscollectable() or ((obj.ttype() == obj.value.gc.?.gch.tt) and !lgc.isdead(g, obj.value.gc.?)));
    }

    pub inline fn setnilvalue(obj: *TValue) void {
        obj.settype(.Nil);
    }
    pub inline fn setnvalue(obj: *TValue, x: f64) void {
        obj.value.n = x;
        obj.settype(.Number);
    }
    pub inline fn setvvalue(obj: *TValue, x: f32, y: f32, z: f32, w: ?f32) void {
        const i_v: [*]f32 = @ptrCast(&obj.value.v);
        i_v[0] = x;
        i_v[1] = y;
        i_v[2] = z;
        if (comptime config.VECTOR_SIZE == 4)
            i_v[3] = w orelse 0;
        obj.settype(.Vector);
    }
    pub inline fn setpvalue(obj: *TValue, x: ?*anyopaque, tag: u32) void {
        obj.value.p = x;
        obj.extra[0] = @intCast(tag);
        obj.settype(.LightUserdata);
    }
    pub inline fn setbvalue(obj: *TValue, x: bool) void {
        obj.value.b = if (x) 1 else 0;
        obj.settype(.Boolean);
    }
    pub inline fn setsvalue(obj: *TValue, L: *lstate.lua_State, x: *TString) void {
        obj.value.gc = @ptrCast(x);
        obj.settype(.String);
        obj.checkliveness(L.global);
    }
    pub inline fn setuvalue(obj: *TValue, L: *lstate.lua_State, x: *Udata) void {
        obj.value.gc = @ptrCast(x);
        obj.settype(.Userdata);
        obj.checkliveness(L.global);
    }
    pub inline fn setthvalue(obj: *TValue, L: *lstate.lua_State, x: *lstate.lua_State) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Thread);
        obj.checkliveness(L.global);
    }
    pub inline fn setclvalue(obj: *TValue, L: *lstate.lua_State, x: *Closure) void {
        obj.value.gc = @ptrCast(x);
        obj.settype(.Function);
        obj.checkliveness(L.global);
    }
    pub inline fn sethvalue(obj: *TValue, L: *lstate.lua_State, x: *LuaTable) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Table);
        obj.checkliveness(L.global);
    }
    pub inline fn setptvalue(obj: *TValue, L: *lstate.lua_State, x: *Proto) void {
        obj.value.gc = @ptrCast(x);
        obj.settype(.Proto);
        obj.checkliveness(L.global);
    }
    pub inline fn setupvalue(obj: *TValue, L: *lstate.lua_State, x: *UpVal) void {
        obj.value.gc = @ptrCast(x);
        obj.settype(.UpVal);
        obj.checkliveness(L.global);
    }
    pub inline fn setobj(obj: *TValue, L: *lstate.lua_State, o2: *const TValue) void {
        obj.* = o2.*;
        obj.checkliveness(L.global);
    }

    pub inline fn settype(obj: *TValue, t: lua.Type) void {
        obj.tt = @intFromEnum(t);
    }
    pub inline fn iscollectable(o: *const TValue) bool {
        return o.ttype() >= @intFromEnum(lua.Type.String);
    }

    pub inline fn iscfunction(o: *const TValue) bool {
        return o.ttype() == @intFromEnum(lua.Type.Function) and o.clvalue().isC != 0;
    }
    pub inline fn isLfunction(o: *const TValue) bool {
        return o.ttype() == @intFromEnum(lua.Type.Function) and o.clvalue().isC == 0;
    }
};

pub const LU_TAG_ITERATOR = config.UTAG_LIMIT;

pub inline fn checkliveness() void {}

pub const StkId = *TValue;

pub const TString = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    // 1 byte padding

    atom: i16,

    // 2 byte padding

    /// next string in the hash table bucket
    next: ?*TString,

    hash: c_uint,
    len: c_uint,

    /// string data is allocated right after the header
    data: [1]u8,

    pub inline fn getstr(s: *const TString) [*c]const u8 {
        return @ptrCast(&s.data);
    }
};

pub const Udata = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    tag: u8,

    len: c_int,

    metatable: ?*LuaTable,

    data: extern union {
        /// userdata is allocated right after the header
        data: [1]u8,
        /// ensures maximum alignment for data
        dummy: lcommon.L_Umaxalign,
    },
};

pub const Buffer = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    len: c_int,

    data: extern union {
        /// userdata is allocated right after the header
        data: [1]u8,
        /// ensures maximum alignment for data
        dummy: lcommon.L_Umaxalign,
    },
};

///
/// Function Prototypes
///
pub const Proto = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    /// number of upvalues
    nups: u8,
    numparams: u8,
    is_vararg: u8,
    maxstacksize: u8,
    flags: u8,

    /// constants used by the function
    k: [*]TValue,
    /// function bytecode
    code: *lcommon.Instruction,
    /// functions defined inside the function
    p: [*]?*Proto,
    codeentry: *const lcommon.Instruction,

    execdata: ?*anyopaque,
    exectarget: usize,

    lineinfo: ?[*]u8, // for each instruction, line number as a delta from baseline
    abslineinfo: ?[*]u8, // baseline line info, one entry for each 1<<linegaplog2 instructions; allocated after lineinfo
    locvars: [*]LocVar, // information about local variables
    upvalues: [*]?*TString, // upvalue names
    source: ?*TString,

    debugname: ?*TString,
    debuginsn: ?[*]u8, // a copy of code[] array with just opcodes

    typeinfo: ?[*]u8,

    userdata: ?*anyopaque,

    gclist: ?*lstate.GCObject,

    sizecode: c_int,
    sizep: c_int,
    sizelocvars: c_int,
    sizeupvalues: c_int,
    sizek: c_int,
    sizelineinfo: c_int,
    linegaplog2: c_int,
    linedefined: c_int,
    bytecodeid: c_int,
    sizetypeinfo: c_int,
};

pub const LocVar = extern struct {
    varname: ?*TString,
    /// first point where variable is active
    startpc: c_int,
    /// first point where variable is dead
    endpc: c_int,
    /// register slot, relative to base, where variable is stored
    reg: u8,
};

///
/// Upvalues
///
pub const UpVal = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    /// set if reachable from an alive thread (only valid during atomic)
    markedopen: u8,

    // 4 byte padding (x64)

    /// points to stack or to its own value
    v: *TValue,
    u: extern union {
        /// the value (when closed)
        value: TValue,
        open: extern struct {
            // global double linked list (when open)
            prev: ?*UpVal,
            next: ?*UpVal,

            // thread linked list (when open)
            threadnext: ?*UpVal,
        },
    },

    pub inline fn upisopen(up: *const UpVal) bool {
        return up.v != &up.u.value;
    }
};

///
/// Closures
///
pub const Closure = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    isC: u8,
    nupvalues: u8,
    stacksize: u8,
    preload: u8,

    gclist: ?*lstate.GCObject,
    env: *LuaTable,

    d: extern union {
        c: extern struct {
            f: lua.CFunction,
            cont: lua.Continuation,
            debugname: [*c]const u8,
            upvals: [1]TValue,
        },
        l: extern struct {
            p: *Proto,
            uprefs: [1]TValue,
        },
    },
};

pub const TKey = extern struct {
    value: Value,
    extra: [config.EXTRA_SIZE]c_int,
    tt: u8,
    next: [3]u8, // for chaining

    pub inline fn ttype(this: *const TKey) u4 {
        return @intCast(this.tt & 0x0F);
    }

    pub inline fn vnext(this: *TKey) i28 {
        const lower = @as(u4, @intCast(this.tt & 0xF0));
        const higher = @as(u24, @bitCast(this.next));
        return @bitCast((@as(u28, @intCast(lower)) << 24) | @as(u28, @intCast(higher)));
    }
};

pub const LuaNode = extern struct {
    val: TValue,
    key: TKey,

    pub inline fn gkey(this: *LuaNode) *TKey {
        return &this.key;
    }
    pub inline fn gval(this: *LuaNode) *TValue {
        return &this.val;
    }
    pub inline fn gnext(this: *LuaNode) i28 {
        return this.key.vnext();
    }
};

pub const LuaTable = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    /// 1<<p means tagmethod(p) is not present
    tmcache: u8,
    /// sandboxing feature to prohibit writes to table
    readonly: u8,
    /// environment doesn't share globals with other scripts
    safeenv: u8,
    /// log2 of size of `node' array
    lsizenode: u8,
    /// (1<<lsizenode)-1, truncated to 8 bits
    nodemask8: u8,

    /// size of `array' array
    sizearray: c_int,
    bound: extern union {
        /// any free position is before this position
        lastfree: c_int,
        /// negated 'boundary' of `array' array; iff aboundary < 0
        aboundary: c_int,
    },

    metatable: ?*LuaTable,
    array: [*]TValue, // array part
    node: [*]LuaNode,
    gclist: ?*lstate.GCObject,
};

pub const nilobject = &nilobject_;

const nilobject_: TValue = .{
    .value = undefined,
    .extra = undefined,
    .tt = @intFromEnum(lua.Type.Nil),
};

pub fn Opushvfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) void {
    var buf: [lua.config.BUFFERSIZE]u8 = undefined;
    const fstr = std.fmt.bufPrint(&buf, fmt, args) catch |err| @panic(@errorName(err));
    L.pushlstring(fstr);
}

pub inline fn Opushfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) void {
    Opushvfstring(L, fmt, args);
}

// pub fn Ochunkid(out: []u8, comptime source: []const u8) []u8 {
//     c.luaO
// }
