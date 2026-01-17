const std = @import("std");

const lua = @import("../VM/lua.zig");
const Parser = @import("../Ast/Parser.zig");
const Lexer = @import("../Ast/Lexer.zig");
const Location = @import("../Ast/Location.zig").Location;

const cpp_std = @import("../cpp_std.zig");

pub const CompileConstant = *anyopaque;

/// return a type identifier for a global library member
/// values are defined by 'enum LuauBytecodeType' in Bytecode.h
pub const LibraryMemberTypeCallback = *const fn (library: [*c]const u8, member: [*c]const u8) callconv(.c) c_int;

/// setup a value of a constant for a global library member
/// use setCompileConstant*** set of functions for values
pub const LibraryMemberConstantCallback = *const fn (library: [*c]const u8, member: [*c]const u8, constant: *CompileConstant) callconv(.c) c_int;

pub const CompileOptions = extern struct {
    /// 0 - no optimization
    /// 1 - baseline optimization level that doesn't prevent debuggability
    /// 2 - includes optimizations that harm debuggability such as inlining
    optimizationLevel: c_int = 1,
    /// 0 - no debugging support
    /// 1 - line info & function names only; sufficient for backtraces
    /// 2 - full debug info with local & upvalue names; necessary for debugger
    debugLevel: c_int = 1,
    /// type information is used to guide native code generation decisions
    /// information includes testable typeArguments for function arguments, locals, upvalues and some temporaries
    /// 0 - generate for native modules
    /// 1 - generate for all modules
    typeInfoLevel: c_int = 0,
    /// 0 - no code coverage support
    /// 1 - statement coverage
    /// 2 - statement and expression coverage (verbose)
    coverageLevel: c_int = 0,

    /// alternative global builtin to construct vectors, in addition to default builtin 'vector.create'
    vectorLib: [*c]const u8 = null,
    vectorCtor: [*c]const u8 = null,

    /// alternative vector type name for type tables, in addition to default type 'vector'
    vectorType: [*c]const u8 = null,

    /// null-terminated array of globals that are mutable; disables the import optimization for fields accessed through these
    mutableGlobals: [*c]const [*c]const u8 = null,

    /// null-terminated array of userdata typeArguments that will be included in the type information
    userdataTypes: [*c]const [*c]const u8 = null,

    /// null-terminated array of globals which act as libraries and have members with known type and/or constant value
    /// when an import of one of these libraries is accessed, callbacks below will be called to receive that information
    librariesWithKnownMembers: [*c]const [*c]const u8 = null,
    libraryMemberTypeCb: ?LibraryMemberTypeCallback = null,
    libraryMemberConstantCb: ?LibraryMemberConstantCallback = null,

    // null-terminated array of library functions that should not be compiled into a built-in fastcall ("name" "lib.name")
    disabledBuiltins: [*c]const [*c]const u8 = null,
};

pub const CompilerError = cpp_std.Exception(extern struct {
    location: Location,
    message: cpp_std.String,
});

extern "c" fn zig_Luau_Compiler_compile_ParseResult(
    *const Parser.ParseResult,
    *const Lexer.AstNameTable,
    *usize,
    ?*const CompileOptions,
    ?*anyopaque,
) ?[*]const u8;
extern "c" fn zig_Luau_Compiler_compileLoad_ParseResult(
    *const Parser.ParseResult,
    *const Lexer.AstNameTable,
    *lua.State,
    [*c]const u8,
    ?*const CompileOptions,
    c_int,
    ?*anyopaque,
) c_int;
extern "c" fn zig_Luau_Compiler_compileLoad(
    *lua.State,
    [*c]const u8,
    [*c]const u8,
    usize,
    ?*const CompileOptions,
    c_int,
) c_int;
extern "c" fn zig_Luau_Compiler_compile_free(*anyopaque) void;

pub fn compileParseResult(
    allocator: std.mem.Allocator,
    parseResult: *Parser.ParseResult,
    namesTable: *Lexer.AstNameTable,
    options: ?CompileOptions,
) error{OutOfMemory}![]const u8 {
    var size: usize = 0;
    const bytes = zig_Luau_Compiler_compile_ParseResult(parseResult, namesTable, &size, if (options) |*o| o else null, null) orelse return error.OutOfMemory;
    defer zig_Luau_Compiler_compile_free(@ptrCast(@constCast(bytes)));
    return try allocator.dupe(u8, bytes[0..size]);
}

pub fn compileLoadParseResult(
    L: *lua.State,
    moduleName: [:0]const u8,
    parseResult: *Parser.ParseResult,
    namesTable: *Lexer.AstNameTable,
    options: ?CompileOptions,
    env: i32,
) error{Fail}!void {
    if (zig_Luau_Compiler_compileLoad_ParseResult(parseResult, namesTable, L, moduleName, if (options) |*o| o else null, env, null) != 0)
        return error.Fail;
}

pub fn compileLoad(
    L: *lua.State,
    moduleName: [:0]const u8,
    source: []const u8,
    options: ?CompileOptions,
    env: i32,
) error{Fail}!void {
    if (zig_Luau_Compiler_compileLoad(L, moduleName, source.ptr, source.len, if (options) |*o| o else null, env) != 0)
        return error.Fail;
}

test compileParseResult {
    const Allocator = @import("../Ast/Allocator.zig");

    const allocator = Allocator.init();
    defer allocator.deinit();

    const astNameTable = Lexer.AstNameTable.init(allocator);
    defer astNameTable.deinit();

    const source =
        \\--!test
        \\-- This is a test comment
        \\local x =
        \\
    ;

    const parseResult = Parser.parse(source, astNameTable, allocator, .{});
    defer parseResult.deinit();

    const zig_allocator = std.testing.allocator;
    const bytes = try compileParseResult(zig_allocator, parseResult, astNameTable, null);
    defer zig_allocator.free(bytes);

    try std.testing.expect(bytes[0] == 0);
    try std.testing.expectEqualStrings(":4: Expected identifier when parsing expression, got <eof>", bytes[1..]);
}

// sources:
// https://github.com/luau-lang/luau/blob/8fe64db609ccbffb0abb7507c7ecef8c88327ef3/Compiler/include/Luau/Compiler.h
// https://github.com/luau-lang/luau/blob/8fe64db609ccbffb0abb7507c7ecef8c88327ef3/Compiler/src/Compiler.cpp
