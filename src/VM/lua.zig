const std = @import("std");
pub const c = @import("c");

const lstate = @import("lstate.zig");
pub const config = @import("luaconf.zig");

pub const MULTRET = c.LUA_MULTRET;

// pseudo-indices
pub const REGISTRYINDEX = c.LUA_REGISTRYINDEX;
pub const GLOBALSINDEX = c.LUA_GLOBALSINDEX;
pub const ENVIRONINDEX = c.LUA_ENVIRONINDEX;

pub fn upvalueindex(i: i32) i32 {
    return GLOBALSINDEX - i;
}

pub fn ispseudo(i: i32) bool {
    return i <= REGISTRYINDEX;
}

// thread status; 0 is OK
pub const Status = enum(u3) {
    Ok = 0,
    Yield,
    ErrRun,
    /// legacy error code, preserved for compatibility
    ErrSyntax,
    ErrMem,
    ErrErr,
    /// yielded for a debug breakpoint
    Break,

    pub fn check(s: Status) !Status {
        switch (s) {
            .ErrErr, .ErrRun => return error.Runtime,
            .ErrMem => return error.OutOfMemory,
            .ErrSyntax => return error.BadSyntax,
            else => return s,
        }
    }
};

pub const CoStatus = enum(u3) {
    /// running
    Running = 0,
    /// suspended
    Suspended,
    /// 'normal' (it resumed another coroutine)
    Normal,
    /// finished
    Finished,
    /// finished with error
    FinishedErr,
};

pub const State = lstate.lua_State;

pub const CFunction = *const fn (L: *State) callconv(.c) c_int;
pub const Continuation = *const fn (L: *State, status: c_int) callconv(.c) c_int;
pub const Destructor = *const fn (L: *State, ?*anyopaque) callconv(.c) void;
pub const Coverage = *const fn (?*anyopaque, [*c]const u8, c_int, c_int, [*c]const c_int, usize) callconv(.c) void;

///
/// prototype for memory-allocation functions
///
pub const Alloc = *const fn (ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque;

///
///  basic types
///
pub const TNONE = c.LUA_TNONE;

/// Must be a signed integer because LuaType.none is -1
pub const Type = enum(i5) {
    None = TNONE,
    Nil = c.LUA_TNIL, // must be 0 due to lua_isnoneornil
    Boolean = c.LUA_TBOOLEAN, // must be 1 due to l_isfalse
    LightUserdata = c.LUA_TLIGHTUSERDATA,
    Number = c.LUA_TNUMBER,
    Vector = c.LUA_TVECTOR,
    String = c.LUA_TSTRING, // all types above this must be value types, all types below this must be GC types - see iscollectable
    Table = c.LUA_TTABLE,
    Function = c.LUA_TFUNCTION,
    Userdata = c.LUA_TUSERDATA,
    Thread = c.LUA_TTHREAD,
    Buffer = c.LUA_TBUFFER,

    // values below this line are used in GCObject tags but may never show up in TValue type tags
    Proto = c.LUA_TPROTO,
    UpVal = c.LUA_TUPVAL,
    Deadkey = c.LUA_TDEADKEY,

    // the count of TValue type tags
    pub const T_COUNT = c.LUA_T_COUNT;

    pub inline fn isnoneornil(t: Type) bool {
        return t == .None or t == .Nil;
    }
};

// type of numbers in Luau
pub const Number = c.lua_Number;

// type for integer functions
pub const Integer = c.lua_Integer;

// unsigned integer type
pub const Unsigned = c.lua_Unsigned;

///
/// garbage-collection function and options
///
pub const GCOp = enum(u4) {
    // stop and resume incremental garbage collection
    Stop = c.LUA_GCSTOP,
    Restart = c.LUA_GCRESTART,

    // run a full GC cycle; not recommended for latency sensitive applications
    Collect = c.LUA_GCCOLLECT,

    // return the heap size in KB and the remainder in bytes
    Count = c.LUA_GCCOUNT,
    CountB = c.LUA_GCCOUNTB,

    // return 1 if GC is active (not stopped); note that GC may not be actively collecting even if it's running
    IsRunning = c.LUA_GCISRUNNING,

    ///
    /// perform an explicit GC step, with the step size specified in KB
    ///
    /// garbage collection is handled by 'assists' that perform some amount of GC work matching pace of allocation
    /// explicit GC steps allow to perform some amount of work at custom points to offset the need for GC assists
    /// note that GC might also be paused for some duration (until bytes allocated meet the threshold)
    /// if an explicit step is performed during this pause, it will trigger the start of the next collection cycle
    ///
    Step = c.LUA_GCSTEP,

    ///
    /// tune GC parameters G (goal), S (step multiplier) and step size (usually best left ignored)
    ///
    /// garbage collection is incremental and tries to maintain the heap size to balance memory and performance overhead
    /// this overhead is determined by G (goal) which is the ratio between total heap size and the amount of live data in it
    /// G is specified in percentages; by default G=200% which means that the heap is allowed to grow to ~2x the size of live data.
    ///
    /// collector tries to collect S% of allocated bytes by interrupting the application after step size bytes were allocated.
    /// when S is too small, collector may not be able to catch up and the effective goal that can be reached will be larger.
    /// S is specified in percentages; by default S=200% which means that collector will run at ~2x the pace of allocations.
    ///
    /// it is recommended to set S in the interval [100 / (G - 100), 100 + 100 / (G - 100))] with a minimum value of 150%; for example:
    /// - for G=200%, S should be in the interval [150%, 200%]
    /// - for G=150%, S should be in the interval [200%, 300%]
    /// - for G=125%, S should be in the interval [400%, 500%]
    ///
    SetGoal = c.LUA_GCSETGOAL,
    SetStepMul = c.LUA_GCSETSTEPMUL,
    SetStepSize = c.LUA_GCSETSTEPSIZE,
};

///
/// reference system, can be used to pin objects
///
pub const NOREF = c.LUA_NOREF;
pub const REFNIL = c.LUA_REFNIL;

pub const Hook = *const fn (?*State, [*c]c.lua_Debug) callconv(.c) void;

pub const Debug = struct {
    what: Context = .lua,
    name: ?[:0]const u8 = null,
    source: ?[:0]const u8 = null,
    short_src: ?[]u8 = null,
    linedefined: c_int = 0,
    currentline: c_int = 0,
    nupvals: u8 = 0,
    nparams: u8 = 0,
    isvararg: u8 = 0,
    ssbuf: [config.IDSIZE:0]u8,

    pub const Context = enum {
        lua,
        c,
        main,
        tail,
    };

    pub fn fromLua(ar: c.lua_Debug, options: []const u8) Debug {
        var arz: Debug = undefined;

        if (std.mem.indexOf(u8, options, "n")) |_|
            arz.name = std.mem.span(ar.name);

        if (std.mem.indexOf(u8, options, "s")) |_| {
            arz.source = std.mem.span(ar.source);

            const short_src: [:0]const u8 = std.mem.span(ar.short_src);
            @memcpy(arz.ssbuf[0..short_src.len], short_src[0.. :0]);
            arz.short_src = arz.ssbuf[0..short_src.len];

            arz.linedefined = ar.linedefined;
            arz.what = blk: {
                const what = std.mem.span(ar.what);
                if (std.mem.eql(u8, "Lua", what)) break :blk .lua;
                if (std.mem.eql(u8, "C", what)) break :blk .c;
                if (std.mem.eql(u8, "main", what)) break :blk .main;
                if (std.mem.eql(u8, "tail", what)) break :blk .tail;
                unreachable;
            };
        }

        if (std.mem.indexOf(u8, options, "l")) |_|
            arz.currentline = ar.currentline;

        if (std.mem.indexOf(u8, options, "u")) |_|
            arz.nupvals = ar.nupvals;

        if (std.mem.indexOf(u8, options, "a")) |_| {
            arz.nparams = ar.nparams;
            arz.isvararg = ar.isvararg;
        }

        return arz;
    }
};

/// Callbacks that can be used to reconfigure behavior of the VM dynamically.
/// These are shared between all coroutines.
///
/// Note: interrupt is safe to set from an arbitrary thread but all other callbacks
/// can only be changed when the VM is not running any code
pub const Callbacks = extern struct {
    /// arbitrary userdata pointer that is never overwritten by Luau
    userdata: ?*anyopaque,

    /// gets called at safepoints (loop back edges, call/ret, gc) if set
    interrupt: ?*const fn (L: *State, gc: c_int) callconv(.C) void,
    /// gets called when an unprotected error is raised (if longjmp is used)
    panic: ?*const fn (L: *State, errcode: c_int) callconv(.C) void,

    /// gets called when L is created (LP == parent) or destroyed (LP == NULL)
    userthread: ?*const fn (LP: *State, L: *State) callconv(.C) void,
    /// gets called when a string is created; returned atom can be retrieved via tostringatom
    useratom: ?*const fn (s: [*c]const u8, l: usize) callconv(.C) i16,

    /// gets called when BREAK instruction is encountered
    debugbreak: ?*const fn (L: *State, ar: *c.lua_Debug) callconv(.C) void,
    /// gets called after each instruction in single step mode
    debugstep: ?*const fn (L: *State, ar: *c.lua_Debug) callconv(.C) void,
    /// gets called when thread execution is interrupted by break in another thread
    debuginterrupt: ?*const fn (L: *State, ar: *c.lua_Debug) callconv(.C) void,
    /// gets called when protected call results in an error
    debugprotectederror: ?*const fn (L: *State) callconv(.C) void,

    /// gets called when memory is allocated
    onallocate: ?*const fn (L: *State, osize: usize, nsize: usize) callconv(.C) void,
};
