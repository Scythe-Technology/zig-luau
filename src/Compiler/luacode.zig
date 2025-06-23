const c = @import("c");
const std = @import("std");

const Compiler = @import("Compiler.zig");

extern "c" fn zig_luau_free(ptr: *anyopaque) void;

extern "c" fn luau_compile(source: [*c]const u8, size: usize, options: ?*const Compiler.CompileOptions, outsize: [*c]usize) [*c]u8;
extern "c" fn luau_set_compile_constant_nil(constant: *Compiler.CompileConstant) void;
extern "c" fn luau_set_compile_constant_boolean(constant: *Compiler.CompileConstant, b: c_int) void;
extern "c" fn luau_set_compile_constant_number(constant: *Compiler.CompileConstant, n: f64) void;
extern "c" fn luau_set_compile_constant_vector(constant: *Compiler.CompileConstant, x: f32, y: f32, z: f32, w: f32) void;
extern "c" fn luau_set_compile_constant_string(constant: *Compiler.CompileConstant, s: [*c]const u8, l: usize) void;

/// Compile luau source into bytecode, return callee owned buffer allocated through the given allocator.
pub fn compile(allocator: std.mem.Allocator, source: []const u8, options: ?Compiler.CompileOptions) ![]const u8 {
    var size: usize = 0;

    const bytecode = luau_compile(source.ptr, source.len, if (options) |*o| o else null, &size);
    if (bytecode == null)
        return error.OutOfMemory;
    defer zig_luau_free(bytecode);

    return try allocator.dupe(u8, bytecode[0..size]);
}

pub fn set_compile_constant_nil(constant: *Compiler.CompileConstant) void {
    luau_set_compile_constant_nil(constant);
}

pub fn set_compile_constant_boolean(constant: *Compiler.CompileConstant, b: bool) void {
    luau_set_compile_constant_boolean(constant, if (b) 1 else 0);
}

pub fn set_compile_constant_number(constant: *Compiler.CompileConstant, n: f64) void {
    luau_set_compile_constant_number(constant, n);
}

pub fn set_compile_constant_vector(constant: *Compiler.CompileConstant, x: f32, y: f32, z: f32, w: f32) void {
    luau_set_compile_constant_vector(constant, x, y, z, w);
}

pub fn set_compile_constant_string(constant: *Compiler.CompileConstant, s: []const u8) void {
    luau_set_compile_constant_string(constant, s.ptr, s.len);
}

// sources:
// https://github.com/luau-lang/luau/blob/8fe64db609ccbffb0abb7507c7ecef8c88327ef3/Compiler/include/luacode.h
// https://github.com/luau-lang/luau/blob/8fe64db609ccbffb0abb7507c7ecef8c88327ef3/Compiler/src/lcode.cpp
