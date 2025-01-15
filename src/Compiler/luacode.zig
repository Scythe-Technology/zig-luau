const c = @import("c");
const std = @import("std");

const Compiler = @import("Compiler.zig");

extern "c" fn zig_luau_free(ptr: *anyopaque) void;

/// Zig wrapper for Luau lua_CompileOptions that uses the same defaults as Luau if
/// no compile options is specified.
pub const CompileOptions = Compiler.CompileOptions;

/// Compile luau source into bytecode, return callee owned buffer allocated through the given allocator.
pub fn compile(allocator: std.mem.Allocator, source: []const u8, options: CompileOptions) ![]const u8 {
    var size: usize = 0;

    var opts = options.toC();
    const bytecode = c.luau_compile(source.ptr, source.len, &opts, &size);
    if (bytecode == null) return error.Memory;
    defer zig_luau_free(bytecode);
    return try allocator.dupe(u8, bytecode[0..size]);
}
