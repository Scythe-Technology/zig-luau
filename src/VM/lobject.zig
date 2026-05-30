const c = @import("c");
const std = @import("std");

const lgc = @import("lgc.zig");
const lua = @import("lua.zig");
const lstate = @import("lstate.zig");
const lcommon = @import("lcommon.zig");
const lnumutils = @import("lnumutils.zig");

const Errorset = @import("errorset.zig");

pub const CommonHeader = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,
};

pub const GCheader = extern struct {
    header: CommonHeader,

    pub inline fn ttype(this: *const GCheader) c_int {
        return this.header.tt;
    }
};

pub const Value = extern union {
    gc: ?*lstate.GCObject,
    p: ?*anyopaque,
    n: f64,
    b: c_int,
    l: i64,
    /// v[0], v[1] live here; v[2] lives in TValue::extra
    v: [2]f32,
};

///
/// Tagged Values
///
pub const TValue = extern struct {
    value: Value,
    extra: [lua.config.EXTRA_SIZE]c_int = undefined,
    tt: c_int,

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
    pub inline fn ttisinteger(obj: *const TValue) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Integer);
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

    pub inline fn obj2gco(obj: *TValue) *lstate.GCObject {
        std.debug.assert(obj.iscollectable());
        return @ptrCast(@alignCast(obj));
    }

    pub inline fn gcvalue(obj: *const TValue) *lstate.GCObject {
        std.debug.assert(obj.iscollectable());
        return obj.value.gc.?;
    }
    pub inline fn pvalue(obj: *const TValue) ?*anyopaque {
        std.debug.assert(obj.ttislightuserdata());
        return obj.value.p;
    }
    pub inline fn nvalue(obj: *const TValue) f64 {
        std.debug.assert(obj.ttisnumber());
        return obj.value.n;
    }
    pub inline fn lvalue(obj: *const TValue) i64 {
        std.debug.assert(obj.ttisinteger());
        return obj.value.l;
    }
    pub inline fn vvalue(obj: *const TValue) []const f32 {
        std.debug.assert(obj.ttisvector());
        return @as([*]const f32, @ptrCast(&obj.value.v))[0..lua.config.VECTOR_SIZE];
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
    pub inline fn cobjvalue(obj: *const TValue) *anyopaque {
        std.debug.assert(obj.ttisisclassobject());
        return &obj.value.gc.?.classobj;
    }
    pub inline fn svalue(obj: *const TValue) [*c]const u8 {
        return obj.tsvalue().getstr();
    }

    pub inline fn l_isfalse(obj: *const TValue) bool {
        return obj.ttisnil() or (obj.ttisboolean() and !obj.bvalue());
    }

    pub inline fn lightuserdatatag(obj: *const TValue) u8 {
        std.debug.assert(obj.ttislightuserdata());
        return @intCast(obj.extra[0]);
    }

    pub inline fn checkliveness(obj: *const TValue, g: *const lstate.global_State) void {
        std.debug.assert(!obj.iscollectable() or ((obj.ttype() == obj.value.gc.?.gch.header.tt) and !lgc.isdead(g, obj.value.gc.?)));
    }

    pub inline fn setnilvalue(obj: *TValue) void {
        obj.settype(.Nil);
    }
    pub inline fn setnvalue(obj: *TValue, x: f64) void {
        obj.value.n = x;
        obj.settype(.Number);
    }
    pub inline fn setlvalue(obj: *TValue, x: i64) void {
        obj.value.l = x;
        obj.settype(.Integer);
    }
    pub inline fn setvvalue(obj: *TValue, x: f32, y: f32, z: f32, w: ?f32) void {
        const i_v: [*]f32 = @ptrCast(&obj.value.v);
        i_v[0] = x;
        i_v[1] = y;
        i_v[2] = z;
        if (comptime lua.config.VECTOR_SIZE == 4)
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
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.String);
        obj.checkliveness(L.global);
    }
    pub inline fn setuvalue(obj: *TValue, L: *lstate.lua_State, x: *Udata) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Userdata);
        obj.checkliveness(L.global);
    }
    pub inline fn setthvalue(obj: *TValue, L: *lstate.lua_State, x: *lstate.lua_State) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Thread);
        obj.checkliveness(L.global);
    }
    pub inline fn setbufvalue(obj: *TValue, L: *lstate.lua_State, x: *Buffer) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Buffer);
        obj.checkliveness(L.global);
    }
    pub inline fn setclvalue(obj: *TValue, L: *lstate.lua_State, x: *Closure) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Function);
        obj.checkliveness(L.global);
    }
    pub inline fn sethvalue(obj: *TValue, L: *lstate.lua_State, x: *LuaTable) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Table);
        obj.checkliveness(L.global);
    }
    pub inline fn setptvalue(obj: *TValue, L: *lstate.lua_State, x: *Proto) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.Proto);
        obj.checkliveness(L.global);
    }
    pub inline fn setupvalue(obj: *TValue, L: *lstate.lua_State, x: *UpVal) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.UpVal);
        obj.checkliveness(L.global);
    }
    pub inline fn setobj(obj: *TValue, L: *lstate.lua_State, o2: *const TValue) void {
        obj.* = o2.*;
        obj.checkliveness(L.global);
    }
    pub inline fn setcobjvalue(obj: *TValue, L: *lstate.lua_State, x: *anyopaque) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.ClassObj);
        obj.checkliveness(L.global);
    }
    pub inline fn setsinstvalue(obj: *TValue, L: *lstate.lua_State, x: *anyopaque) void {
        obj.value.gc = @ptrCast(@alignCast(x));
        obj.settype(.ClassInst);
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

pub const LU_TAG_ITERATOR = lua.config.UTAG_LIMIT;

pub inline fn checkliveness() void {}

pub const StkId = [*]TValue;

pub const TString = extern struct {
    header: CommonHeader,

    // 1 byte padding

    atom: i16,

    // 2 byte padding

    /// next string in the hash table bucket
    next: ?*TString,

    hash: c_uint,
    len: c_uint,

    /// string data is allocated right after the header
    data: [1]u8,

    pub inline fn obj2gco(obj: *TString) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }

    pub inline fn gdata(s: *TString) [*]u8 {
        return @ptrCast(@alignCast(&s.data));
    }

    pub inline fn getstr(s: *const TString) [*c]const u8 {
        return @ptrCast(@alignCast(&s.data));
    }

    pub inline fn toSlice(s: *const TString) [:0]const u8 {
        return s.getstr()[0..s.len :0];
    }
};

pub const Udata = extern struct {
    header: CommonHeader,

    tag: u8,

    len: c_int,

    metatable: ?*LuaTable,

    data: [1]u8 align(8),

    pub inline fn obj2gco(obj: *Udata) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }
};

pub const Buffer = extern struct {
    header: CommonHeader,

    len: c_uint,

    data: [1]u8 align(8),

    pub inline fn obj2gco(obj: *Buffer) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }
};

pub const FeedbackVectorSlotKind = enum(u8) {
    CallTarget,
};

pub const FeedbackVectorSlot = extern struct {
    kind: FeedbackVectorSlotKind,
    data: extern union {
        call_target: extern struct {
            pc: u32,
            proto: u32,
            hits: u32,
        },
    },
};

///
/// Function Prototypes
///
pub const Proto = extern struct {
    header: CommonHeader,

    /// number of upvalues
    nups: u8,
    numparams: u8,
    is_vararg: u8,
    maxstacksize: u8,
    flags: u8,

    /// constants used by the function
    k: ?[*]TValue,
    /// function bytecode
    code: ?[*]lcommon.Instruction,
    /// functions defined inside the function
    p: ?[*]?*Proto,
    codeentry: ?*const lcommon.Instruction,

    execdata: ?*anyopaque,
    exectarget: usize,

    lineinfo: ?[*]u8, // for each instruction, line number as a delta from baseline
    abslineinfo: ?[*]u8, // baseline line info, one entry for each 1<<linegaplog2 instructions; allocated after lineinfo
    locvars: ?[*]LocVar, // information about local variables
    upvalues: ?[*]?*TString, // upvalue names
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

    feedbackvec: ?[*]FeedbackVectorSlot,
    feedbackvecsize: u32,
    funid: u32,

    pub inline fn obj2gco(obj: *Proto) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }
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
    header: CommonHeader,

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

    pub inline fn obj2gco(obj: *UpVal) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }

    pub inline fn upisopen(up: *const UpVal) bool {
        return up.v != &up.u.value;
    }
};

///
/// Closures
///
pub const Closure = extern struct {
    header: CommonHeader,

    isC: u8,
    nupvalues: u8,
    stacksize: u8,
    preload: u8,

    usage: u64,
    gclist: ?*lstate.GCObject,
    env: *LuaTable,

    d: ValueUnion,

    pub const ValueUnion = extern union {
        c: C,
        l: L,

        pub const C = extern struct {
            f: ?lua.CFunction,
            cont: ?lua.Continuation,
            debugname: [*c]const u8,
            upvals: [1]TValue,

            pub inline fn upvalues(cc: *C) [*]TValue {
                return @as([*]TValue, @ptrCast(&cc.upvals));
            }
        };

        pub const L = extern struct {
            p: *Proto,
            uprefs: [1]TValue,

            pub inline fn upreferences(ll: *L) [*]TValue {
                return @as([*]TValue, @ptrCast(&ll.uprefs));
            }
        };
    };

    pub inline fn obj2gco(obj: *Closure) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }
};

pub const TKey = extern struct {
    value: Value,
    extra: [lua.config.EXTRA_SIZE]c_int,
    pi: Packed = undefined,

    pub const Packed = packed struct(u32) {
        tt: u4, // type
        next: i28, // next in the chain

        pub fn withtt(tt: u4) [4]u8 {
            return @bitCast(Packed{ .tt = tt, .next = 0 });
        }
    };

    pub inline fn ttype(this: *const TKey) u4 {
        return this.pi.tt;
    }

    pub inline fn typeOf(obj: *const TKey) lua.Type {
        return @enumFromInt(obj.ttype());
    }

    pub inline fn setttype(this: *TKey, t: lua.Type) void {
        this.pi.tt = @intFromEnum(t);
    }

    pub inline fn ttisnil(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Nil);
    }
    pub inline fn ttisnumber(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Number);
    }
    pub inline fn ttisinteger(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Integer);
    }
    pub inline fn ttisstring(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.String);
    }
    pub inline fn ttistable(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Table);
    }
    pub inline fn ttisfunction(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Function);
    }
    pub inline fn ttisboolean(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Boolean);
    }
    pub inline fn ttisuserdata(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Userdata);
    }
    pub inline fn ttisthread(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Thread);
    }
    pub inline fn ttisbuffer(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Buffer);
    }
    pub inline fn ttislightuserdata(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.LightUserdata);
    }
    pub inline fn ttisvector(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.Vector);
    }
    pub inline fn ttisupval(obj: *const TKey) bool {
        return obj.ttype() == @intFromEnum(lua.Type.UpVal);
    }

    pub inline fn gcvalue(obj: *const TKey) *lstate.GCObject {
        std.debug.assert(obj.iscollectable());
        return obj.value.gc.?;
    }
    pub inline fn pvalue(obj: *const TKey) ?*anyopaque {
        std.debug.assert(obj.ttislightuserdata());
        return obj.value.p;
    }
    pub inline fn nvalue(obj: *const TKey) f64 {
        std.debug.assert(obj.ttisnumber());
        return obj.value.n;
    }
    pub inline fn lvalue(obj: *const TKey) i64 {
        std.debug.assert(obj.ttisinteger());
        return obj.value.l;
    }
    pub inline fn vvalue(obj: *const TKey) []const f32 {
        std.debug.assert(obj.ttisvector());
        return @as([*]const f32, @ptrCast(&obj.value.v))[0..lua.config.VECTOR_SIZE];
    }
    pub inline fn tsvalue(obj: *const TKey) *TString {
        std.debug.assert(obj.ttisstring());
        return &obj.value.gc.?.ts;
    }
    pub inline fn uvalue(obj: *const TKey) *Udata {
        std.debug.assert(obj.ttisuserdata());
        return &obj.value.gc.?.u;
    }
    pub inline fn clvalue(obj: *const TKey) *Closure {
        std.debug.assert(obj.ttisfunction());
        return &obj.value.gc.?.cl;
    }
    pub inline fn hvalue(obj: *const TKey) *LuaTable {
        std.debug.assert(obj.ttistable());
        return &obj.value.gc.?.h;
    }
    pub inline fn bvalue(obj: *const TKey) bool {
        std.debug.assert(obj.ttisboolean());
        return obj.value.b != 0;
    }
    pub inline fn thvalue(obj: *const TKey) *lstate.lua_State {
        std.debug.assert(obj.ttisthread());
        return &obj.value.gc.?.th;
    }
    pub inline fn bufvalue(obj: *const TKey) *Buffer {
        std.debug.assert(obj.ttisbuffer());
        return &obj.value.gc.?.buf;
    }
    pub inline fn upvalue(obj: *TKey) *UpVal {
        std.debug.assert(obj.ttisupval());
        return &obj.value.gc.?.uv;
    }
    pub inline fn svalue(obj: *const TKey) [*c]const u8 {
        return obj.tsvalue().getstr();
    }

    pub inline fn lightuserdatatag(obj: *const TKey) c_int {
        std.debug.assert(obj.ttislightuserdata());
        return obj.extra[0];
    }

    pub inline fn iscollectable(o: *const TKey) bool {
        return o.ttype() >= @intFromEnum(lua.Type.String);
    }

    pub inline fn setnilvalue(obj: *TKey) void {
        obj.pi.tt = @intFromEnum(lua.Type.Nil);
    }

    pub inline fn next(this: *TKey) i28 {
        return this.pi.next;
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
        return this.key.pi.next;
    }

    pub inline fn add_num(this: *LuaNode, n: anytype) *LuaNode {
        switch (@typeInfo(@TypeOf(n))) {
            .comptime_int => return @ptrCast(@as([*]LuaNode, @ptrCast(this)) + @as(usize, @intCast(n))),
            .int => |i| {
                if (i.signedness == .unsigned)
                    return @ptrCast(@as([*]LuaNode, @ptrCast(this)) + @as(usize, @intCast(n)))
                else {
                    if (n < 0)
                        return @ptrCast(@as([*]LuaNode, @ptrCast(this)) - @as(usize, @intCast(-n)))
                    else
                        return @ptrCast(@as([*]LuaNode, @ptrCast(this)) + @as(usize, @intCast(n)));
                }
            },
            else => @compileError("n must be an integer"),
        }
    }

    pub fn sub(this: *LuaNode, ptr: *LuaNode) isize {
        if (@intFromPtr(ptr) > @intFromPtr(this))
            return -@as(isize, @intCast(@as([*]LuaNode, @ptrCast(ptr)) - @as([*]LuaNode, @ptrCast(this))));
        return @intCast(@as([*]LuaNode, @ptrCast(this)) - @as([*]LuaNode, @ptrCast(ptr)));
    }
};

pub inline fn setnodekey(L: *lstate.lua_State, node: *LuaNode, obj: *const TValue) void {
    node.key.value = obj.value;
    @memcpy(node.key.extra[0..lua.config.EXTRA_SIZE], obj.extra[0..lua.config.EXTRA_SIZE]);
    node.key.pi.tt = @intCast(obj.tt);
    obj.checkliveness(L.global);
}

pub inline fn getnodekey(L: *lstate.lua_State, obj: *TValue, node: *const LuaNode) void {
    obj.value = node.key.value;
    @memcpy(obj.extra[0..lua.config.EXTRA_SIZE], node.key.extra[0..lua.config.EXTRA_SIZE]);
    obj.tt = @intCast(node.key.pi.tt);
    obj.checkliveness(L.global);
}

pub const LuaTable = extern struct {
    header: CommonHeader,

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
    array: ?[*]TValue, // array part
    node: [*]LuaNode,
    gclist: ?*lstate.GCObject,

    pub inline fn obj2gco(obj: *LuaTable) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }

    pub inline fn gnode(t: *const LuaTable, i: usize) [*]LuaNode {
        return t.node + i;
    }
};

pub const ClassObject = extern struct {
    header: CommonHeader,

    gclist: ?*lstate.GCObject,

    name: *TString,

    /// Mapping from offset to static members (only methods for now).
    staticmembers: [*]TValue,

    /// Mapping from member name to offset.
    memberstooffset: *LuaTable,

    /// Mapping from offset to member name.
    offsettomember: [*]*TString,

    /// Metatable for this *class object*. At time of writing this only contains
    /// __call, but we may add more metamethods to class objects in the future.
    metatable: *LuaTable,

    /// Number of instance members that we expect instances of this class object
    /// to have.
    numberofinstancemembers: c_int,

    // Total number of members that we expect this class object to have between
    // instance and static members.
    //
    // We store this number as an optimization. It's pretty rare that we need
    // to reference the specific number of static members, but it's very common
    // to reference the total number of members (for validating hot paths in
    // the interpreter) and the number of instance members (branching on
    // instance or static members, creating class instances).
    numberofallmembers: c_int,

    pub inline fn obj2gco(obj: *ClassObject) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }
};

pub const ClassInstance = extern struct {
    header: CommonHeader,

    gclist: ?*lstate.GCObject,

    /// The class object that this value is an instance of.
    classobj: *ClassObject,

    /// The number of members that this instance contains. We need this in order
    /// to free ourselves if we got swept in the same GC cycle as our class
    /// pointer.
    numberofmembers: c_int,

    /// The fields of this instance.
    members: [*]TValue,

    pub inline fn obj2gco(obj: *ClassInstance) *lstate.GCObject {
        return @ptrCast(@alignCast(obj));
    }
};

pub inline fn lmod(comptime T: type, s: u32, size: T) T {
    std.debug.assert(size & (size - 1) == 0);
    return s & (size - 1);
}

pub inline fn twoto(x: if (@sizeOf(usize) == 8) u6 else u5) usize {
    return @as(usize, 1) << x;
}
pub inline fn sizenode(t: *const LuaTable) usize {
    return @intCast(@as(usize, 1) << @truncate(t.lsizenode));
}

extern "c" const luaO_nilobject_: TValue;
pub const Onilobject = &luaO_nilobject_;

pub inline fn ceillog2(x: u32) i32 {
    return Olog2(x - 1) + 1;
}

pub fn Olog2(i: u32) i32 {
    // zig fmt: off
    const log_2: [256]u8 = [_]u8{0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6,
                                 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
                                 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
                                 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
                                 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
                                 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
                                 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8};
    // zig fmt: on
    var x: u32 = i;
    var l: i32 = -1;
    while (x >= 256) {
        l += 8;
        x >>= 8;
    }
    return l + log_2[x];
}

pub fn OrawequalObj(t1: *const TValue, t2: *const TValue) bool {
    if (t1.ttype() != t2.ttype())
        return false;

    switch (t1.typeOf()) {
        .None => unreachable,
        .Nil => return true,
        .Number => return t1.nvalue() == t2.nvalue(),
        .Integer => return t1.lvalue() == t2.lvalue(),
        .Vector => return lnumutils.iveceq(t1.vvalue(), t2.vvalue()),
        .Boolean => return t1.bvalue() == t2.bvalue(),
        .LightUserdata => return t1.pvalue() == t2.pvalue() and t1.lightuserdatatag() == t2.lightuserdatatag(),
        inline else => |t| {
            comptime std.debug.assert(t.istypecollectable());
            return t1.gcvalue() == t2.gcvalue();
        },
    }
}

pub fn OrawequalKey(t1: *const TKey, t2: *const TValue) bool {
    if (t1.ttype() != t2.ttype())
        return false;

    switch (t1.typeOf()) {
        .None => unreachable,
        .Nil => return true,
        .Number => return t1.nvalue() == t2.nvalue(),
        .Integer => return t1.lvalue() == t2.lvalue(),
        .Vector => return lnumutils.iveceq(t1.vvalue(), t2.vvalue()),
        .Boolean => return t1.bvalue() == t2.bvalue(),
        .LightUserdata => return t1.pvalue() == t2.pvalue() and t1.lightuserdatatag() == t2.lightuserdatatag(),
        inline else => |t| {
            comptime std.debug.assert(t.istypecollectable());
            return t1.gcvalue() == t2.gcvalue();
        },
    }
}

pub fn Opushvfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) Errorset.Table!void {
    var buf: [lua.config.BUFFERSIZE]u8 = undefined;
    const fstr = std.fmt.bufPrint(&buf, fmt, args) catch |err| @panic(@errorName(err));
    try L.pushlstring(fstr);
}

pub inline fn Opushfstring(L: *lua.State, comptime fmt: []const u8, args: anytype) Errorset.Table!void {
    try Opushvfstring(L, fmt, args);
}

// pub fn Ochunkid(out: []u8, comptime source: []const u8) []u8 {
//     c.luaO
// }

test "size match" {
    const Sizes = struct {
        extern "c" const GCObject_size: u8;
        extern "c" const GCheader_size: u8;
        extern "c" const Value_size: u8;
        extern "c" const TValue_size: u8;
        extern "c" const TString_size: u8;
        extern "c" const Udata_size: u8;
        extern "c" const LuauBuffer_size: u8;
        extern "c" const Proto_size: u8;
        extern "c" const LocVar_size: u8;
        extern "c" const UpVal_size: u8;
        extern "c" const Closure_size: u8;
        extern "c" const TKey_size: u8;
        extern "c" const LuaNode_size: u8;
        extern "c" const LuaTable_size: u8;
        extern "c" const LuaClassObject_size: u8;
        extern "c" const LuaClassInstance_size: u8;

        extern "c" const TString_data_offset: u8;
        extern "c" const Udata_data_offset: u8;
        extern "c" const LuauBuffer_data_offset: u8;
    };

    try std.testing.expect(Sizes.GCObject_size == @sizeOf(lstate.GCObject));
    try std.testing.expect(Sizes.GCheader_size == @sizeOf(GCheader));
    try std.testing.expect(Sizes.Value_size == @sizeOf(Value));
    try std.testing.expect(Sizes.TValue_size == @sizeOf(TValue));
    try std.testing.expect(Sizes.TString_size == @sizeOf(TString));
    try std.testing.expect(Sizes.Udata_size == @sizeOf(Udata));
    try std.testing.expect(Sizes.LuauBuffer_size == @sizeOf(Buffer));
    try std.testing.expect(Sizes.Proto_size == @sizeOf(Proto));
    try std.testing.expect(Sizes.LocVar_size == @sizeOf(LocVar));
    try std.testing.expect(Sizes.UpVal_size == @sizeOf(UpVal));
    try std.testing.expect(Sizes.Closure_size == @sizeOf(Closure));
    try std.testing.expect(Sizes.TKey_size == @sizeOf(TKey));
    try std.testing.expect(Sizes.LuaNode_size == @sizeOf(LuaNode));
    try std.testing.expect(Sizes.LuaTable_size == @sizeOf(LuaTable));
    try std.testing.expect(Sizes.LuaClassObject_size == @sizeOf(ClassObject));
    try std.testing.expect(Sizes.LuaClassInstance_size == @sizeOf(ClassInstance));

    try std.testing.expect(Sizes.TString_data_offset == @offsetOf(TString, "data"));
    try std.testing.expect(Sizes.Udata_data_offset == @offsetOf(Udata, "data"));
    try std.testing.expect(Sizes.LuauBuffer_data_offset == @offsetOf(Buffer, "data"));
}
