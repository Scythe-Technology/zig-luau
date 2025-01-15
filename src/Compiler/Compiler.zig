const std = @import("std");
const Parser = @import("../Ast/Parser.zig");
const Lexer = @import("../Ast/Lexer.zig");

const c = @import("c");

extern "c" fn zig_Luau_Compiler_compile_ParseResult(*const Parser.ParseResult, *const Lexer.AstNameTable, *usize, ?*c.lua_CompileOptions, ?*anyopaque) ?[*]const u8;
extern "c" fn zig_Luau_Compiler_compile_free(*anyopaque) void;

pub const CompileOptions = struct {
    optimization_level: i32 = 1,
    debug_level: i32 = 1,
    coverage_level: i32 = 0,
    /// global builtin to construct vectors; disabled by default (<vector_lib>.<vector_ctor>)
    vector_lib: ?[*:0]const u8 = null,
    vector_ctor: ?[*:0]const u8 = null,
    /// vector type name for type tables; disabled by default
    vector_type: ?[*:0]const u8 = null,
    /// null-terminated array of globals that are mutable; disables the import optimization for fields accessed through these
    mutable_globals: ?[*:null]const ?[*:0]const u8 = null,

    pub fn toC(this: CompileOptions) c.lua_CompileOptions {
        return c.lua_CompileOptions{
            .optimizationLevel = this.optimization_level,
            .debugLevel = this.debug_level,
            .coverageLevel = this.coverage_level,
            .vectorLib = this.vector_lib,
            .vectorCtor = this.vector_ctor,
            .vectorType = this.vector_type,
            .mutableGlobals = this.mutable_globals,
        };
    }
};

pub fn compileParseResult(
    allocator: std.mem.Allocator,
    parseResult: *Parser.ParseResult,
    namesTable: *Lexer.AstNameTable,
    options: ?CompileOptions,
) error{OutOfMemory}![]const u8 {
    var size: usize = 0;
    var opts = if (options) |o| o.toC() else null;
    const bytes = zig_Luau_Compiler_compile_ParseResult(parseResult, namesTable, &size, if (opts) |*o| o else null, null) orelse return error.OutOfMemory;
    defer zig_Luau_Compiler_compile_free(@ptrCast(@constCast(bytes)));
    return try allocator.dupe(u8, bytes[0..size]);
}

test compileParseResult {
    const Allocator = @import("../Ast/Allocator.zig").Allocator;

    var allocator = Allocator.init();
    defer allocator.deinit();

    var astNameTable = Lexer.AstNameTable.init(allocator);
    defer astNameTable.deinit();
    const source =
        \\--!test
        \\-- This is a test comment
        \\local x =
        \\
    ;

    var parseResult = Parser.parse(source, astNameTable, allocator);
    defer parseResult.deinit();

    const zig_allocator = std.testing.allocator;
    const bytes = try compileParseResult(zig_allocator, parseResult, astNameTable, null);
    defer zig_allocator.free(bytes);

    try std.testing.expect(bytes[0] == 0);
    try std.testing.expectEqualStrings(bytes[1..], ":4: Expected identifier when parsing expression, got <eof>");
}
