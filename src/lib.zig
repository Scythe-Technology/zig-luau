const std = @import("std");
const builtin = @import("builtin");

const build_config = @import("config");

pub const codegen = @import("CodeGen/lcodegen.zig");

pub const Analysis = if (build_config.buildAnalysis) struct {
    pub const Frontend = @import("Analysis/Frontend.zig");
    pub const FileResolver = @import("Analysis/FileResolver.zig");
    pub const AstJsonEncoder = @import("Analysis/AstJsonEncoder.zig");
    pub const GenericConfigResolver = @import("Analysis/GenericConfigResolver.zig");
    test {
        inline for (@typeInfo(@This()).@"struct".decls) |decl|
            std.testing.refAllDecls(@field(@This(), decl.name));
    }
} else void;

pub const Ast = if (build_config.buildAst) struct {
    pub const Ast = @import("Ast/Ast.zig");
    pub const Allocator = @import("Ast/Allocator.zig");
    pub const Lexer = @import("Ast/Lexer.zig");
    pub const Parser = @import("Ast/Parser.zig");
    pub const Location = @import("Ast/Location.zig");
    test {
        inline for (@typeInfo(@This()).@"struct".decls) |decl|
            std.testing.refAllDecls(@field(@This(), decl.name));
    }
} else void;

pub const Common = struct {
    pub const DenseHash = @import("Common/DenseHash.zig");
    pub const Bytecode = @import("Common/Bytecode.zig");
    pub const BytecodeUtils = @import("Common/BytecodeUtils.zig");
    pub const ExperimentalFlags = @import("Common/ExperimentalFlags.zig");
    test {
        inline for (@typeInfo(@This()).@"struct".decls) |decl|
            std.testing.refAllDecls(@field(@This(), decl.name));
    }
};

pub const Compiler = if (build_config.buildCompiler) struct {
    pub const luacode = @import("Compiler/luacode.zig");
    pub const Compiler = @import("Compiler/Compiler.zig");
    test {
        inline for (@typeInfo(@This()).@"struct".decls) |decl|
            std.testing.refAllDecls(@field(@This(), decl.name));
    }
} else void;

pub const VM = if (build_config.buildVM) struct {
    pub const lua = @import("VM/lua.zig");
    pub const ldo = @import("VM/ldo.zig");
    pub const lgc = @import("VM/lgc.zig");
    pub const ltm = @import("VM/ltm.zig");
    pub const zapi = @import("VM/zapi.zig");
    pub const lapi = @import("VM/lapi.zig");
    pub const laux = @import("VM/laux.zig");
    pub const lperf = @import("VM/lperf.zig");
    pub const linit = @import("VM/linit.zig");
    pub const lstate = @import("VM/lstate.zig");
    pub const ldebug = @import("VM/ldebug.zig");
    pub const lobject = @import("VM/lobject.zig");
    pub const lvmload = @import("VM/lvmload.zig");
    pub const lcommon = @import("VM/lcommon.zig");
    pub const lvmutils = @import("VM/lvmutils.zig");
    pub const lgcdebug = @import("VM/lgcdebug.zig");

    // libraries
    pub const lbitlib = @import("VM/lbitlib.zig");
    pub const lbaselib = @import("VM/lbaselib.zig");
    pub const lcorolib = @import("VM/lcorolib.zig");
    pub const ldblib = @import("VM/ldblib.zig");
    pub const lmathlib = @import("VM/lmathlib.zig");
    pub const loslib = @import("VM/loslib.zig");
    pub const lstrlib = @import("VM/lstrlib.zig");
    pub const ltablib = @import("VM/ltablib.zig");
    pub const lutf8lib = @import("VM/lutf8lib.zig");
    pub const lveclib = @import("VM/lveclib.zig");
    test {
        inline for (@typeInfo(@This()).@"struct".decls) |decl|
            std.testing.refAllDecls(@field(@This(), decl.name));
    }
} else void;

test {
    _ = Analysis;
    _ = Ast;
    _ = Common;
    _ = Compiler;
    _ = VM;
}

//
// VM
//
pub const LUAU_VERSION = VM.lua.config.LUAU_VERSION;
pub const VECTOR_SIZE = VM.lua.config.VECTOR_SIZE;

pub const State = VM.lua.State;

//
// Compiler
//
pub const compile = Compiler.luacode.compile;
pub const CompileOptions = Compiler.Compiler.CompileOptions;

const c_FlagGroup = extern struct {
    names: [*c][*c]const u8,
    types: [*c]c_int,
    size: usize,
};

fn FValue(comptime T: type) type {
    return extern struct {
        const Self = @This();

        value: T,
        dynamic: bool,
        name: [*c]const u8,
        next: ?*Self,

        pub const Iterator = struct {
            state: *Self,
            consumed: bool = false,

            pub fn next(self: *Iterator) ?*Self {
                const state = self.state;
                if (!self.consumed) {
                    self.consumed = true;
                    return state;
                }
                const n = state.next orelse return null;
                self.state = n;
                return n;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{
                .state = self,
            };
        }
    };
}

/// This function is defined in luau.cpp and must be called to define the assertion printer
extern "c" fn zig_registerAssertionHandler() void;

extern "c" fn zig_luau_getFValueList_bool() *FValue(bool);
extern "c" fn zig_luau_getFValueList_int() *FValue(c_int);

// Internal API
extern "c" fn zig_luau_luaD_checkstack(*anyopaque, c_int) void;
extern "c" fn zig_luau_expandstacklimit(*anyopaque, c_int) void;
extern "c" fn zig_luau_luaG_isnative(*anyopaque, c_int) c_int;

// NCG Workarounds - Minimal Debug Support for NCG
/// Luau.CodeGen mock __register_frame for a workaround Luau NCG
export fn __register_frame(frame: *const u8) void {
    _ = frame;
}
/// Luau.CodeGen mock __deregister_frame for a workaround Luau NCG
export fn __deregister_frame(frame: *const u8) void {
    _ = frame;
}

pub const FFlags = struct {
    pub fn Get(comptime T: type) *FValue(if (T == i32) c_int else T) {
        if (T == bool)
            return zig_luau_getFValueList_bool()
        else if (T == c_int or T == i32)
            return zig_luau_getFValueList_int()
        else
            @compileError("Unsupported type");
    }

    pub fn SetByName(comptime T: type, name: []const u8, value: T) !void {
        var iter = Get(T).iterator();
        while (iter.next()) |flag| {
            if (std.mem.eql(u8, std.mem.span(flag.name), name)) {
                flag.value = value;
                return;
            }
        }
        return error.UnknownFlag;
    }

    pub fn GetByName(comptime T: type, name: []const u8) ?*FValue(if (T == i32) c_int else T) {
        var iter = Get(T).iterator();
        while (iter.next()) |flag| {
            if (std.mem.eql(u8, std.mem.span(flag.name), name))
                return flag;
        }
        return null;
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

pub const CodeGen = if (!builtin.cpu.arch.isWasm()) struct {
    pub fn Supported() bool {
        return codegen.supported();
    }
    pub fn Create(luau: *VM.lua.State) void {
        codegen.create(luau);
    }
    pub fn Compile(luau: *VM.lua.State, idx: i32) void {
        codegen.compile(luau, @intCast(idx));
    }
} else struct {
    pub fn Supported() bool {
        return false;
    }
    pub fn Create(_: *VM.lua.State) void {
        @panic("CodeGen is not supported on wasm");
    }
    pub fn Compile(_: *VM.lua.State, _: i32) void {
        @panic("CodeGen is not supported on wasm");
    }
};

const alignment = @alignOf(std.c.max_align_t);

/// Allows Luau to allocate memory using a Zig allocator passed in via data.
fn alloc(data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*align(alignment) anyopaque {
    // just like malloc() returns a pointer "which is suitably aligned for any built-in type",
    // the memory allocated by this function should also be aligned for any type that Lua may
    // desire to allocate. use the largest alignment for the target
    const allocator_ptr: *std.mem.Allocator = @ptrCast(@alignCast(data.?));

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
        const new_ptr = allocator_ptr.alignedAlloc(u8, .fromByteUnits(alignment), nsize) catch return null;
        return new_ptr.ptr;
    }
}

pub fn getallocator(luau: *VM.lua.State) std.mem.Allocator {
    var data: ?*std.mem.Allocator = undefined;
    _ = luau.getallocf(@ptrCast(&data));

    if (data) |allocator_ptr| {
        // Although the Allocator is passed to Lua as a pointer, return a
        // copy to make use more convenient.
        return allocator_ptr.*;
    }

    @panic("Lua.allocator() invalid on Lua states created without a Zig allocator");
}

/// Initialize a Luau state with the given allocator
pub fn init(allocator_ptr: *const std.mem.Allocator) !*VM.lua.State {
    zig_registerAssertionHandler();
    return try VM.lstate.newstate(alloc, @constCast(allocator_ptr));
}

// Internal API functions
pub const sys = struct {
    pub inline fn luaD_checkstack(luau: *VM.lua.State, n: i32) void {
        zig_luau_luaD_checkstack(@ptrCast(luau), n);
    }
    pub inline fn luaD_expandstacklimit(luau: *VM.lua.State, n: i32) void {
        zig_luau_expandstacklimit(@ptrCast(luau), n);
    }
};

test {
    std.testing.refAllDecls(sys);
}

comptime {
    if (builtin.target.cpu.arch.isWasm() and builtin.target.os.tag != .emscripten) {
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
