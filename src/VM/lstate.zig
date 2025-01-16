const c = @import("c");
const std = @import("std");

const zapi = @import("zapi.zig");

const ldo = @import("ldo.zig");
const lgc = @import("lgc.zig");
const ltm = @import("ltm.zig");
const lua = @import("lua.zig");
const lapi = @import("lapi.zig");
const laux = @import("laux.zig");
const linit = @import("linit.zig");
const ldebug = @import("ldebug.zig");
const lcommon = @import("lcommon.zig");
const config = @import("luaconf.zig");
const lobject = @import("lobject.zig");
const lvmload = @import("lvmload.zig");

const lbaselib = @import("lbaselib.zig");
const lcorolib = @import("lcorolib.zig");
const ltablib = @import("ltablib.zig");
const loslib = @import("loslib.zig");
const lstrlib = @import("lstrlib.zig");
const lmathlib = @import("lmathlib.zig");
const ldblib = @import("ldblib.zig");
const lutf8lib = @import("lutf8lib.zig");
const lbitlib = @import("lbitlib.zig");
const lbuflib = @import("lbuflib.zig");
const lveclib = @import("lveclib.zig");

const state = @This();

///
/// Main thread combines a thread state and the global state
///
pub const LG = extern struct {
    l: lua_State,
    g: global_State,
};

const stringtable = extern struct {
    hash: [*]*lobject.TString,
    /// number of elements
    nuse: u32,
    size: c_int,
};

///
/// informations about a call
///
/// the general Lua stack frame structure is as follows:
/// - each function gets a stack frame, with function "registers" being stack slots on the frame
/// - function arguments are associated with registers 0+
/// - function locals and temporaries follow after; usually locals are a consecutive block per scope, and temporaries are allocated after this, but
/// this is up to the compiler
///
/// when function doesn't have varargs, the stack layout is as follows:
/// ^ (func) ^^ [fixed args] [locals + temporaries]
/// where ^ is the 'func' pointer in CallInfo struct, and ^^ is the 'base' pointer (which is what registers are relative to)
///
/// when function *does* have varargs, the stack layout is more complex - the runtime has to copy the fixed arguments so that the 0+ addressing still
/// works as follows:
/// ^ (func) [fixed args] [varargs] ^^ [fixed args] [locals + temporaries]
///
/// computing the sizes of these individual blocks works as follows:
/// - the number of fixed args is always matching the `numparams` in a function's Proto lobject; runtime adds `nil` during the call execution as
/// necessary
/// - the number of variadic args can be computed by evaluating (ci->base - ci->func - 1 - numparams)
///
/// the CallInfo structures are allocated as an array, with each subsequent call being *appended* to this array (so if f calls g, CallInfo for g
/// immediately follows CallInfo for f)
/// the `nresults` field in CallInfo is set by the caller to tell the function how many arguments the caller is expecting on the stack after the
/// function returns
/// the `flags` field in CallInfo contains internal execution flags that are important for pcall/etc, see LUA_CALLINFO_*
///
pub const CallInfo = extern struct {
    /// base for this function
    base: lobject.StkId,
    /// function index in the stack
    func: lobject.StkId,
    /// top for this function
    top: lobject.StkId,
    savedpc: ?*const lcommon.Instruction,

    /// expected number of results from this function
    nresults: c_int,
    /// call frame flags, see LUA_CALLINFO_*
    flags: c_uint,

    pub inline fn add_num(this: *CallInfo, num: usize) *CallInfo {
        return @ptrFromInt(@intFromPtr(this) + (num * @sizeOf(CallInfo)));
    }

    pub inline fn sub(this: *CallInfo, ptr: *CallInfo) usize {
        return @divExact(@intFromPtr(this) - @intFromPtr(ptr), @sizeOf(CallInfo));
    }
    pub inline fn sub_num(this: *CallInfo, num: usize) *CallInfo {
        return @ptrFromInt(@intFromPtr(this) - (num * @sizeOf(CallInfo)));
    }

    pub inline fn ci_func(this: *CallInfo) *lobject.Closure {
        return this.func.clvalue();
    }

    pub inline fn isLua(this: *CallInfo) bool {
        return this.func.ttisfunction() and this.ci_func().isC != 1;
    }
};

// should the interpreter return after returning from this callinfo? first frame must have this set
pub const CALLINFO_RETURN = 1 << 0;
// should the error thrown during execution get handled by continuation from this callinfo? func must be C
pub const CALLINFO_HANDLE = 1 << 1;
// should this function be executed using execution callback for native code
pub const CALLINFO_NATIVE = 1 << 2;

const GCStats = extern struct {
    // data for proportional-integral controller of heap trigger value
    triggerterms: [32]i32 = std.mem.zeroes([32]i32),
    triggertermpos: u32 = 0,
    triggerintegral: i32 = 0,

    atomicstarttotalsizebytes: usize = 0,
    endtotalsizebytes: usize = 0,
    heapgoalsizebytes: usize = 0,

    starttimestamp: f64 = 0,
    atomicstarttimestamp: f64 = 0,
    endtimestamp: f64 = 0,
};

const GCCycleMetrics = extern struct {
    starttotalsizebytes: usize = 0,
    heaptriggersizebytes: usize = 0,

    pausetime: f64 = 0.0, // time from end of the last cycle to the start of a new one

    starttimestamp: f64 = 0.0,
    endtimestamp: f64 = 0.0,

    marktime: f64 = 0.0,
    markassisttime: f64 = 0.0,
    markmaxexplicittime: f64 = 0.0,
    markexplicitsteps: usize = 0,
    markwork: usize = 0,

    atomicstarttimestamp: f64 = 0.0,
    atomicstarttotalsizebytes: usize = 0,
    atomictime: f64 = 0.0,

    // specific atomic stage parts
    atomictimeupval: f64 = 0.0,
    atomictimeweak: f64 = 0.0,
    atomictimegray: f64 = 0.0,
    atomictimeclear: f64 = 0.0,

    sweeptime: f64 = 0.0,
    sweepassisttime: f64 = 0.0,
    sweepmaxexplicittime: f64 = 0.0,
    sweepexplicitsteps: usize = 0,
    sweepwork: usize = 0,

    assistwork: usize = 0,
    explicitwork: usize = 0,

    propagatework: usize = 0,
    propagateagainwork: usize = 0,

    endtotalsizebytes: usize = 0,
};

const GCMetrics = extern struct {
    stepexplicittimeacc: f64 = 0.0,
    stepassisttimeacc: f64 = 0.0,

    /// when cycle is completed, last cycle values are updated
    completedcycles: u64 = 0,

    lastcycle: GCCycleMetrics,
    currcycle: GCCycleMetrics,
};

const ExecutionCallbacks = extern struct {
    context: *anyopaque,
    /// gets called when a function is created
    close: *const fn (L: *lua_State) callconv(.c) void,
    /// gets called when a function is destroyed
    destroy: *const fn (L: *lua_State, proto: *anyopaque) callconv(.c) void,
    /// gets called when a function is about to start/resume (when execdata is present), return 0 to exit VM
    enter: *const fn (L: *lua_State, proto: *anyopaque) callconv(.c) c_int,
    /// gets called when a function has to be switched from native to bytecode in the debugger
    disable: *const fn (L: *lua_State, proto: *anyopaque) callconv(.c) void,
    /// gets called to request the size of memory associated with native part of the Proto
    getmemorysize: *const fn (L: *lua_State, proto: *anyopaque) callconv(.c) usize,
    /// gets called to get the userdata type index
    gettypemapping: *const fn (L: *lua_State, str: [*c]const u8, len: usize) callconv(.c) u8,
};

pub const global_State = extern struct {
    /// hash table for strings
    strt: stringtable,

    /// function to reallocate memory
    frealloc: ?lua.Alloc,
    /// auxiliary data to `frealloc'
    ud: *anyopaque,

    currentwhite: u8,
    /// state of garbage collector
    gcstate: u8,

    /// list of gray objects
    gray: *GCObject,
    /// list of objects to be traversed atomically
    grayagain: *GCObject,
    /// list of weak tables (to be cleared)
    weak: *GCObject,

    /// when totalbytes > GCthreshold, run GC step
    GCthreshold: usize,
    /// number of bytes currently allocated
    totalbytes: usize,
    /// see LUAI_GCGOAL
    gcgoal: c_int,
    /// see LUAI_GCSTEPMUL
    gcstepmul: c_int,
    /// see LUAI_GCSTEPSIZE
    gcstepsize: c_int,

    /// free page linked list for each size class for non-collectable objects
    freepages: [config.SIZECLASSES]*anyopaque,
    /// free page linked list for each size class for collectable objects
    freegcopages: [config.SIZECLASSES]*anyopaque,
    /// page linked list with all pages for all non-collectable lobject classes (available with LUAU_ASSERTENABLED)
    allpages: *anyopaque,
    /// page linked list with all pages for all collectable lobject classes
    allgcopages: *anyopaque,
    /// position of the sweep in `allgcopages'
    sweepgcopage: *anyopaque,

    /// total amount of memory used by each memory category
    memcatbytes: [config.MEMORY_CATEGORIES]usize,

    mainthread: *lua_State,
    /// head of double-linked list of all open upvalues
    uvhead: lobject.UpVal,
    /// metatables for basic types
    mt: [lua.Type.T_COUNT]?*lobject.Table,
    /// names for basic types
    ttname: [lua.Type.T_COUNT]*lobject.TString,
    /// array with tag-method names
    tmname: [ltm.N]*lobject.TString,

    /// storage for temporary values used in pseudo2addr
    pseudotemp: lobject.TValue,

    /// registry table, used by lua_ref and LUA_REGISTRYINDEX
    registry: lobject.TValue,
    /// next free slot in registry
    registryfree: c_int,

    /// jump buffer data for longjmp-style error handling
    errorjmp: *anyopaque,

    /// PCG random number generator state
    rngstate: u64,
    /// pointer encoding key for display
    ptrenckey: [4]u64,

    cb: lua.Callbacks,

    ecb: ExecutionCallbacks,

    /// for each userdata tag, a gc callback to be called immediately before freeing memory
    udatagc: [config.UTAG_LIMIT]*const fn (*lua_State, *anyopaque) callconv(.C) void,
    /// metatables for tagged userdata
    udatamt: [config.UTAG_LIMIT]*lobject.Table,

    /// names for tagged lightuserdata
    lightuserdataname: [config.LUTAG_LIMIT]*lobject.TString,

    gcstats: GCStats,

    /// TODO: change `false` to be based on configuration (LUAI_GCMETRICS)
    gcmetrics: if (false) GCMetrics else void,
};

pub const lua_State = extern struct {
    tt: u8,
    marked: u8,
    memcat: u8,

    tstatus: u8,

    /// memory category that is used for new GC lobject allocations
    activememcat: u8,

    /// thread is currently executing, stack may be mutated without barriers
    isactive: bool,
    /// call debugstep hook after each instruction
    tsinglestep: bool,

    /// first free slot in the stack
    top: lobject.StkId,
    /// base of current function
    base: lobject.StkId,
    global: *global_State,
    /// call info for current function
    ci: ?*CallInfo,
    /// last free slot in the stack
    stack_last: lobject.StkId,
    /// stack base
    stack: ?lobject.StkId,

    /// points after end of ci array
    end_ci: ?*CallInfo,
    /// array of CallInfo's
    base_ci: ?*CallInfo,

    stacksize: c_int,
    /// size of array `base_ci'
    size_ci: c_int,

    /// number of nested C calls
    nCcalls: u16,
    /// nested C calls when resuming coroutine
    baseCcalls: u16,

    /// when table operations or INDEX/NEWINDEX is invoked from Luau, what is the expected slot for lookup?
    cachedslot: c_int,

    /// table of globals
    gt: ?*lobject.Table,
    /// list of open upvalues in this stack
    openupval: ?*lobject.UpVal,
    gclist: ?*GCObject,

    /// when invoked from Luau using NAMECALL, what method do we need to invoke?
    namecall: ?*lobject.TString,

    userdata: ?*anyopaque,

    pub inline fn registry(L: *lua_State) lobject.StkId {
        return &L.global.registry;
    }

    pub inline fn curr_func(L: *lua_State) *lobject.Closure {
        return L.ci.?.func.clvalue();
    }

    // pub const api_incr_top = lapi.incr_top;
    // pub const api_check = lapi.check;
    // pub const api_checknelems = lapi.checknelems;

    //
    // state manipulation
    //
    pub const close = state.close;
    pub const newthread = lapi.newthread;
    pub const mainthread = lapi.mainthread;
    pub const resetthread = state.resetthread;
    pub const isthreadreset = state.isthreadreset;

    //
    // basic stack manipulation
    //
    pub const absindex = lapi.absindex;
    pub const gettop = lapi.gettop;
    pub const settop = lapi.settop;
    pub const pop = lapi.pop;
    pub const pushvalue = lapi.pushvalue;
    pub const remove = lapi.remove;
    pub const insert = lapi.insert;
    pub const replace = lapi.replace;
    pub const checkstack = lapi.checkstack;
    pub const rawcheckstack = lapi.rawcheckstack;

    pub const xmove = lapi.xmove;
    pub const xpush = lapi.xpush;

    //
    // access functions (stack -> C)
    //
    pub const isnumber = lapi.isnumber;
    pub const isstring = lapi.isstring;
    pub const iscfunction = lapi.iscfunction;
    pub const isLfunction = lapi.isLfunction;
    pub const isuserdata = lapi.isuserdata;
    pub const @"type" = lapi.type;
    pub const isfunction = lapi.isfunction;
    pub const istable = lapi.istable;
    pub const islightuserdata = lapi.islightuserdata;
    pub const isnone = lapi.isnone;
    pub const isnil = lapi.isnil;
    pub const isboolean = lapi.isboolean;
    pub const isvector = lapi.isvector;
    pub const isthread = lapi.isthread;
    pub const isbuffer = lapi.isbuffer;
    pub const isnoneornil = lapi.isnoneornil;
    pub const typeOf = lapi.typeOf;
    pub const typename = lapi.typename;

    pub const equal = lapi.equal;
    pub const rawequal = lapi.rawequal;
    pub const lessthan = lapi.lessthan;

    pub const tonumberx = lapi.tonumberx;
    pub const tonumber = lapi.tonumber;
    pub const tointegerx = lapi.tointegerx;
    pub const tointeger = lapi.tointeger;
    pub const tounsignedx = lapi.tounsignedx;
    pub const tounsigned = lapi.tounsigned;
    pub const tovector = lapi.tovector;
    pub const toboolean = lapi.toboolean;
    pub const tolstring = lapi.tolstring;
    pub const tostring = lapi.tostring;
    pub const namecallatom = lapi.namecallatom;
    pub const namecallstr = lapi.namecallstr;
    pub const objlen = lapi.objlen;
    pub const strlen = lapi.strlen;
    pub const tocfunction = lapi.tocfunction;
    pub const tolightuserdata = lapi.tolightuserdata;
    pub const tolightuserdatatagged = lapi.tolightuserdatatagged;
    pub const touserdata = lapi.touserdata;
    pub const touserdatatagged = lapi.touserdatatagged;
    pub const userdatatag = lapi.userdatatag;
    pub const lightuserdatatag = lapi.lightuserdatatag;
    pub const tothread = lapi.tothread;
    pub const tobuffer = lapi.tobuffer;
    pub const topointer = lapi.topointer;

    //
    // push functions (C -> stack)
    //
    pub const pushnil = lapi.pushnil;
    pub const pushnumber = lapi.pushnumber;
    pub const pushinteger = lapi.pushinteger;
    pub const pushunsigned = lapi.pushunsigned;
    pub const pushvector = lapi.pushvector;
    pub const pushlstring = lapi.pushlstring;
    pub const pushstring = lapi.pushstring;
    pub const pushvfstring = lapi.pushvfstring;
    pub const pushfstring = lapi.pushfstring;
    pub const pushcclosurek = lapi.pushcclosurek;
    pub const pushcfunction = lapi.pushcfunction;
    pub const pushcclosure = lapi.pushcclosure;
    pub const pushboolean = lapi.pushboolean;
    pub const pushthread = lapi.pushthread;

    pub const pushlightuserdatatagged = lapi.pushlightuserdatatagged;
    pub const pushlightuserdata = lapi.pushlightuserdata;
    pub const newuserdatatagged = lapi.newuserdatatagged;
    pub const newuserdata = lapi.newuserdata;
    pub const newuserdatataggedwithmetatable = lapi.newuserdatataggedwithmetatable;
    pub const newuserdatadtor = lapi.newuserdatadtor;

    pub const newbuffer = lapi.newbuffer;

    //
    // get functions (Lua -> stack)
    //
    pub const gettable = lapi.gettable;
    pub const getfield = lapi.getfield;
    pub const getglobal = lapi.getglobal;
    pub const rawgetfield = lapi.rawgetfield;
    pub const rawget = lapi.rawget;
    pub const rawgeti = lapi.rawgeti;
    pub const createtable = lapi.createtable;
    pub const newtable = lapi.newtable;

    pub const setreadonly = lapi.setreadonly;
    pub const getreadonly = lapi.getreadonly;
    pub const setsafeenv = lapi.setsafeenv;

    pub const getmetatable = lapi.getmetatable;
    pub const getfenv = lapi.getfenv;

    //
    // set functions (stack -> Lua)
    //
    pub const settable = lapi.settable;
    pub const setfield = lapi.setfield;
    pub const setglobal = lapi.setglobal;
    pub const rawsetfield = lapi.rawsetfield;
    pub const rawset = lapi.rawset;
    pub const rawseti = lapi.rawseti;
    pub const setmetatable = lapi.setmetatable;
    pub const setfenv = lapi.setfenv;

    //
    // `load' and `call' functions (load and run Luau bytecode)
    //
    pub const call = lapi.call;
    pub const pcall = lapi.pcall;

    //
    // coroutine functions
    //
    pub const yield = ldo.yield;
    pub const @"break" = ldo.@"break";
    pub const resumethread = ldo.@"resume";
    pub const resumeerror = ldo.resumeerror;
    pub const status = lapi.status;
    pub const isyieldable = ldo.isyieldable;
    pub const getthreaddata = lapi.getthreaddata;
    pub const setthreaddata = lapi.setthreaddata;
    pub const costatus = lapi.costatus;

    //
    // garbage-collection function and options
    //
    pub const gc = lapi.gc;

    //
    // memory statistics
    // all allocated bytes are attributed to the memory category of the running thread (0..LUA_MEMORY_CATEGORIES-1)
    //
    pub const setmemcat = lapi.setmemcat;
    pub const totalbytes = lapi.totalbytes;

    //
    // miscellaneous functions
    //
    pub const raiseerror = lapi.@"error";

    pub const next = lapi.next;
    pub const rawiter = lapi.rawiter;

    pub const concat = lapi.concat;

    pub const getupvalue = lapi.getupvalue;
    pub const setupvalue = lapi.setupvalue;
    pub const ref = lapi.ref;
    pub const unref = lapi.unref;
    pub const setuserdatatag = lapi.setuserdatatag;
    pub const setuserdatadtor = lapi.setuserdatadtor;
    pub const getuserdatadtor = lapi.getuserdatadtor;
    pub const setuserdatametatable = lapi.setuserdatametatable;
    pub const getuserdatametatable = lapi.getuserdatametatable;
    pub const setlightuserdataname = lapi.setlightuserdataname;
    pub const getlightuserdataname = lapi.getlightuserdataname;
    pub const clonefunction = lapi.clonefunction;
    pub const cleartable = lapi.cleartable;
    pub const callbacks = lapi.callbacks;
    pub const getallocf = lapi.getallocf;

    // lapi
    pub const Atoobject = lapi.Atoobject;
    pub const Apushobject = lapi.Apushobject;

    // laux
    pub const LargerrorL = laux.LargerrorL;
    pub const Largerror = laux.Largerror;
    pub const Largcheck = laux.Largcheck;
    pub const LtypeerrorL = laux.LtypeerrorL;
    pub const Lwhere = laux.Lwhere;
    pub const LerrorL = laux.LerrorL;
    pub const Lcheckoption = laux.Lcheckoption;
    pub const Lnewmetatable = laux.Lnewmetatable;
    pub const Lgetmetatable = laux.Lgetmetatable;
    pub const Lcheckudata = laux.Lcheckudata;
    pub const Lcheckbuffer = laux.Lcheckbuffer;
    pub const Lcheckstack = laux.Lcheckstack;
    pub const Lchecktype = laux.Lchecktype;
    pub const Lcheckany = laux.Lcheckany;
    pub const Lchecklstring = laux.Lchecklstring;
    pub const Lcheckstring = laux.Lcheckstring;
    pub const Loptlstring = laux.Loptlstring;
    pub const Loptstring = laux.Loptstring;
    pub const Lchecknumber = laux.Lchecknumber;
    pub const Loptnumber = laux.Loptnumber;
    pub const Lcheckboolean = laux.Lcheckboolean;
    pub const Loptboolean = laux.Loptboolean;
    pub const Lcheckinteger = laux.Lcheckinteger;
    pub const Loptinteger = laux.Loptinteger;
    pub const Lcheckunsigned = laux.Lcheckunsigned;
    pub const Loptunsigned = laux.Loptunsigned;
    pub const Lcheckvector = laux.Lcheckvector;
    pub const Loptvector = laux.Loptvector;
    pub const Lgetmetafield = laux.Lgetmetafield;
    pub const Lcallmeta = laux.Lcallmeta;
    pub const Lregister = laux.Lregister;
    pub const Lfindtable = laux.Lfindtable;
    pub const Ltypename = laux.Ltypename;
    pub const Ltolstring = laux.Ltolstring;

    // ldebug
    pub const getargument = ldebug.getargument;
    pub const getlocal = ldebug.getlocal;
    pub const setlocal = ldebug.setlocal;
    pub const stackdepth = ldebug.stackdepth;
    pub const getinfo = ldebug.getinfo;
    pub const Gisnative = ldebug.Gisnative;
    pub const singlestep = ldebug.singlestep;
    pub const breakpoint = ldebug.breakpoint;
    pub const coverage = ldebug.coverage;
    pub const debugtrace = ldebug.debugtrace;

    // linit
    pub const Lopenlibs = linit.openlibs;
    pub const Lsandbox = linit.sandbox;
    pub const Lsandboxthread = linit.sandboxthread;

    // lobject
    pub const Opushfstring = lobject.pushfstring;

    // lvmload
    pub const load = lvmload.load;

    // libraries
    pub const openbase = lbaselib.open;
    pub const opencoroutine = lcorolib.open;
    pub const opentable = ltablib.open;
    pub const openos = loslib.open;
    pub const openstring = lstrlib.open;
    pub const openmath = lmathlib.open;
    pub const opendebug = ldblib.open;
    pub const openutf8 = lutf8lib.open;
    pub const openbit32 = lbitlib.open;
    pub const openbuffer = lbuflib.open;
    pub const openvector = lveclib.open;

    // zig api
    pub const Zpushfunction = zapi.Zpushfunction;
    pub const Zpushvaluekc = zapi.Zpushvaluekc;
    pub const Zpushvalue = zapi.Zpushvalue;
    pub const Zsetfield = zapi.Zsetfield;
    pub const Zsetfieldc = zapi.Zsetfieldc;
    pub const Zsetglobal = zapi.Zsetglobal;
    pub const Zsetglobalc = zapi.Zsetglobalc;
    pub const Zpushbuffer = zapi.Zpushbuffer;
    pub const Zresumeferror = zapi.Zresumeferror;
    pub const Zerror = zapi.Zerror;
    pub const Zerrorf = zapi.Zerrorf;

    pub inline fn deinit(L: *lua_State) void {
        L.close();
    }
};

pub const GCObject = extern union {
    gch: lobject.GCheader,
    ts: lobject.TString,
    u: lobject.Udata,
    cl: lobject.Closure,
    h: lobject.Table,
    p: lobject.Proto,
    uv: lobject.UpVal,
    th: lua_State, // thread
    buf: lobject.Buffer,

    pub inline fn tots(o: *GCObject) *lobject.TString {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.String));
        return &o.ts;
    }
    pub inline fn tou(o: *GCObject) *lobject.Udata {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.Userdata));
        return &o.u;
    }
    pub inline fn tocl(o: *GCObject) *lobject.Closure {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.Function));
        return &o.cl;
    }
    pub inline fn toh(o: *GCObject) *lobject.Table {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.Table));
        return &o.h;
    }
    pub inline fn top(o: *GCObject) *lobject.Proto {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.Proto));
        return &o.p;
    }
    pub inline fn touv(o: *GCObject) *lobject.UpVal {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.UpVal));
        return &o.uv;
    }
    pub inline fn toth(o: *GCObject) *state.lua_State {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.Thread));
        return &o.th;
    }
    pub inline fn tobuf(o: *GCObject) *lobject.Buffer {
        std.debug.assert(o.gch.ttype() == @intFromEnum(lua.Type.Buffer));
        return &o.buf;
    }
};

pub inline fn newstate(f: lua.Alloc, ud: ?*anyopaque) !*lua.State {
    if (c.lua_newstate(f, ud)) |s|
        return @ptrCast(@alignCast(s))
    else
        return error.OutOfMemory;
}
pub inline fn Lnewstate() !*lua.State {
    if (c.luaL_newstate()) |s|
        return @ptrCast(@alignCast(s))
    else
        return error.OutOfMemory;
}

pub inline fn close(L: *lua_State) void {
    c.lua_close(@ptrCast(L));
}

pub inline fn resetthread(L: *lua_State) void {
    c.lua_resetthread(@ptrCast(L));
}

pub fn isthreadreset(L: *lua_State) bool {
    return L.ci == L.base_ci and L.base == L.top and L.tstatus == @intFromEnum(lua.Status.Ok);
}
