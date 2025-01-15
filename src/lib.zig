const std = @import("std");
const builtin = @import("builtin");

pub const codegen = @import("CodeGen/lcodegen.zig");

pub const Ast = struct {
    pub const Allocator = @import("Ast/Allocator.zig");
    pub const Lexer = @import("Ast/Lexer.zig");
    pub const Parser = @import("Ast/Parser.zig");
    test {
        std.testing.refAllDecls(Parser);
        std.testing.refAllDecls(Lexer);
        std.testing.refAllDecls(Allocator);
    }
};

pub const VM = struct {
    pub const zapi = @import("VM/zapi.zig");
    pub const lapi = @import("VM/lapi.zig");
    pub const laux = @import("VM/laux.zig");
    pub const ldo = @import("VM/ldo.zig");
    pub const lgc = @import("VM/lgc.zig");
    pub const ltm = @import("VM/ltm.zig");
    pub const lua = @import("VM/lua.zig");
    pub const lperf = @import("VM/lperf.zig");
    pub const lstate = @import("VM/lstate.zig");
    pub const lobject = @import("VM/lobject.zig");
    pub const lvmload = @import("VM/lvmload.zig");
    test {
        std.testing.refAllDecls(zapi);
        std.testing.refAllDecls(lapi);
        std.testing.refAllDecls(laux);
        std.testing.refAllDecls(ldo);
        std.testing.refAllDecls(lgc);
        std.testing.refAllDecls(ltm);
        std.testing.refAllDecls(lua);
        std.testing.refAllDecls(lperf);
        std.testing.refAllDecls(lstate);
        std.testing.refAllDecls(lobject);
        std.testing.refAllDecls(lvmload);
    }
};

pub const Compiler = struct {
    pub const luacode = @import("Compiler/luacode.zig");
    pub const Compiler = @import("Compiler/Compiler.zig");
    test {
        std.testing.refAllDecls(luacode);
        std.testing.refAllDecls(@import("Compiler/Compiler.zig"));
    }
};

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

/// This function is defined in luau.cpp and must be called to define the assertion printer
extern "c" fn zig_registerAssertionHandler() void;

/// This function is defined in luau.cpp and ensures Zig uses the correct free when compiling luau code
extern "c" fn zig_luau_freeflags(c_FlagGroup) void;

extern "c" fn zig_luau_setflag_bool([*]const u8, usize, bool) bool;
extern "c" fn zig_luau_setflag_int([*]const u8, usize, c_int) bool;
extern "c" fn zig_luau_getflag_bool([*]const u8, usize, *bool) bool;
extern "c" fn zig_luau_getflag_int([*]const u8, usize, *c_int) bool;

extern "c" fn zig_luau_getflags() c_FlagGroup;

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

pub const Flags = struct {
    allocator: std.mem.Allocator,
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

    pub fn getFlags(allocator: std.mem.Allocator) !Flags {
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
        const new_ptr = allocator_ptr.alignedAlloc(u8, alignment, nsize) catch return null;
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
