const std = @import("std");
const builtin = @import("builtin");

const c = @import("c");

pub const Ast = struct {
    pub const Allocator = @import("Ast/Allocator.zig");
    pub const Lexer = @import("Ast/Lexer.zig");
    pub const Parser = @import("Ast/Parser.zig");

    test {
        _ = Ast.Allocator;
        _ = Ast.Lexer;
        _ = Ast.Parser;
    }
};

pub const Compiler = @import("Compiler/Compiler.zig");
test {
    _ = Compiler;
}

test {
    _ = Ast;
}

const config = @import("config");

/// The length of Luau vector values, either 3 or 4.
pub const VECTOR_SIZE = if (config.use_4_vector) 4 else 3;

pub const LUAU_VERSION = config.luau_version;

const c_FlagGroup = extern struct {
    names: [*c][*c]const u8,
    types: [*c]c_int,
    size: usize,
};

/// This function is defined in luau.cpp and must be called to define the assertion printer
extern "c" fn zig_registerAssertionHandler() void;

/// This function is defined in luau.cpp and ensures Zig uses the correct free when compiling luau code
extern "c" fn zig_luau_free(ptr: *anyopaque) void;
extern "c" fn zig_luau_freeflags(c_FlagGroup) void;

extern "c" fn zig_luau_setflag_bool([*]const u8, usize, bool) bool;
extern "c" fn zig_luau_setflag_int([*]const u8, usize, c_int) bool;
extern "c" fn zig_luau_getflag_bool([*]const u8, usize, *bool) bool;
extern "c" fn zig_luau_getflag_int([*]const u8, usize, *c_int) bool;

extern "c" fn zig_luau_getflags() c_FlagGroup;

// Internal API
extern "c" fn zig_luau_luaD_checkstack(*LuaState, c_int) void;
extern "c" fn zig_luau_expandstacklimit(*LuaState, c_int) void;
extern "c" fn zig_luau_luaG_isnative(*LuaState, c_int) c_int;

// NCG Workarounds - Minimal Debug Support for NCG
/// Luau.CodeGen mock __register_frame for a workaround Luau NCG
export fn __register_frame(frame: *const u8) void {
    _ = frame;
}
/// Luau.CodeGen mock __deregister_frame for a workaround Luau NCG
export fn __deregister_frame(frame: *const u8) void {
    _ = frame;
}

const Allocator = std.mem.Allocator;

// Types
//
// Luau constants and types are declared below in alphabetical order
// For constants that have a logical grouping (like Operators), Zig enums are used for type safety

/// The type of function that Luau uses for all internal allocations and frees
/// `data` is an opaque pointer to any data (the allocator), `ptr` is a pointer to the block being alloced/realloced/freed
/// `osize` is the original size or a code, and `nsize` is the new size
///
pub const AllocFn = *const fn (data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque;

/// Type for C userdata destructors
pub const CUserdataDtorFn = *const fn (userdata: *anyopaque) callconv(.C) void;
pub const ZigUserdataDtorFn = *const fn (data: *anyopaque) void;

/// Type for C useratom callback
pub const CUserAtomCallbackFn = *const fn (str: [*c]const u8, len: usize) callconv(.C) i16;

/// The internal Luau debug structure
const Debug = c.lua_Debug;

pub const DebugInfo = struct {
    source: [:0]const u8 = undefined,
    src_len: usize = 0,
    short_src: [c.LUA_IDSIZE:0]u8 = undefined,
    short_src_len: usize = 0,

    name: ?[:0]const u8 = undefined,
    what: FnType = undefined,

    current_line: ?i32 = null,
    line_defined: ?i32 = null,

    is_vararg: bool = false,

    pub const NameType = enum { global, local, method, field, upvalue, other };

    pub const FnType = enum { luau, c, main, tail };

    pub const Options = packed struct {
        f: bool = false,
        l: bool = false,
        n: bool = false,
        s: bool = false,
        u: bool = false,
        L: bool = false,

        fn toString(options: Options) [10:0]u8 {
            var str = [_:0]u8{0} ** 10;
            var index: u8 = 0;

            inline for (std.meta.fields(Options)) |field| {
                if (@field(options, field.name)) {
                    str[index] = field.name[0];
                    index += 1;
                }
            }
            while (index < str.len) : (index += 1) str[index] = 0;

            return str;
        }
    };
};

/// The superset of all errors returned from ziglua
pub const Error = error{
    /// A generic failure (used when a function can only fail in one way)
    Fail,
    /// A runtime error
    Runtime,
    /// A syntax error during precompilation
    Syntax,
    /// A memory allocation error
    Memory,
    /// An error while running the message handler
    MsgHandler,
    /// A file-releated error
    File,
};

/// Type for arrays of functions to be registered
pub const FnReg = struct {
    name: [:0]const u8,
    func: ?CFn,
};

/// The index of the global environment table
pub const GLOBALSINDEX = c.LUA_GLOBALSINDEX;
/// Index of the regsitry in the stack (pseudo-index)
pub const REGISTRYINDEX = c.LUA_REGISTRYINDEX;

/// Type for debugging hook functions
// pub const CHookFn = *const fn (state: ?*LuaState, ar: ?*Debug) callconv(.C) void;

// /// Hook event codes
// pub const Hook = c.lua_Hook;

/// Type of integers in Luau (typically an i64)
pub const Integer = c.lua_Integer;

/// Type for continuation-function contexts (usually isize)
pub const Context = isize;

/// Type for continuation functions
// pub const CContFn = *const fn (state: ?*LuaState, status: c_int, ctx: Context) callconv(.C) c_int;

pub const Libs = packed struct {
    base: bool = false,
    package: bool = false,
    string: bool = false,
    utf8: bool = false,
    table: bool = false,
    math: bool = false,
    io: bool = false,
    os: bool = false,
    debug: bool = false,
    bit32: bool = false,
    buffer: bool = false,
    vector: bool = false,
};

/// The type of the opaque structure that points to a thread and the state of a Luau interpreter
pub const LuaState = c.lua_State;

/// Luau types
/// Must be a signed integer because LuaType.none is -1
pub const LuaType = enum(i5) {
    none = c.LUA_TNONE,
    nil = c.LUA_TNIL,
    boolean = c.LUA_TBOOLEAN,
    light_userdata = c.LUA_TLIGHTUSERDATA,
    number = c.LUA_TNUMBER,
    vector = c.LUA_TVECTOR,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    function = c.LUA_TFUNCTION,
    userdata = c.LUA_TUSERDATA,
    thread = c.LUA_TTHREAD,
    buffer = c.LUA_TBUFFER,
};

pub const LuaObject = union(LuaType) {
    none: void,
    nil: void,

    boolean: bool,
    light_userdata: *anyopaque,

    number: Number,

    vector: []const f32,
    string: []const u8,

    table: void,
    function: void,

    userdata: *anyopaque,

    thread: void,

    buffer: []u8,
};

/// Modes used for `Luau.load()`
pub const Mode = enum(u2) { binary, text, binary_text };

/// The minimum Luau stack available to a function
pub const MINSTACK = c.LUA_MINSTACK;

/// Option for multiple returns in `Luau.protectedCall()` and `Luau.call()`
pub const MULTRET = c.LUA_MULTRET;

/// Type of floats in Luau (typically an f64)
pub const Number = c.lua_Number;

/// The unsigned version of Integer
pub const Unsigned = c.lua_Unsigned;

/// The type of the reader function used by `Luau.load()`
// pub const CReaderFn = *const fn (state: ?*LuaState, data: ?*anyopaque, size: [*c]usize) callconv(.C) [*c]const u8;

/// The possible status of a call to `Luau.resumeThread`
pub const ResumeStatus = enum(u1) {
    ok = StatusCode.ok,
    yield = StatusCode.yield,
};

/// Reference constants
pub const ref_nil = c.LUA_REFNIL;
pub const ref_no = c.LUA_NOREF;

/// Status that a thread can be in
/// Usually errors are reported by a Zig error rather than a status enum value
pub const Status = enum(u3) {
    ok = StatusCode.ok,
    yield = StatusCode.yield,
    err_runtime = StatusCode.err_runtime,
    err_syntax = StatusCode.err_syntax,
    err_memory = StatusCode.err_memory,
    err_error = StatusCode.err_error,
};

/// Coroutine Status a thread can be in.
pub const CoroutineStatus = enum(u3) {
    running = CoroutineStatusCode.running,
    suspended = CoroutineStatusCode.suspended,
    normal = CoroutineStatusCode.normal,
    finished = CoroutineStatusCode.finished,
    err = CoroutineStatusCode.err,
};

/// Status codes
/// Not public, because typically Status.ok is returned from a function implicitly;
/// Any function that returns an error usually returns a Zig error, and a void return
/// is an implicit Status.ok.
/// In the rare case that the status code is required from a function, an enum is
/// used for that specific function's return type
/// TODO: see where this is used and check if a null can be used instead
const StatusCode = struct {
    pub const ok = c.LUA_OK;
    pub const yield = c.LUA_YIELD;
    pub const err_runtime = c.LUA_ERRRUN;
    pub const err_syntax = c.LUA_ERRSYNTAX;
    pub const err_memory = c.LUA_ERRMEM;
    pub const err_error = c.LUA_ERRERR;

    pub const err_gcmm = unreachable;
};

const CoroutineStatusCode = struct {
    pub const running = c.LUA_CORUN;
    pub const suspended = c.LUA_COSUS;
    pub const normal = c.LUA_CONOR;
    pub const finished = c.LUA_COFIN;
    pub const err = c.LUA_COERR;
};

/// The type of warning functions used by Luau to emit warnings
// pub const CWarnFn = @compileError("CWarnFn not defined");

/// The type of the writer function used by `Luau.dump()`
// pub const CWriterFn = *const fn (state: ?*LuaState, buf: ?*const anyopaque, size: usize, data: ?*anyopaque) callconv(.C) c_int;

/// For bundling a parsed value with an arena allocator
/// Copied from std.json.Parsed
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

pub fn isNoneOrNil(t: LuaType) bool {
    return t == .none or t == .nil;
}

pub const Flags = struct {
    allocator: Allocator,
    flags: []Flag,

    pub const FlagType = enum {
        boolean,
        integer,
    };

    pub const Flag = struct {
        name: []const u8,
        type: FlagType,
    };

    pub fn setBoolean(name: []const u8, value: bool) !void {
        if (!zig_luau_setflag_bool(name.ptr, name.len, value)) return error.UnknownFlag;
    }

    pub fn setInteger(name: []const u8, value: i32) !void {
        if (!zig_luau_setflag_int(name.ptr, name.len, @intCast(value))) return error.UnknownFlag;
    }

    pub fn getBoolean(name: []const u8) !bool {
        var value: bool = undefined;
        if (!zig_luau_getflag_bool(name.ptr, name.len, &value)) return error.UnknownFlag;
        return value;
    }

    pub fn getInteger(name: []const u8) !i32 {
        var value: c_int = undefined;
        if (!zig_luau_getflag_int(name.ptr, name.len, &value)) return error.UnknownFlag;
        return @intCast(value);
    }

    pub fn getFlags(allocator: Allocator) !Flags {
        const cflags = zig_luau_getflags();
        defer zig_luau_freeflags(cflags);

        var list = std.ArrayList(Flag).init(allocator);
        defer list.deinit();
        errdefer for (list.items) |flag| allocator.free(flag.name);

        const names = cflags.names;

        for (0..cflags.size) |i| {
            const name = try allocator.dupe(u8, std.mem.span(names[i]));
            errdefer allocator.free(name);
            const ttype: FlagType = @enumFromInt(cflags.types[i]);
            try list.append(.{
                .name = name,
                .type = ttype,
            });
        }

        return .{
            .allocator = allocator,
            .flags = try list.toOwnedSlice(),
        };
    }

    pub fn deinit(self: Flags) void {
        for (self.flags) |flag| {
            self.allocator.free(flag.name);
        }
        self.allocator.free(self.flags);
    }
};

pub const Metamethods = struct {
    pub const index = "__index";
    pub const newindex = "__newindex";
    pub const call = "__call";
    pub const concat = "__concat";
    pub const unm = "__unm";
    pub const add = "__add";
    pub const sub = "__sub";
    pub const mul = "__mul";
    pub const div = "__div";
    pub const idiv = "__idiv";
    pub const mod = "__mod";
    pub const pow = "__pow";
    pub const tostring = "__tostring";
    pub const metatable = "__metatable";
    pub const eq = "__eq";
    pub const lt = "__lt";
    pub const le = "__le";
    pub const mode = "__mode";
    pub const len = "__len";
    pub const iter = "__iter";
    pub const typename = "__type";
    pub const namecall = "__namecall";
};

pub const CNative = c;
pub const State = struct {
    pub fn LuauToState(luau: *Luau) *LuaState {
        return @ptrCast(luau);
    }
    pub fn StateToLuau(state: *LuaState) *Luau {
        return @ptrCast(state);
    }
};

const stateCast = State.LuauToState;

pub const CodeGen = if (!builtin.cpu.arch.isWasm()) struct {
    pub fn Supported() bool {
        return c.luau_codegen_supported() == 1;
    }
    pub fn Create(luau: *Luau) void {
        c.luau_codegen_create(stateCast(luau));
    }
    pub fn Compile(luau: *Luau, idx: i32) void {
        c.luau_codegen_compile(stateCast(luau), @intCast(idx));
    }
} else struct {
    pub fn Supported() bool {
        return false;
    }
    pub fn Create(_: *Luau) void {
        @panic("CodeGen is not supported on wasm");
    }
    pub fn Compile(_: *Luau, _: i32) void {
        @panic("CodeGen is not supported on wasm");
    }
};

/// A Zig wrapper around the Luau C API
/// Represents a Luau state or thread and contains the entire state of the Luau interpreter
pub const Luau = struct {
    const alignment = @alignOf(std.c.max_align_t);

    /// Allows Luau to allocate memory using a Zig allocator passed in via data.
    fn alloc(data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*align(alignment) anyopaque {
        // just like malloc() returns a pointer "which is suitably aligned for any built-in type",
        // the memory allocated by this function should also be aligned for any type that Lua may
        // desire to allocate. use the largest alignment for the target
        const allocator_ptr: *Allocator = @ptrCast(@alignCast(data.?));

        if (@as(?[*]align(alignment) u8, @ptrCast(@alignCast(ptr)))) |prev_ptr| {
            const prev_slice = prev_ptr[0..osize];

            // when nsize is zero the allocator must behave like free and return null
            if (nsize == 0) {
                allocator_ptr.free(prev_slice);
                return null;
            }

            // when nsize is not zero the allocator must behave like realloc
            const new_ptr = allocator_ptr.realloc(prev_slice, nsize) catch return null;
            return new_ptr.ptr;
        } else if (nsize == 0) {
            return null;
        } else {
            // ptr is null, allocate a new block of memory
            const new_ptr = allocator_ptr.alignedAlloc(u8, alignment, nsize) catch return null;
            return new_ptr.ptr;
        }
    }

    /// Initialize a Luau state with the given allocator
    pub fn init(allocator_ptr: *const Allocator) !*Luau {
        zig_registerAssertionHandler();

        // @constCast() is safe here because Lua does not mutate the pointer internally
        if (c.lua_newstate(alloc, @constCast(allocator_ptr))) |state| {
            return @ptrCast(state);
        } else return error.Memory;
    }

    /// Deinitialize a Luau state and free all memory
    pub fn deinit(luau: *Luau) void {
        luau.close();
    }

    pub fn allocator(luau: *Luau) Allocator {
        var data: ?*Allocator = undefined;
        _ = luau.getAllocFn(@ptrCast(&data));

        if (data) |allocator_ptr| {
            // Although the Allocator is passed to Lua as a pointer, return a
            // copy to make use more convenient.
            return allocator_ptr.*;
        }

        @panic("Lua.allocator() invalid on Lua states created without a Zig allocator");
    }

    pub inline fn absIndex(luau: *Luau, index: i32) i32 {
        return c.lua_absindex(@ptrCast(luau), index);
    }

    /// Calls a function (or any callable value)
    /// First push the function to be called onto the stack. Then push any arguments onto the stack.
    /// Then call this function. All arguments and the function value are popped, and any results
    /// are pushed onto the stack.
    pub inline fn call(luau: *Luau, num_args: i32, num_results: i32) void {
        c.lua_call(stateCast(luau), num_args, num_results);
    }

    /// Ensures that the stack has space for at least n extra arguments
    /// Returns an error if more stack space cannot be allocated
    /// Never shrinks the stack
    pub fn checkStack(luau: *Luau, n: i32) !void {
        if (c.lua_checkstack(stateCast(luau), n) == 0) return error.Fail;
    }

    /// Release all Luau objects in the state and free all dynamic memory
    pub inline fn close(luau: *Luau) void {
        c.lua_close(stateCast(luau));
    }

    /// Concatenates the n values at the top of the stack, pops them, and leaves the result at the top
    /// If the number of values is 1, the result is a single value on the stack (nothing changes)
    /// If the number of values is 0, the result is the empty string
    pub inline fn concat(luau: *Luau, n: i32) void {
        c.lua_concat(stateCast(luau), n);
    }

    /// Creates a new empty table and pushes onto the stack
    /// num_arr is a hint for how many elements the table will have as a sequence
    /// num_rec is a hint for how many other elements the table will have
    /// Luau may preallocate memory for the table based on the hints
    pub inline fn createTable(luau: *Luau, num_arr: i32, num_rec: i32) void {
        c.lua_createtable(stateCast(luau), num_arr, num_rec);
    }

    /// Returns true if the two values at the indexes are equal following the semantics of the
    /// Luau == operator.
    pub inline fn equal(luau: *Luau, index1: i32, index2: i32) bool {
        return c.lua_equal(stateCast(luau), index1, index2) == 1;
    }

    /// Raises a Luau error using the value at the top of the stack as the error object
    /// Does a longjump and therefore never returns
    pub inline fn raiseError(luau: *Luau) noreturn {
        _ = c.lua_error(stateCast(luau));
        unreachable;
    }

    /// Perform a full garbage-collection cycle
    pub inline fn gcCollect(luau: *Luau) void {
        _ = c.lua_gc(stateCast(luau), c.LUA_GCCOLLECT, 0);
    }

    /// Stops the garbage collector
    pub inline fn gcStop(luau: *Luau) void {
        _ = c.lua_gc(stateCast(luau), c.LUA_GCSTOP, 0);
    }

    /// Restarts the garbage collector
    pub inline fn gcRestart(luau: *Luau) void {
        _ = c.lua_gc(stateCast(luau), c.LUA_GCRESTART, 0);
    }

    /// Performs an incremental step of garbage collection corresponding to the allocation of step_size Kbytes
    pub inline fn gcStep(luau: *Luau) void {
        _ = c.lua_gc(stateCast(luau), c.LUA_GCSTEP, 0);
    }

    /// Returns the current amount of memory (in Kbytes) in use by Luau
    pub inline fn gcCount(luau: *Luau) i32 {
        return c.lua_gc(stateCast(luau), c.LUA_GCCOUNT, 0);
    }

    /// Returns the remainder of dividing the current amount of bytes of memory in use by Luau by 1024
    pub inline fn gcCountB(luau: *Luau) i32 {
        return c.lua_gc(stateCast(luau), c.LUA_GCCOUNTB, 0);
    }

    /// Sets `multiplier` as the new value for the step multiplier of the collector
    /// Returns the previous value of the step multiplier
    pub inline fn gcSetStepMul(luau: *Luau, multiplier: i32) i32 {
        return c.lua_gc(stateCast(luau), c.LUA_GCSETSTEPMUL, multiplier);
    }

    pub inline fn gcIsRunning(luau: *Luau) bool {
        return c.lua_gc(stateCast(luau), c.LUA_GCISRUNNING, 0) == 1;
    }

    pub inline fn gcSetGoal(luau: *Luau, goal: i32) i32 {
        return c.lua_gc(stateCast(luau), c.LUA_GCSETGOAL, goal);
    }

    pub inline fn gcSetStepSize(luau: *Luau, size: i32) i32 {
        return c.lua_gc(stateCast(luau), c.LUA_GCSETSTEPSIZE, size);
    }

    pub inline fn newUserdataTagged(luau: *Luau, comptime T: type, tag: c_int) *T {
        // safe to .? because this function throws a Luau error on out of memory
        return opaqueCast(T, c.lua_newuserdatatagged(stateCast(luau), @sizeOf(T), tag).?);
    }

    pub inline fn newUserdataTaggedWithMetatable(luau: *Luau, comptime T: type, tag: c_int) *T {
        // safe to .? because this function throws a Luau error on out of memory
        return opaqueCast(T, c.lua_newuserdatataggedwithmetatable(stateCast(luau), @sizeOf(T), tag).?);
    }

    pub inline fn newUserdataDtor(luau: *Luau, comptime T: type, comptime dtorfn: *const fn (ptr: *T) void) *T {
        const dtorCfn = struct {
            fn inner(ptr: ?*anyopaque) callconv(.C) void {
                if (ptr) |p| @call(.always_inline, dtorfn, .{opaqueCast(T, p)});
            }
        }.inner;
        // safe to .? because this function throws a Lua error on out of memory
        // so the returned pointer should never be null
        return opaqueCast(T, c.lua_newuserdatadtor(stateCast(luau), @sizeOf(T), @ptrCast(&dtorCfn)).?);
    }

    pub fn setUserdataDtor(luau: *Luau, comptime T: type, tag: c_int, comptime dtorfn: ?*const fn (L: *Luau, ptr: *T) void) void {
        if (dtorfn) |dtor| {
            const dtorCfn = struct {
                fn inner(state: ?*LuaState, ptr: ?*anyopaque) callconv(.C) void {
                    if (ptr) |p| @call(.always_inline, dtor, .{ @as(*Luau, @ptrCast(state.?)), opaqueCast(T, p) });
                }
            }.inner;
            c.lua_setuserdatadtor(stateCast(luau), tag, dtorCfn);
        } else c.lua_setuserdatadtor(stateCast(luau), tag, null);
    }

    /// Sets metatable to tag, Pops the stack
    pub inline fn setUserdataMetatable(luau: *Luau, tag: c_int, idx: i32) void {
        c.lua_setuserdatametatable(stateCast(luau), tag, idx);
    }

    pub inline fn setUserdataTag(luau: *Luau, idx: c_int, tag: c_int) void {
        c.lua_setuserdatatag(stateCast(luau), idx, tag);
    }

    pub inline fn getUserdataDtor(luau: *Luau, tag: c_int) c.lua_Destructor {
        return c.lua_getuserdatadtor(stateCast(luau), tag);
    }

    pub inline fn getUserdataTag(luau: *Luau, index: i32) c_int {
        return c.lua_userdatatag(stateCast(luau), index);
    }

    pub fn getLightUserdataName(luau: *Luau, tag: c_int) ![*:0]const u8 {
        if (c.lua_getlightuserdataname(stateCast(luau), tag)) |name| return name;
        return error.Fail;
    }

    pub inline fn setLightUserdataName(luau: *Luau, tag: c_int, name: [:0]const u8) void {
        c.lua_setlightuserdataname(stateCast(luau), tag, name.ptr);
    }

    pub inline fn setThreadData(luau: *Luau, comptime T: type, data: *T) void {
        c.lua_setthreaddata(stateCast(luau), opaqueCast(anyopaque, data));
    }

    pub fn getThreadData(luau: *Luau, comptime T: type) !*T {
        if (c.lua_getthreaddata(stateCast(luau))) |ptr| return opaqueCast(T, ptr);
        return error.Fail;
    }

    /// Returns the memory allocation function of a given state
    /// If data is not null, it is set to the opaque pointer given when the allocator function was set
    pub inline fn getAllocFn(luau: *Luau, data: ?**anyopaque) AllocFn {
        // Assert cannot be null because it is impossible (and not useful) to pass null
        // to the functions that set the allocator (setallocf and newstate)
        return c.lua_getallocf(stateCast(luau), @ptrCast(data)).?;
    }

    /// Pushes onto the stack the environment table of the value at the given index.
    pub inline fn getFenv(luau: *Luau, index: i32) void {
        c.lua_getfenv(stateCast(luau), index);
    }

    /// Pushes onto the stack the value t[key] where t is the value at the given index
    pub inline fn getField(luau: *Luau, index: i32, key: [:0]const u8) LuaType {
        return @enumFromInt(c.lua_getfield(stateCast(luau), index, key.ptr));
    }

    fn toLuaObject(luau: *Luau, t: LuaType) !LuaObject {
        switch (t) {
            .none => return .{ .none = @as(void, undefined) },
            .nil => return .{ .nil = @as(void, undefined) },
            .boolean => return .{ .boolean = luau.toBoolean(-1) },
            .light_userdata => return .{ .light_userdata = try luau.toUserdata(anyopaque, -1) },
            .number => return .{ .number = try luau.toNumber(-1) },
            .vector => return .{ .vector = try luau.toVector(-1) },
            .string => return .{ .string = try luau.toString(-1) },
            .table => return .{ .table = @as(void, undefined) },
            .function => return .{ .function = @as(void, undefined) },
            .userdata => return .{ .userdata = try luau.toUserdata(anyopaque, -1) },
            .thread => return .{ .thread = @as(void, undefined) },
            .buffer => return .{ .buffer = try luau.toBuffer(-1) },
        }
        @panic("Unhandled object cases");
    }

    pub fn getFieldObj(luau: *Luau, index: i32, key: [:0]const u8) !LuaObject {
        errdefer luau.pop(1);
        return try luau.toLuaObject(luau.getField(index, key));
    }

    pub fn getFieldObjConsumed(luau: *Luau, index: i32, key: [:0]const u8) !LuaObject {
        defer luau.pop(1);
        return try luau.toLuaObject(luau.getField(index, key));
    }

    /// Pushes onto the stack the value of the global name
    pub inline fn getGlobal(luau: *Luau, name: [:0]const u8) LuaType {
        return luau.getField(GLOBALSINDEX, name);
    }

    pub fn getGlobalObj(luau: *Luau, key: [:0]const u8) !LuaObject {
        errdefer luau.pop(1);
        return try luau.toLuaObject(luau.getGlobal(key));
    }

    pub fn getGlobalObjConsumed(luau: *Luau, key: [:0]const u8) !LuaObject {
        defer luau.pop(1);
        return try luau.toLuaObject(luau.getGlobal(key));
    }

    /// If the value at the given index has a metatable, the function pushes that metatable onto the stack, returning true
    /// Otherwise false is returned
    pub inline fn getMetatable(luau: *Luau, index: i32) bool {
        return c.lua_getmetatable(stateCast(luau), index) != 0;
    }

    /// Pushes onto the stack the value t[k] where t is the value at the given index and k is the value on the top of the stack
    pub inline fn getTable(luau: *Luau, index: i32) LuaType {
        return @enumFromInt(c.lua_gettable(stateCast(luau), index));
    }

    /// Returns a boolean indicating if the lua object at index is read-only
    pub inline fn getReadOnly(luau: *Luau, index: i32) bool {
        return c.lua_getreadonly(stateCast(luau), index) == 1;
    }

    /// Returns the index of the top element in the stack
    /// Because indices start at 1, the result is also equal to the number of elements in the stack
    pub inline fn getTop(luau: *Luau) i32 {
        return c.lua_gettop(stateCast(luau));
    }

    /// Moves the top element into the given valid `index` shifting up any elements to make room
    pub inline fn insert(luau: *Luau, index: i32) void {
        // translate-c cannot translate this macro correctly
        c.lua_insert(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is a boolean
    pub inline fn isBoolean(luau: *Luau, index: i32) bool {
        return c.lua_isboolean(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is a CFn
    pub inline fn isCFunction(luau: *Luau, index: i32) bool {
        return c.lua_iscfunction(stateCast(luau), index) != 0;
    }

    /// Returns true if the value at the given index is a function (C or Luau)
    pub inline fn isFunction(luau: *Luau, index: i32) bool {
        return c.lua_isfunction(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is a light userdata
    pub inline fn isLightUserdata(luau: *Luau, index: i32) bool {
        return c.lua_islightuserdata(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is nil
    pub inline fn isNil(luau: *Luau, index: i32) bool {
        return c.lua_isnil(stateCast(luau), index);
    }

    /// Returns true if the given index is not valid
    pub inline fn isNone(luau: *Luau, index: i32) bool {
        return c.lua_isnone(stateCast(luau), index);
    }

    /// Returns true if the given index is not valid or if the value at the index is nil
    pub inline fn isNoneOrNil(luau: *Luau, index: i32) bool {
        return c.lua_isnoneornil(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is a number
    pub inline fn isNumber(luau: *Luau, index: i32) bool {
        return c.lua_isnumber(stateCast(luau), index) != 0;
    }

    /// Returns true if the value at the given index is a string
    pub inline fn isString(luau: *Luau, index: i32) bool {
        return c.lua_isstring(stateCast(luau), index) != 0;
    }

    /// Returns true if the value at the given index is a table
    pub inline fn isTable(luau: *Luau, index: i32) bool {
        return c.lua_istable(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is a thread
    pub inline fn isThread(luau: *Luau, index: i32) bool {
        return c.lua_isthread(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is a userdata (full or light)
    pub inline fn isUserdata(luau: *Luau, index: i32) bool {
        return c.lua_isuserdata(stateCast(luau), index) != 0;
    }

    /// Returns true if the value at the given index is a buffer
    pub inline fn isBuffer(luau: *Luau, index: i32) bool {
        return c.lua_isbuffer(stateCast(luau), index);
    }

    /// Returns true if the value at the given index is a vector
    pub inline fn isVector(luau: *Luau, index: i32) bool {
        return c.lua_isvector(stateCast(luau), index);
    }

    pub inline fn isNative(luau: *Luau, level: i32) bool {
        return zig_luau_luaG_isnative(stateCast(luau), level) == 1;
    }

    /// Returns true if the value at index1 is smaller than the value at index2, following the
    /// semantics of the Luau < operator.
    pub inline fn lessThan(luau: *Luau, index1: i32, index2: i32) bool {
        return c.lua_lessthan(stateCast(luau), index1, index2) == 1;
    }

    /// Creates a new independent state and returns its main thread
    pub fn newState(alloc_fn: AllocFn, data: ?*const anyopaque) !*Luau {
        zig_registerAssertionHandler();

        if (c.lua_newstate(alloc_fn, @constCast(data))) |state| {
            return @ptrCast(state);
        } else return error.Memory;
    }

    /// Creates a new empty table and pushes it onto the stack
    /// Equivalent to createTable(0, 0)
    pub inline fn newTable(luau: *Luau) void {
        c.lua_newtable(stateCast(luau));
    }

    /// Creates a new thread, pushes it on the stack, and returns a Luau state that represents the new thread
    /// The new thread shares the global environment but has a separate execution stack
    pub inline fn newThread(luau: *Luau) *Luau {
        return @ptrCast(c.lua_newthread(stateCast(luau)).?);
    }

    /// This function allocates a new userdata of the given type.
    /// Returns a pointer to the Luau-owned data
    pub inline fn newUserdata(luau: *Luau, comptime T: type) *T {
        // safe to .? because this function throws a Luau error on out of memory
        // so the returned pointer should never be null
        return opaqueCast(T, c.lua_newuserdata(stateCast(luau), @sizeOf(T)).?);
    }

    /// This function creates and pushes a slice of full userdata onto the stack.
    /// Returns a slice to the Luau-owned data.
    pub fn newUserdataSlice(luau: *Luau, comptime T: type, size: usize) []T {
        // safe to .? because this function throws a Luau error on out of memory
        const ptr = c.lua_newuserdata(stateCast(luau), @sizeOf(T) * size).?;
        return @as([*]T, @ptrCast(@alignCast(ptr)))[0..size];
    }

    pub fn newBuffer(luau: *Luau, size: usize) []u8 {
        // safe to .? because this function throws a Luau error on out of memory
        const ptr = c.lua_newbuffer(stateCast(luau), size).?;
        return @as([*]u8, @ptrCast(@alignCast(ptr)))[0..size];
    }

    /// Pops a key from the stack, and pushes a key-value pair from the table at the given index.
    pub inline fn next(luau: *Luau, index: i32) bool {
        return c.lua_next(stateCast(luau), index) != 0;
    }

    /// Returns the length of the value at the given index
    pub inline fn objLen(luau: *Luau, index: i32) i32 {
        return c.lua_objlen(stateCast(luau), index);
    }

    /// Calls a function (or callable object) in protected mode
    pub fn pcall(luau: *Luau, num_args: i32, num_results: i32, err_func: i32) !void {
        // The translate-c version of lua_pcall does not type-check so we must rewrite it
        // (macros don't always translate well with translate-c)
        const ret = c.lua_pcall(stateCast(luau), num_args, num_results, err_func);
        switch (ret) {
            StatusCode.ok => return,
            StatusCode.err_runtime => return error.Runtime,
            StatusCode.err_memory => return error.Memory,
            StatusCode.err_error => return error.MsgHandler,
            else => unreachable,
        }
    }

    /// Pops `n` elements from the top of the stack
    pub inline fn pop(luau: *Luau, n: i32) void {
        luau.setTop(-n - 1);
    }

    /// Pushes a boolean value with value `b` onto the stack
    pub inline fn pushBoolean(luau: *Luau, b: bool) void {
        c.lua_pushboolean(stateCast(luau), @intFromBool(b));
    }

    /// Pushes a new Closure onto the stack
    /// `n` tells how many upvalues this function will have
    pub inline fn pushClosure(luau: *Luau, c_fn: CFn, name: [:0]const u8, n: i32) void {
        c.lua_pushcclosurek(stateCast(luau), c_fn, name, n, null);
    }

    /// Pushes a function onto the stack.
    /// Equivalent to pushClosure with no upvalues
    pub inline fn pushFunction(luau: *Luau, comptime zig_fn: anytype, name: [:0]const u8) void {
        luau.pushClosure(toCFn(zig_fn), name, 0);
    }
    pub inline fn pushCFunction(luau: *Luau, c_fn: CFn, name: [:0]const u8) void {
        luau.pushClosure(c_fn, name, 0);
    }

    /// Push a formatted string onto the stack and return a pointer to the string
    pub inline fn pushFString(luau: *Luau, fmt: [:0]const u8, args: anytype) [*:0]const u8 {
        return @call(.auto, c.lua_pushfstringL, .{ stateCast(luau), fmt.ptr } ++ args);
    }

    inline fn isArgComptimeKnown(value: anytype) bool {
        return @typeInfo(@TypeOf(.{value})).@"struct".fields[0].is_comptime;
    }

    /// Push a zig comptime formatted string onto the stack
    pub fn pushFmtString(luau: *Luau, comptime fmt: []const u8, args: anytype) !void {
        if (isArgComptimeKnown(args))
            luau.pushLString(std.fmt.comptimePrint(fmt, args))
        else {
            const lua_allocator = luau.allocator();
            const str = try std.fmt.allocPrint(lua_allocator, fmt, args);
            defer lua_allocator.free(str);
            luau.pushLString(str);
        }
    }

    /// Pushes a zero-terminated string onto the stack
    /// Luau makes a copy of the string so `str` may be freed immediately after return
    pub inline fn pushString(luau: *Luau, str: [:0]const u8) void {
        c.lua_pushstring(stateCast(luau), str.ptr);
    }

    /// Pushes the bytes onto the stack
    pub inline fn pushLString(luau: *Luau, bytes: []const u8) void {
        c.lua_pushlstring(stateCast(luau), bytes.ptr, bytes.len);
    }

    /// Pushes the bytes onto the stack as buffer
    pub fn pushBuffer(luau: *Luau, bytes: []const u8) void {
        const buf = luau.newBuffer(bytes.len);
        @memcpy(buf, bytes);
    }

    /// Pushes an integer with value `n` onto the stack
    pub inline fn pushInteger(luau: *Luau, n: Integer) void {
        c.lua_pushinteger(stateCast(luau), n);
    }

    /// Pushes a float with value `n` onto the stack
    pub inline fn pushNumber(luau: *Luau, n: Number) void {
        c.lua_pushnumber(stateCast(luau), n);
    }

    /// Pushes a usigned integer with value `n` onto the stack
    pub inline fn pushUnsigned(luau: *Luau, n: Unsigned) void {
        c.lua_pushunsigned(stateCast(luau), n);
    }

    /// Pushes a light userdata onto the stack
    pub inline fn pushLightUserdata(luau: *Luau, ptr: *anyopaque) void {
        c.lua_pushlightuserdata(stateCast(luau), ptr);
    }

    /// Pushes a nil value onto the stack
    pub inline fn pushNil(luau: *Luau) void {
        c.lua_pushnil(stateCast(luau));
    }

    /// Pushes this thread onto the stack
    /// Returns true if this thread is the main thread of its state
    pub inline fn pushThread(luau: *Luau) bool {
        return c.lua_pushthread(stateCast(luau)) != 0;
    }

    pub inline fn pushVector(luau: *Luau, x: f32, y: f32, z: f32, w: ?f32) void {
        if (VECTOR_SIZE == 3) {
            c.lua_pushvector(stateCast(luau), x, y, z);
        } else {
            c.lua_pushvector(stateCast(luau), x, y, z, w orelse 0.0);
        }
    }

    /// Pushes a copy of the element at the given index onto the stack
    pub inline fn pushValue(luau: *Luau, index: i32) void {
        c.lua_pushvalue(stateCast(luau), index);
    }

    /// Returns true if the two values in indices `index1` and `index2` are primitively equal
    /// Bypasses __eq metamethods
    /// Returns false if not equal, or if any index is invalid
    pub inline fn rawEqual(luau: *Luau, index1: i32, index2: i32) bool {
        return c.lua_rawequal(stateCast(luau), index1, index2) != 0;
    }

    /// Similar to `Luau.getTable()` but does a raw access (without metamethods)
    pub inline fn rawGetTable(luau: *Luau, index: i32) LuaType {
        return @enumFromInt(c.lua_rawget(stateCast(luau), index));
    }

    /// Pushes onto the stack the value t[n], where `t` is the table at the given `index`
    /// Returns the `LuaType` of the pushed value
    pub inline fn rawGetIndex(luau: *Luau, index: i32, n: i32) LuaType {
        return @enumFromInt(c.lua_rawgeti(stateCast(luau), index, n));
    }

    /// Similar to `Luau.setTable()` but does a raw assignment (without metamethods)
    pub inline fn rawSetTable(luau: *Luau, index: i32) void {
        c.lua_rawset(stateCast(luau), index);
    }

    /// Does the equivalent of t[`i`] = v where t is the table at the given `index`
    /// and v is the value at the top of the stack
    /// Pops the value from the stack. Does not use __newindex metavalue
    pub inline fn rawSetIndex(luau: *Luau, index: i32, i: i32) void {
        c.lua_rawseti(stateCast(luau), index, i);
    }

    /// Sets the C function f as the new value of global name
    pub fn register(luau: *Luau, name: [:0]const u8, comptime zig_fn: anytype) void {
        // translate-c failure
        luau.pushFunction(zig_fn, name);
        luau.setGlobal(name);
    }

    /// Removes the element at the given valid `index` shifting down elements to fill the gap
    pub inline fn remove(luau: *Luau, index: i32) void {
        c.lua_remove(stateCast(luau), index);
    }

    /// Moves the top element into the given valid `index` without shifting any elements,
    /// then pops the top element
    pub inline fn replace(luau: *Luau, index: i32) void {
        c.lua_replace(stateCast(luau), index);
    }

    /// Starts and resumes a coroutine in the thread
    pub fn resumeThread(luau: *Luau, from: ?*Luau, num_args: i32) !ResumeStatus {
        const thread_status = c.lua_resume(
            stateCast(luau),
            if (from) |from_val|
                stateCast(from_val)
            else
                null,
            num_args,
        );
        switch (thread_status) {
            StatusCode.err_runtime => return error.Runtime,
            StatusCode.err_memory => return error.Memory,
            StatusCode.err_error => return error.MsgHandler,
            else => return @enumFromInt(thread_status),
        }
    }

    /// Yielded thread is resumed with an error, and the error object is at the top of the stack
    pub fn resumeThreadError(luau: *Luau, from: ?*Luau) !ResumeStatus {
        const thread_status = c.lua_resumeerror(
            stateCast(luau),
            if (from) |state|
                stateCast(state)
            else
                null,
        );
        switch (thread_status) {
            StatusCode.err_runtime => return error.Runtime,
            StatusCode.err_memory => return error.Memory,
            StatusCode.err_error => return error.MsgHandler,
            else => return @enumFromInt(thread_status),
        }
    }

    /// Resume a thread with an error and a zig comptime formatted message
    pub fn resumeThreadErrorFmt(luau: *Luau, from: ?*Luau, comptime fmt: []const u8, args: anytype) !ResumeStatus {
        try luau.pushFmtString(fmt, args);
        return luau.resumeThreadError(from);
    }

    /// Resets thread
    pub inline fn resetThread(luau: *Luau) void {
        c.lua_resetthread(stateCast(luau));
    }

    /// Returns boolean indicating if the thread is reset
    pub inline fn isThreadReset(luau: *Luau) bool {
        return c.lua_isthreadreset(stateCast(luau)) != 0;
    }

    /// Returns the coroutine status of given thread
    pub inline fn statusThread(luau: *Luau, co: *Luau) CoroutineStatus {
        return @enumFromInt(c.lua_costatus(stateCast(luau), stateCast(co)));
    }

    /// Pops a table from the stack and sets it as the new environment for the value at the
    /// given index. Returns an error if the value at that index is not a function or thread or userdata.
    pub inline fn setfenv(luau: *Luau, index: i32) !void {
        if (c.lua_setfenv(stateCast(luau), index) == 0) return error.Fail;
    }

    /// Does the equivalent to t[`k`] = v where t is the value at the given `index`
    /// and v is the value on the top of the stack
    pub inline fn setField(luau: *Luau, index: i32, k: [:0]const u8) void {
        c.lua_setfield(stateCast(luau), index, k.ptr);
    }

    /// Pops a value from the stack and sets it as the new value of global `name`
    pub inline fn setGlobal(luau: *Luau, name: [:0]const u8) void {
        c.lua_setglobal(stateCast(luau), name.ptr);
    }

    pub fn setFieldAhead(luau: *Luau, comptime index: i32, k: [:0]const u8) void {
        const idx = comptime if (index != GLOBALSINDEX and index != REGISTRYINDEX and index < 0) index - 1 else index;
        luau.setField(idx, k);
    }

    pub fn setFieldNil(luau: *Luau, comptime index: i32, k: [:0]const u8) void {
        luau.pushNil();
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldFn(luau: *Luau, comptime index: i32, k: [:0]const u8, comptime zig_fn: anytype) void {
        luau.pushFunction(zig_fn, k);
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldBoolean(luau: *Luau, comptime index: i32, k: [:0]const u8, value: bool) void {
        luau.pushBoolean(value);
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldInteger(luau: *Luau, comptime index: i32, k: [:0]const u8, value: Integer) void {
        luau.pushInteger(value);
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldNumber(luau: *Luau, comptime index: i32, k: [:0]const u8, value: Number) void {
        luau.pushNumber(value);
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldUnsigned(luau: *Luau, comptime index: i32, k: [:0]const u8, value: Unsigned) void {
        luau.pushUnsigned(value);
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldString(luau: *Luau, comptime index: i32, k: [:0]const u8, value: [:0]const u8) void {
        luau.pushString(value);
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldLString(luau: *Luau, comptime index: i32, k: [:0]const u8, value: []const u8) void {
        luau.pushLString(value);
        luau.setFieldAhead(index, k);
    }
    pub fn setFieldVector(luau: *Luau, comptime index: i32, k: [:0]const u8, x: f32, y: f32, z: f32, w: ?f32) void {
        luau.pushVector(x, y, z, w);
        luau.setFieldAhead(index, k);
    }

    pub fn setGlobalNil(luau: *Luau, name: [:0]const u8) void {
        luau.pushNil();
        luau.setGlobal(name);
    }
    pub fn setGlobalFn(luau: *Luau, name: [:0]const u8, comptime zig_fn: anytype) void {
        luau.pushFunction(zig_fn, name);
        luau.setGlobal(name);
    }
    pub fn setGlobalBoolean(luau: *Luau, name: [:0]const u8, value: bool) void {
        luau.pushBoolean(value);
        luau.setGlobal(name);
    }
    pub fn setGlobalInteger(luau: *Luau, name: [:0]const u8, value: Integer) void {
        luau.pushInteger(value);
        luau.setGlobal(name);
    }
    pub fn setGlobalNumber(luau: *Luau, name: [:0]const u8, value: Number) void {
        luau.pushNumber(value);
        luau.setGlobal(name);
    }
    pub fn setGlobalUnsigned(luau: *Luau, name: [:0]const u8, value: Unsigned) void {
        luau.pushUnsigned(value);
        luau.setGlobal(name);
    }
    pub fn setGlobalString(luau: *Luau, name: [:0]const u8, value: [:0]const u8) void {
        luau.pushString(value);
        luau.setGlobal(name);
    }
    pub fn setGlobalLString(luau: *Luau, name: [:0]const u8, value: []const u8) void {
        luau.pushLString(value);
        luau.setGlobal(name);
    }
    pub fn setGlobalVector(luau: *Luau, name: [:0]const u8, x: f32, y: f32, z: f32, w: ?f32) void {
        luau.pushVector(x, y, z, w);
        luau.setGlobal(name);
    }

    /// Pops a table or nil from the stack and sets that value as the new metatable for the
    /// value at the given `index`
    pub inline fn setMetatable(luau: *Luau, index: i32) void {
        // lua_setmetatable always returns 1 so is safe to ignore
        _ = c.lua_setmetatable(stateCast(luau), index);
    }

    /// Does the equivalent to t[k] = v, where t is the value at the given `index`
    /// v is the value on the top of the stack, and k is the value just below the top
    pub inline fn setTable(luau: *Luau, index: i32) void {
        c.lua_settable(stateCast(luau), index);
    }

    /// Sets read-only of the lua object at index
    pub inline fn setReadOnly(luau: *Luau, index: i32, enabled: bool) void {
        c.lua_setreadonly(stateCast(luau), index, if (enabled) 1 else 0);
    }

    /// Sets the top of the stack to `index`
    /// If the new top is greater than the old, new elements are filled with nil
    /// If `index` is 0 all stack elements are removed
    pub inline fn setTop(luau: *Luau, index: i32) void {
        c.lua_settop(stateCast(luau), index);
    }

    /// Returns the status of this thread
    pub inline fn status(luau: *Luau) Status {
        return @enumFromInt(c.lua_status(stateCast(luau)));
    }

    /// Converts the Luau value at the given `index` into a boolean
    /// The Luau value at the index will be considered true unless it is false or nil
    pub inline fn toBoolean(luau: *Luau, index: i32) bool {
        return c.lua_toboolean(stateCast(luau), index) != 0;
    }

    /// Converts the Luau value at the given `index` to a signed integer
    /// The Luau value must be an integer, or a number, or a string convertible to an integer otherwise toInteger returns 0
    pub fn toInteger(luau: *Luau, index: i32) !Integer {
        var success: c_int = undefined;
        const result = c.lua_tointegerx(stateCast(luau), index, &success);
        if (success == 0) return error.Fail;
        return result;
    }

    /// Converts the Luau value at the given `index` to a float
    /// The Luau value must be a number or a string convertible to a number otherwise toNumber returns 0
    pub fn toNumber(luau: *Luau, index: i32) !Number {
        var success: c_int = undefined;
        const result = c.lua_tonumberx(stateCast(luau), index, &success);
        if (success == 0) return error.Fail;
        return result;
    }

    /// Converts the Luau value at the given `index` to a unsigned integer
    /// The Luau value must be an integer, or a number, or a string convertible to an integer otherwise toInteger returns 0
    pub fn toUnsigned(luau: *Luau, index: i32) !Unsigned {
        var success: c_int = undefined;
        const result = c.lua_tounsignedx(stateCast(luau), index, &success);
        if (success == 0) return error.Fail;
        return result;
    }

    /// Converts the Luau value at the given `index` to a zero-terminated many-itemed-pointer (string)
    /// Returns an error if the conversion failed
    /// If the value was a number the actual value in the stack will be changed to a string
    pub fn toString(luau: *Luau, index: i32) ![:0]const u8 {
        var length: usize = undefined;
        if (c.lua_tolstring(stateCast(luau), index, &length)) |str| return str[0..length :0];
        return error.Fail;
    }

    /// Converts the value at the given `index` to an opaque pointer
    pub fn toPointer(luau: *Luau, index: i32) !*const anyopaque {
        if (c.lua_topointer(stateCast(luau), index)) |ptr| return ptr;
        return error.Fail;
    }

    /// Converts a value at the given `index` into a CFn
    /// Returns an error if the value is not a CFn
    pub fn toCFunction(luau: *Luau, index: i32) !CFn {
        return c.lua_tocfunction(stateCast(luau), index) orelse return error.Fail;
    }

    /// Converts the value at the given `index` to a Luau thread (wrapped with a `Luau` struct)
    /// The thread does _not_ contain an allocator because it is not the main thread and should therefore not be used with `deinit()`
    /// Returns an error if the value is not a thread
    pub fn toThread(luau: *Luau, index: i32) !*Luau {
        const thread = c.lua_tothread(stateCast(luau), index);
        if (thread) |thread_ptr| return @ptrCast(thread_ptr);
        return error.Fail;
    }

    /// Returns a Luau-owned userdata pointer of the given type at the given index.
    /// Works for both light and full userdata.
    /// Returns an error if the value is not a userdata.
    pub fn toUserdata(luau: *Luau, comptime T: type, index: i32) !*T {
        if (c.lua_touserdata(stateCast(luau), index)) |ptr| return opaqueCast(T, ptr);
        return error.Fail;
    }

    /// Returns a Luau-owned userdata slice of the given type at the given index.
    /// Returns an error if the value is not a userdata.
    pub fn toUserdataSlice(luau: *Luau, comptime T: type, index: i32) ![]T {
        if (c.lua_touserdata(stateCast(luau), index)) |ptr| {
            const size = @as(u32, @intCast(luau.objectLen(index))) / @sizeOf(T);
            return @as([*]T, @ptrCast(@alignCast(ptr)))[0..size];
        }
        return error.Fail;
    }

    pub fn toUserdataTagged(luau: *Luau, comptime T: type, index: i32, tag: i32) !*T {
        if (c.lua_touserdatatagged(stateCast(luau), index, tag)) |ptr| return opaqueCast(T, ptr);
        return error.Fail;
    }

    pub fn toBuffer(luau: *Luau, index: i32) ![]u8 {
        var length: usize = undefined;
        if (c.lua_tobuffer(stateCast(luau), index, &length)) |ptr| return @as([*]u8, @ptrCast(@alignCast(ptr)))[0..length];
        return error.Fail;
    }

    pub fn toVector(luau: *Luau, index: i32) ![]const f32 {
        if (c.lua_tovector(stateCast(luau), index)) |ptr| return @as([*]const f32, @ptrCast(@alignCast(ptr)))[0..VECTOR_SIZE];
        return error.Fail;
    }

    pub fn typeOfObj(luau: *Luau, index: i32) !LuaObject {
        luau.pushValue(index);
        errdefer luau.pop(1);
        return try luau.toLuaObject(luau.typeOf(-1));
    }

    pub fn typeOfObjConsumed(luau: *Luau, index: i32) !LuaObject {
        luau.pushValue(index);
        defer luau.pop(1);
        return try luau.toLuaObject(luau.typeOf(-1));
    }

    /// Returns the `LuaType` of the value at the given index
    /// Note that this is equivalent to lua_type but because type is a Zig primitive it is renamed to `typeOf`
    pub inline fn typeOf(luau: *Luau, index: i32) LuaType {
        return @enumFromInt(c.lua_type(stateCast(luau), index));
    }

    /// Returns the name of the given `LuaType` as a null-terminated slice
    pub fn typeName(luau: *Luau, t: LuaType) [:0]const u8 {
        return std.mem.span(c.lua_typename(stateCast(luau), @intFromEnum(t)));
    }

    /// Returns the pseudo-index that represents the `i`th upvalue of the running function
    pub inline fn upvalueIndex(i: i32) i32 {
        return c.lua_upvalueindex(i);
    }

    /// Pops `num` values from the current stack and pushes onto the stack of `to`
    pub inline fn xMove(luau: *Luau, to: *Luau, num: i32) void {
        c.lua_xmove(stateCast(luau), stateCast(to), num);
    }

    /// Pushes value at index from the current stack onto the stack of `to`
    pub inline fn xPush(luau: *Luau, to: *Luau, idx: i32) void {
        c.lua_xpush(stateCast(luau), stateCast(to), idx);
    }

    /// Yields a coroutine
    /// This function must be used as the return expression of a function
    pub inline fn yield(luau: *Luau, num_results: i32) i32 {
        return c.lua_yield(stateCast(luau), num_results);
    }

    pub inline fn gBreak(luau: *Luau) i32 {
        return c.lua_break(stateCast(luau));
    }

    pub inline fn isYieldable(luau: *Luau) bool {
        return c.lua_isyieldable(stateCast(luau)) == 1;
    }

    // Debug library functions
    //
    // The debug interface functions are included in alphabetical order
    // Each is kept similar to the original C API function while also making it easy to use from Zig

    /// Warning: this function is not thread-safe since it stores the result in a shared global array! Only use for debugging.
    pub fn debugTrace(luau: *Luau) [:0]const u8 {
        return std.mem.span(c.lua_debugtrace(stateCast(luau)));
    }

    /// Gets information about a specific function or function invocation.
    pub fn getInfo(luau: *Luau, level: i32, options: DebugInfo.Options, info: *DebugInfo) bool {
        const str = options.toString();

        var ar: Debug = undefined;

        // should never fail because we are controlling options with the struct param
        if (c.lua_getinfo(stateCast(luau), level, &str, &ar) == 0)
            return false;
        // std.debug.assert( != 0);

        // copy data into a struct
        if (options.l) info.current_line = if (ar.currentline == -1) null else ar.currentline;
        if (options.n) {
            info.name = if (ar.name != null) std.mem.span(ar.name) else null;
        }
        if (options.s) {
            info.source = std.mem.span(ar.source);

            const short_src: [:0]const u8 = std.mem.span(ar.short_src);
            @memcpy(info.short_src[0..short_src.len], short_src[0.. :0]);
            info.short_src_len = short_src.len;

            info.line_defined = ar.linedefined;
            info.what = blk: {
                const what = std.mem.span(ar.what);
                if (std.mem.eql(u8, "Lua", what)) break :blk .luau;
                if (std.mem.eql(u8, "C", what)) break :blk .c;
                if (std.mem.eql(u8, "main", what)) break :blk .main;
                if (std.mem.eql(u8, "tail", what)) break :blk .tail;
                unreachable;
            };
        }
        return true;
    }

    /// Gets information about a local variable
    /// Returns the name of the local variable
    pub fn getLocal(luau: *Luau, level: i32, n: i32) ![:0]const u8 {
        if (c.lua_getlocal(stateCast(luau), level, n)) |name| {
            return std.mem.span(name);
        }
        return error.None;
    }

    /// Gets information about the `n`th upvalue of the closure at index `func_index`
    pub fn getUpvalue(luau: *Luau, func_index: i32, n: i32) ![:0]const u8 {
        if (c.lua_getupvalue(stateCast(luau), func_index, n)) |name| {
            return std.mem.span(name);
        }
        return error.None;
    }

    pub inline fn getArgument(luau: *Luau, level: i32, n: i32) i32 {
        return c.lua_getargument(stateCast(luau), level, n);
    }

    /// Sets the value of a local variable
    /// Returns an error when the index is greater than the number of active locals
    /// Returns the name of the local variable
    pub fn setLocal(luau: *Luau, level: i32, n: i32) ![:0]const u8 {
        if (c.lua_setlocal(stateCast(luau), level, n)) |name| {
            return std.mem.span(name);
        }
        return error.Fail;
    }

    /// Sets the value of a closure's upvalue
    /// Returns the name of the upvalue or an error if the upvalue does not exist
    pub fn setUpvalue(luau: *Luau, func_index: i32, n: i32) ![:0]const u8 {
        if (c.lua_setupvalue(stateCast(luau), func_index, n)) |name| {
            return std.mem.span(name);
        }
        return error.Fail;
    }

    // Auxiliary library functions
    //
    // Auxiliary library functions are included in alphabetical order.
    // Each is kept similar to the original C API function while also making it easy to use from Zig

    /// Checks whether `cond` is true. Raises an error using `Luau.argError()` if not
    /// Possibly never returns
    pub fn argCheck(luau: *Luau, cond: bool, arg: i32, extra_msg: [:0]const u8) void {
        // translate-c failed
        if (!cond) luau.argError(arg, extra_msg);
    }

    /// Raises an error reporting a problem with argument `arg` of the C function that called it
    pub inline fn argError(luau: *Luau, arg: i32, extra_msg: [*:0]const u8) noreturn {
        _ = c.luaL_argerror(stateCast(luau), arg, extra_msg);
        unreachable;
    }

    /// Calls a metamethod
    pub inline fn callMeta(luau: *Luau, obj: i32, field: [:0]const u8) !void {
        if (c.luaL_callmeta(stateCast(luau), obj, field.ptr) == 0) return error.Fail;
    }

    /// Checks whether the function has an argument of any type at position `arg`
    pub inline fn checkAny(luau: *Luau, arg: i32) void {
        c.luaL_checkany(stateCast(luau), arg);
    }

    pub inline fn checkBoolean(luau: *Luau, arg: i32) bool {
        return c.luaL_checkboolean(stateCast(luau), arg) != 0;
    }

    /// Checks whether the function argument `arg` is a number and returns the number cast to an Integer
    pub inline fn checkInteger(luau: *Luau, arg: i32) Integer {
        return c.luaL_checkinteger(stateCast(luau), arg);
    }

    /// Checks whether the function argument `arg` is a number and returns the number
    pub inline fn checkNumber(luau: *Luau, arg: i32) Number {
        return c.luaL_checknumber(stateCast(luau), arg);
    }

    /// Checks whether the function argument `arg` is a number and returns the number cast to an unsigned Integer
    pub inline fn checkUnsigned(luau: *Luau, arg: i32) Unsigned {
        return c.luaL_checkunsigned(stateCast(luau), arg);
    }

    /// Checks whether the function argument `arg` is a slice of bytes and returns the slice
    pub fn checkBytes(luau: *Luau, arg: i32) [:0]const u8 {
        var length: usize = 0;
        const str = c.luaL_checklstring(stateCast(luau), arg, &length);
        // luaL_checklstring never returns null (throws luau error)
        return str[0..length :0];
    }

    pub fn checkBuffer(luau: *Luau, arg: i32) []u8 {
        var length: usize = 0;
        const ptr = c.luaL_checkbuffer(stateCast(luau), arg, &length);
        // luaL_checkbuffer never returns null (throws luau error)
        return @as([*]u8, @ptrCast(@alignCast(ptr.?)))[0..length];
    }

    pub fn checkVector(luau: *Luau, arg: i32) []const f32 {
        const ptr = c.luaL_checkvector(stateCast(luau), arg);
        // luaL_checkvector never returns null (throws luau error)
        return @as([*]const f32, @ptrCast(@alignCast(ptr.?)))[0..VECTOR_SIZE];
    }

    /// Checks whether the function argument `arg` is a string and searches for the enum value with the same name in `T`.
    /// `default` is used as a default value when not null
    /// Returns the enum value found
    /// Useful for mapping Luau strings to Zig enums
    pub fn checkOption(luau: *Luau, comptime T: type, arg: i32, default: ?T) T {
        const name = blk: {
            if (default) |defaultName| {
                break :blk luau.optLString(arg, @tagName(defaultName));
            } else {
                break :blk luau.checkBytes(arg);
            }
        };

        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return @enumFromInt(field.value);
            }
        }

        return luau.argError(arg, luau.pushFString("invalid option '%s'", .{name.ptr}));
    }

    /// Grows the stack size to top + `size` elements, raising an error if the stack cannot grow to that size
    /// `msg` is an additional text to go into the error message
    pub inline fn checkStackErr(luau: *Luau, size: i32, msg: ?[*:0]const u8) void {
        c.luaL_checkstack(stateCast(luau), size, msg);
    }

    /// Checks whether the function argument `arg` is a string and returns the string
    pub fn checkString(luau: *Luau, arg: i32) [:0]const u8 {
        var length: usize = 0;
        const str = c.luaL_checklstring(stateCast(luau), arg, &length);
        // luaL_checklstring never returns null (throws lua error)
        return str[0..length :0];
    }

    /// Checks whether the function argument `arg` has type `t`
    pub inline fn checkType(luau: *Luau, arg: i32, t: LuaType) void {
        c.luaL_checktype(stateCast(luau), arg, @intFromEnum(t));
    }

    /// Checks whether the function argument `arg` is a userdata of the type `name`
    /// Returns the userdata's memory-block address
    pub inline fn checkUserdata(luau: *Luau, comptime T: type, arg: i32, name: [:0]const u8) *T {
        // the returned pointer will not be null
        return opaqueCast(T, c.luaL_checkudata(stateCast(luau), arg, name.ptr).?);
    }

    /// Checks whether the function argument `arg` is a userdata of the type `name`
    /// Returns a Luau-owned userdata slice
    pub fn checkUserdataSlice(luau: *Luau, comptime T: type, arg: i32, name: [:0]const u8) []T {
        // the returned pointer will not be null
        const ptr = c.luaL_checkudata(stateCast(luau), arg, name.ptr).?;
        const size = @as(u32, @intCast(luau.objLen(arg))) / @sizeOf(T);
        return @as([*]T, @ptrCast(@alignCast(ptr)))[0..size];
    }

    pub fn Error(luau: *Luau, comptime message: []const u8) anyerror {
        luau.pushLString(message);
        return error.RaiseLuauError;
    }

    pub fn ErrorFmt(luau: *Luau, comptime fmt: []const u8, args: anytype) anyerror {
        luau.pushFmtString(fmt, args) catch |err| {
            luau.pushLString(@errorName(err));
        };
        return error.RaiseLuauError;
    }

    /// Raises an error
    pub fn raiseErrorStr(luau: *Luau, fmt: [:0]const u8, args: anytype) noreturn {
        _ = @call(.auto, c.luaL_errorL, .{ stateCast(luau), fmt.ptr } ++ args);
        unreachable;
    }

    /// Raises an error with zig comptime formatted string
    pub fn raiseErrorFmt(luau: *Luau, comptime fmt: []const u8, args: anytype) !noreturn {
        try luau.pushFmtString(fmt, args);
        luau.raiseError();
    }

    pub fn loadBytecode(luau: *Luau, chunkname: [:0]const u8, bytecode: []const u8) !void {
        try luau.loadBytecodeEnv(chunkname, bytecode, 0);
    }
    pub inline fn loadBytecodeEnv(luau: *Luau, chunkname: [:0]const u8, bytecode: []const u8, envIdx: i32) !void {
        if (c.luau_load(stateCast(luau), chunkname.ptr, bytecode.ptr, bytecode.len, envIdx) != 0) return error.Fail;
    }

    /// Pushes onto the stack the field `e` from the metatable of the object at index `obj`
    /// and returns the type of the pushed value
    pub fn getMetaField(luau: *Luau, obj: i32, field: [:0]const u8) !LuaType {
        const val_type: LuaType = @enumFromInt(c.luaL_getmetafield(stateCast(luau), obj, field.ptr));
        if (val_type == .nil) return error.Fail;
        return val_type;
    }

    pub inline fn getMainThread(luau: *Luau) *Luau {
        return @ptrCast(c.lua_mainthread(stateCast(luau)));
    }

    /// Pushes onto the stack the metatable associated with the name `type_name` in the registry
    /// or nil if there is no metatable associated with that name. Returns the type of the pushed value
    pub inline fn getMetatableRegistry(luau: *Luau, table_name: [:0]const u8) LuaType {
        return @enumFromInt(c.luaL_getmetatable(stateCast(luau), table_name));
    }

    /// If the registry already has the key `key`, returns an error
    /// Otherwise, creates a new table to be used as a metatable for userdata
    pub fn newMetatable(luau: *Luau, key: [:0]const u8) !void {
        if (c.luaL_newmetatable(stateCast(luau), key.ptr) == 0) return error.Fail;
    }

    /// Creates a new Luau state with an allocator using the default libc allocator
    pub fn newStateLibc() !*Luau {
        zig_registerAssertionHandler();

        if (c.luaL_newstate()) |state| {
            return @ptrCast(state);
        } else return error.Memory;
    }

    pub fn nameCallAtom(luau: *Luau) ![:0]const u8 {
        if (c.lua_namecallatom(stateCast(luau), null)) |str| return std.mem.span(str);
        return error.Fail;
    }

    // luaL_opt (a macro) really isn't that useful, so not going to implement for now

    /// If the function argument `arg` is an integer, returns the integer
    /// If the argument is absent or nil returns `default`
    pub fn optInteger(luau: *Luau, arg: i32) ?Integer {
        if (luau.isNoneOrNil(arg)) return null;
        return luau.checkInteger(arg);
    }

    /// If the function argument `arg` is a slice of bytes, returns the slice
    /// If the argument is absent or nil returns `default`
    pub fn optLString(luau: *Luau, arg: i32, default: [:0]const u8) [:0]const u8 {
        var length: usize = 0;
        // will never return null because default cannot be null
        const ret: [*]const u8 = c.luaL_optlstring(stateCast(luau), arg, default.ptr, &length);
        if (ret == default.ptr) return default;
        return ret[0..length :0];
    }

    /// If the function argument `arg` is a number, returns the number
    /// If the argument is absent or nil returns `default`
    pub fn optNumber(luau: *Luau, arg: i32) ?Number {
        if (luau.isNoneOrNil(arg)) return null;
        return luau.checkNumber(arg);
    }

    /// If the function argument `arg` is a boolean, returns the boolean
    /// If the argument is absent or nil returns `default`
    pub fn optBoolean(luau: *Luau, arg: i32) ?bool {
        if (luau.isNoneOrNil(arg)) return null;
        return luau.checkBoolean(arg);
    }

    /// If the function argument `arg` is a string, returns the string
    /// If the argment is absent or nil returns `default`
    pub fn optString(luau: *Luau, arg: i32) ?[:0]const u8 {
        if (luau.isNoneOrNil(arg)) return null;
        return luau.checkString(arg);
    }

    /// If the function argument `arg` is a usigned integer, returns the integer
    /// If the argument is absent or nil returns `default`
    pub fn optUnsigned(luau: *Luau, arg: i32) ?Unsigned {
        if (luau.isNoneOrNil(arg)) return null;
        return luau.checkUnsigned(arg);
    }

    /// If the function argument `arg` is a buffer, returns the buffer
    /// If the argument is absent or nil returns `default`
    pub fn optBuffer(luau: *Luau, arg: i32) ?[]u8 {
        if (luau.isNoneOrNil(arg)) return null;
        return luau.toBuffer(arg) catch null;
    }

    /// If the function argument `arg` is a vector, returns the vector
    /// If the argument is absent or nil returns `default`
    pub fn optVector(luau: *Luau, arg: i32) ?[]const f32 {
        if (luau.isNoneOrNil(arg)) return null;
        return luau.toVector(arg) catch null;
    }

    /// Creates and returns a reference in the table at index `index` for the object on the top of the stack
    pub fn ref(luau: *Luau, index: i32) !i32 {
        const ret = c.lua_ref(stateCast(luau), index);
        return if (ret == ref_nil) error.Fail else ret;
    }

    pub fn findTable(luau: *Luau, index: i32, name: [:0]const u8, sizehint: usize) ?[:0]const u8 {
        if (c.luaL_findtable(stateCast(luau), index, name, @intCast(sizehint))) |e| {
            return std.mem.span(e);
        }
        return null;
    }

    /// Opens a library
    pub fn registerFns(luau: *Luau, libname: ?[:0]const u8, funcs: []const FnReg) void {
        // translated from the implementation of luaI_openlib so we can use a slice of
        // FnReg without requiring a sentinel end value
        if (libname) |name| {
            _ = luau.findTable(REGISTRYINDEX, "_LOADED", 1);
            _ = luau.getField(-1, name);
            if (!luau.isTable(-1)) {
                luau.pop(1);
                if (luau.findTable(GLOBALSINDEX, name, funcs.len)) |_| {
                    luau.raiseErrorStr("name conflict for module '%s'", .{name.ptr});
                }
                luau.pushValue(-1);
                luau.setField(-3, name);
            }
            luau.remove(-2);
            luau.insert(-1);
        }
        for (funcs) |f| {
            if (f.func) |func| {
                luau.pushCFunction(func, f.name);
                luau.setField(-2, f.name);
            }
        }
    }

    /// Returns the name of the type of the value at the given `index`
    pub fn typeNameIndex(luau: *Luau, index: i32) [:0]const u8 {
        return std.mem.span(c.luaL_typename(stateCast(luau), index));
    }

    /// Releases the reference `r` from the table at index `index`
    pub inline fn unref(luau: *Luau, r: i32) void {
        c.lua_unref(stateCast(luau), r);
    }

    /// Pushes onto the stack a string identifying the current position of the control
    /// at the call stack `level`
    pub inline fn where(luau: *Luau, level: i32) void {
        c.luaL_where(stateCast(luau), level);
    }

    // Standard library loading functions

    /// Opens the specified standard library functions
    /// Behaves like openLibs, but allows specifying which libraries
    /// to expose to the global table rather than all of them
    pub fn open(luau: *Luau, libs: Libs) void {
        if (libs.base) luau.requireF("", c.luaopen_base);
        if (libs.string) luau.requireF(c.LUA_STRLIBNAME, c.luaopen_string);
        if (libs.table) luau.requireF(c.LUA_TABLIBNAME, c.luaopen_table);
        if (libs.math) luau.requireF(c.LUA_MATHLIBNAME, c.luaopen_math);
        if (libs.os) luau.requireF(c.LUA_OSLIBNAME, c.luaopen_os);
        if (libs.debug) luau.requireF(c.LUA_DBLIBNAME, c.luaopen_debug);
        if (libs.bit32) luau.requireF(c.LUA_BITLIBNAME, c.luaopen_bit32);
        if (libs.utf8) luau.requireF(c.LUA_UTF8LIBNAME, c.luaopen_utf8);
        if (libs.buffer) luau.requireF(c.LUA_BUFFERLIBNAME, c.luaopen_buffer);
        if (libs.vector) luau.requireF(c.LUA_VECLIBNAME, c.luaopen_vector);
    }

    fn requireF(luau: *Luau, name: [:0]const u8, comptime func: anytype) void {
        luau.pushCFunction(func, name);
        luau.pushString(name);
        luau.call(1, 0);
    }

    /// Open all standard libraries
    pub inline fn openLibs(luau: *Luau) void {
        c.luaL_openlibs(stateCast(luau));
    }

    /// Open the basic standard library
    pub inline fn openBase(luau: *Luau) void {
        _ = c.luaopen_base(stateCast(luau));
    }

    /// Open the string standard library
    pub inline fn openString(luau: *Luau) void {
        _ = c.luaopen_string(stateCast(luau));
    }

    /// Open the table standard library
    pub inline fn openTable(luau: *Luau) void {
        _ = c.luaopen_table(stateCast(luau));
    }

    /// Open the math standard library
    pub inline fn openMath(luau: *Luau) void {
        _ = c.luaopen_math(stateCast(luau));
    }

    /// Open the os standard library
    pub inline fn openOS(luau: *Luau) void {
        _ = c.luaopen_os(stateCast(luau));
    }

    /// Open the debug standard library
    pub inline fn openDebug(luau: *Luau) void {
        _ = c.luaopen_debug(stateCast(luau));
    }

    /// Open the coroutine standard library
    pub inline fn openCoroutine(luau: *Luau) void {
        _ = c.luaopen_coroutine(stateCast(luau));
    }

    /// Open the utf8 standard library
    pub inline fn openUtf8(luau: *Luau) void {
        _ = c.luaopen_utf8(stateCast(luau));
    }

    /// Open the bit32 standard library
    pub inline fn openBit32(luau: *Luau) void {
        _ = c.luaopen_bit32(stateCast(luau));
    }

    /// Open the buffer standard library
    pub inline fn openBuffer(luau: *Luau) void {
        _ = c.luaopen_buffer(stateCast(luau));
    }

    /// Open the vector standard library
    pub inline fn openVector(luau: *Luau) void {
        _ = c.luaopen_vector(stateCast(luau));
    }

    pub inline fn callbacks(luau: *Luau) [*c]c.lua_Callbacks {
        return c.lua_callbacks(stateCast(luau));
    }

    pub inline fn sandbox(luau: *Luau) void {
        c.luaL_sandbox(stateCast(luau));
    }

    pub inline fn sandboxThread(luau: *Luau) void {
        c.luaL_sandboxthread(stateCast(luau));
    }

    pub inline fn setSafeEnv(luau: *Luau, idx: i32, enabled: bool) void {
        c.lua_setsafeenv(stateCast(luau), idx, if (enabled) 1 else 0);
    }

    pub inline fn getStackdepth(luau: *Luau) i32 {
        return c.lua_stackdepth(stateCast(luau));
    }

    pub inline fn setSingleStep(luau: *Luau, enabled: bool) void {
        c.lua_singlestep(stateCast(luau), if (enabled) 1 else 0);
    }

    pub inline fn breakpoint(luau: *Luau, funcindex: i32, line: i32, enabled: bool) i32 {
        return c.lua_breakpoint(stateCast(luau), funcindex, line, if (enabled) 1 else 0);
    }

    pub inline fn gc_dump(luau: *Luau, funcindex: i32, line: i32, enabled: bool) i32 {
        return c.luaG_dump(stateCast(luau), funcindex, line, if (enabled) 1 else 0);
    }

    pub fn getCoverage(
        luau: *Luau,
        comptime T: type,
        funcindex: i32,
        context: *T,
        callback: *const fn (ctx: T, func: []const u8, line: i32, depth: i32, hits: []const i32) void,
    ) bool {
        return c.lua_getcoverage(stateCast(luau), funcindex, context, struct {
            fn inner(ctx: ?*anyopaque, func: [*]const u8, line: c_int, depth: c_int, hits: []const c_int, size: usize) callconv(.C) c_int {
                // this is called by Luau, state should never be null
                return @call(.always_inline, callback, .{ @as(*T, @ptrCast(ctx.?)), std.mem.span(func), line, depth, hits[0..size] });
            }
        }.inner) != 0;
    }

    // Internal API functions
    pub const sys = struct {
        pub inline fn luaD_checkstack(luau: *Luau, n: i32) void {
            zig_luau_luaD_checkstack(stateCast(luau), n);
        }
        pub inline fn luaD_expandstacklimit(luau: *Luau, n: i32) void {
            zig_luau_expandstacklimit(stateCast(luau), n);
        }
    };
};

test Luau {
    std.testing.refAllDecls(Luau);
}

/// A string buffer allowing for Zig code to build Luau strings piecemeal
/// All LuaBuffer functions are wrapped in this struct to make the API more convenient to use
pub const StringBuffer = struct {
    b: LuaBuffer = undefined,

    /// Initialize a Luau string buffer
    pub fn init(buf: *StringBuffer, luau: *Luau) void {
        c.luaL_buffinit(stateCast(luau), &buf.b);
    }

    /// TODO: buffinitsize
    /// Internal Luau type for a string buffer
    pub const LuaBuffer = c.luaL_Strbuf;

    pub const buffer_size = c.LUA_BUFFERSIZE;

    /// Adds `byte` to the buffer
    pub fn addChar(buf: *StringBuffer, byte: u8) void {
        // could not be translated by translate-c
        var lua_buf = &buf.b;
        if (lua_buf.p > &lua_buf.buffer[buffer_size - 1]) _ = buf.prep();
        lua_buf.p.* = byte;
        lua_buf.p += 1;
    }

    /// Adds the string to the buffer
    pub fn addBytes(buf: *StringBuffer, str: []const u8) void {
        c.luaL_addlstring(&buf.b, str.ptr, str.len);
    }

    /// Adds to the buffer a string of `length` previously copied to the buffer area
    pub fn addSize(buf: *StringBuffer, length: usize) void {
        // another function translate-c couldn't handle
        // c.luaL_addsize(&buf.b, length);
        var lua_buf = &buf.b;
        lua_buf.p += length;
    }

    /// Adds the zero-terminated string pointed to by `str` to the buffer
    pub fn addString(buf: *StringBuffer, str: [:0]const u8) void {
        c.luaL_addlstring(&buf.b, str.ptr, str.len);
    }

    /// Adds the value on the top of the stack to the buffer and pops the value
    pub fn addValue(buf: *StringBuffer) void {
        c.luaL_addvalue(&buf.b);
    }

    /// Adds the value at the given index to the buffer
    pub fn addValueAny(buf: *StringBuffer, idx: i32) void {
        c.luaL_addvalueany(&buf.b, idx);
    }

    /// Equivalent to prepSize with a buffer size of Buffer.buffer_size
    pub fn prep(buf: *StringBuffer) []u8 {
        return c.luaL_prepbuffsize(&buf.b, buffer_size)[0..buffer_size];
    }

    /// Finishes the use of the buffer leaving the final string on the top of the stack
    pub fn pushResult(buf: *StringBuffer) void {
        c.luaL_pushresult(&buf.b);
    }

    /// Equivalent to `Buffer.addSize()` followed by `Buffer.pushResult()`
    pub fn pushResultSize(buf: *StringBuffer, size: usize) void {
        c.luaL_pushresultsize(&buf.b, size);
    }
};

// Helper functions to make the ziglua API easier to use

pub inline fn opaqueCast(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

// pub const ZigFn = fn (luau: *Luau) i32;
// // pub const ZigHookFn = fn (luau: *Luau, event: Event, info: *DebugInfo) void;
// pub const ZigContFn = fn (luau: *Luau, status: Status, ctx: Context) i32;
// pub const ZigReaderFn = fn (luau: *Luau, data: *anyopaque) ?[]const u8;
// pub const ZigUserdataDtorFn = fn (data: *anyopaque) void;
// pub const ZigUserAtomCallbackFn = fn (str: []const u8) i16;
// pub const ZigWarnFn = fn (data: ?*anyopaque, msg: []const u8, to_cont: bool) void;
// pub const ZigWriterFn = fn (luau: *Luau, buf: []const u8, data: *anyopaque) bool;

// fn TypeOfWrap(comptime T: type) type {
//     return switch (T) {
//         LuaState => Luau,
//         ZigFn => CFn,
//         // ZigHookFn => CHookFn,
//         ZigContFn => CContFn,
//         ZigReaderFn => CReaderFn,
//         ZigUserdataDtorFn => CUserdataDtorFn,
//         ZigUserAtomCallbackFn => CUserAtomCallbackFn,
//         ZigWarnFn => CWarnFn,
//         ZigWriterFn => CWriterFn,
//         else => @compileError("unsupported type given to wrap: '" ++ @typeName(T) ++ "'"),
//     };
// }

/// Wraps the given value for use in the Luau API
/// Supports the following:
/// * `LuaState` => `Luau`
// pub fn wrap(comptime value: anytype) TypeOfWrap(@TypeOf(value)) {
//     const T = @TypeOf(value);
//     return switch (T) {
//         ZigFn => wrapZigFn(value),
//         // ZigHookFn => wrapZigHookFn(value),
//         ZigContFn => wrapZigContFn(value),
//         ZigReaderFn => wrapZigReaderFn(value),
//         ZigUserdataDtorFn => wrapZigUserdataDtorFn(value),
//         ZigUserAtomCallbackFn => wrapZigUserAtomCallbackFn(value),
//         ZigWarnFn => wrapZigWarnFn(value),
//         ZigWriterFn => wrapZigWriterFn(value),
//         else => @compileError("unsupported type given to wrap: '" ++ @typeName(T) ++ "'"),
//     };
// }

/// Wrap a ZigFn in a CFn for passing to the API
// pub fn toCFn(comptime f: ZigFn) CFn {
//     return struct {
//         fn inner(state: ?*LuaState) callconv(.C) c_int {
//             // this is called by Luau, state should never be null
//             return @call(.always_inline, f, .{@as(*Luau, @ptrCast(state.?))});
//         }
//     }.inner;
// }

pub const CFn = *const fn (state: ?*LuaState) callconv(.C) c_int;
pub const ZigFnInt = *const fn (state: *Luau) i32;
pub const ZigFnVoid = *const fn (state: *Luau) void;
pub const ZigFnErrorSet = *const fn (state: *Luau) anyerror!i32;

pub fn ZigToCFn(comptime fnType: std.builtin.Type.Fn, comptime f: anytype) CFn {
    const ri = @typeInfo(fnType.return_type orelse @compileError("Fn must return something"));
    switch (ri) {
        .int => |_| {
            _ = @as(ZigFnInt, f);
            return struct {
                fn inner(s: ?*LuaState) callconv(.C) c_int {
                    // this is called by Luau, state should never be null
                    return @call(.always_inline, f, .{@as(*Luau, @ptrCast(s.?))});
                }
            }.inner;
        },
        .void => |_| {
            _ = @as(ZigFnVoid, f);
            return struct {
                fn inner(s: ?*LuaState) callconv(.C) c_int {
                    // this is called by Luau, state should never be null
                    @call(.always_inline, f, .{@as(*Luau, @ptrCast(s.?))});
                    return 0;
                }
            }.inner;
        },
        .error_union => |_| {
            _ = @as(ZigFnErrorSet, f);
            return struct {
                fn inner(s: ?*LuaState) callconv(.C) c_int {
                    // this is called by Luau, state should never be null
                    const state = @as(*Luau, @ptrCast(s.?));
                    if (@call(.always_inline, f, .{state})) |res|
                        return res
                    else |err| switch (@as(anyerror, @errorCast(err))) {
                        error.RaiseLuauYieldError => state.raiseErrorStr("attempt to yield across metamethod/C-call boundary", .{}),
                        error.RaiseLuauError => state.raiseError(),
                        else => state.raiseErrorStr("%s", .{@errorName(err).ptr}),
                    }
                }
            }.inner;
        },
        else => @compileError("Unsupported Fn Return type"),
    }
}

pub fn toCFn(comptime f: anytype) CFn {
    const t = @TypeOf(f);
    const ti = @typeInfo(t);
    switch (ti) {
        .@"fn" => |Fn| return ZigToCFn(Fn, f),
        .pointer => |ptr| {
            // *const fn ...
            if (!ptr.is_const)
                @compileError("Pointer must be constant");
            const pi = @typeInfo(ptr.child);
            switch (pi) {
                .@"fn" => |Fn| return ZigToCFn(Fn, f),
                else => @compileError("Pointer must be a pointer to a function"),
            }
        },
        else => @compileError("zig_fn must be a Fn or a Fn Pointer"),
    }
    @compileError("Could not determine zig_fn type");
}

/// Wrap a ZigHookFn in a CHookFn for passing to the API
// fn wrapZigHookFn(comptime f: ZigHookFn) CHookFn {
//     return struct {
//         fn inner(state: ?*LuaState, ar: ?*Debug) callconv(.C) void {
//             // this is called by Luau, state should never be null
//             var info: DebugInfo = .{
//                 .current_line = if (ar.?.currentline == -1) null else ar.?.currentline,
//                 .private = @ptrCast(ar.?.i_ci),
//             };
//             @call(.always_inline, f, .{ @as(*Luau, @ptrCast(state.?)), @as(Event, @enumFromInt(ar.?.event)), &info });
//         }
//     }.inner;
// }

/// Wrap a ZigContFn in a CContFn for passing to the API
// fn wrapZigContFn(comptime f: ZigContFn) CContFn {
//     return struct {
//         fn inner(state: ?*LuaState, status: c_int, ctx: Context) callconv(.C) c_int {
//             // this is called by Luau, state should never be null
//             return @call(.always_inline, f, .{ @as(*Luau, @ptrCast(state.?)), @as(Status, @enumFromInt(status)), ctx });
//         }
//     }.inner;
// }

/// Wrap a ZigReaderFn in a CReaderFn for passing to the API
// fn wrapZigReaderFn(comptime f: ZigReaderFn) CReaderFn {
//     return struct {
//         fn inner(state: ?*LuaState, data: ?*anyopaque, size: [*c]usize) callconv(.C) [*c]const u8 {
//             if (@call(.always_inline, f, .{ @as(*Luau, @ptrCast(state.?)), data.? })) |buffer| {
//                 size.* = buffer.len;
//                 return buffer.ptr;
//             } else {
//                 size.* = 0;
//                 return null;
//             }
//         }
//     }.inner;
// }

/// Wrap a ZigFn in a CFn for passing to the API
// fn wrapZigUserdataDtorFn(comptime f: ZigUserdataDtorFn) CUserdataDtorFn {
//     return struct {
//         fn inner(userdata: *anyopaque) callconv(.C) void {
//             return @call(.always_inline, f, .{userdata});
//         }
//     }.inner;
// }

/// Wrap a ZigFn in a CFn for passing to the API
// fn wrapZigUserAtomCallbackFn(comptime f: ZigUserAtomCallbackFn) CUserAtomCallbackFn {
//     return struct {
//         fn inner(str: [*c]const u8, len: usize) callconv(.C) i16 {
//             if (str) |s| {
//                 const buf = s[0..len];
//                 return @call(.always_inline, f, .{buf});
//             }
//             return -1;
//         }
//     }.inner;
// }

/// Wrap a ZigWarnFn in a CWarnFn for passing to the API
// fn wrapZigWarnFn(comptime f: ZigWarnFn) CWarnFn {
//     return struct {
//         fn inner(data: ?*anyopaque, msg: [*c]const u8, to_cont: c_int) callconv(.C) void {
//             // warning messages emitted from Luau should be null-terminated for display
//             const message = std.mem.span(@as([*:0]const u8, @ptrCast(msg)));
//             @call(.always_inline, f, .{ data, message, to_cont != 0 });
//         }
//     }.inner;
// }

/// Wrap a ZigWriterFn in a CWriterFn for passing to the API
// fn wrapZigWriterFn(comptime f: ZigWriterFn) CWriterFn {
//     return struct {
//         fn inner(state: ?*LuaState, buf: ?*const anyopaque, size: usize, data: ?*anyopaque) callconv(.C) c_int {
//             // this is called by Luau, state should never be null
//             const buffer = @as([*]const u8, @ptrCast(buf))[0..size];
//             const result = @call(.always_inline, f, .{ @as(*Luau, @ptrCast(state.?)), buffer, data.? });
//             // it makes more sense for the inner writer function to return false for failure,
//             // so negate the result here
//             return @intFromBool(!result);
//         }
//     }.inner;
// }

/// Zig wrapper for Luau lua_CompileOptions that uses the same defaults as Luau if
/// no compile options is specified.
pub const CompileOptions = Compiler.CompileOptions;

/// Compile luau source into bytecode, return callee owned buffer allocated through the given allocator.
pub fn compile(allocator: Allocator, source: []const u8, options: CompileOptions) ![]const u8 {
    var size: usize = 0;

    var opts = c.lua_CompileOptions{
        .optimizationLevel = options.optimization_level,
        .debugLevel = options.debug_level,
        .coverageLevel = options.coverage_level,
        .vectorLib = options.vector_lib,
        .vectorCtor = options.vector_ctor,
        .mutableGlobals = options.mutable_globals,
    };
    const bytecode = c.luau_compile(source.ptr, source.len, &opts, &size);
    if (bytecode == null) return error.Memory;
    defer zig_luau_free(bytecode);
    return try allocator.dupe(u8, bytecode[0..size]);
}

pub fn clock() f64 {
    return c.lua_clock();
}

comptime {
    if (builtin.target.isWasm() and builtin.target.os.tag != .emscripten) {
        _ = struct {
            var exception_buf: [4096]u8 = undefined;
            var exception_fba = std.heap.FixedBufferAllocator.init(exception_buf[0..]);
            export fn __cxa_allocate_exception(size: usize) callconv(.C) [*]u8 {
                const data = exception_fba.allocator().alloc(u8, size + 4) catch unreachable;
                std.mem.writeInt(u32, data[0..4], size, .little);
                return data[4..].ptr;
            }
            export fn __cxa_free_exception(data: [*]const u8) callconv(.C) void {
                const size = std.mem.readInt(u32, (data - 4)[0..4], .little);
                exception_fba.allocator().free(data[0 .. size + 4]);
            }
            // should NEVER be called as we override in the luau upstream dependency
            export fn __cxa_throw(thrown_exception: *u8, cpp_type_info: *anyopaque, dest: *const fn () callconv(.C) void) callconv(.C) noreturn {
                _ = thrown_exception;
                _ = cpp_type_info;
                _ = dest;
                unreachable;
            }
            export fn clock() callconv(.C) i64 {
                return std.time.milliTimestamp();
            }
        };
    }
}
