const std = @import("std");

const cpp_std = @import("../cpp_std.zig");

const Ast = @import("Ast.zig");
const Cst = @import("Cst.zig");
const Lexer = @import("Lexer.zig");
const Location = @import("Location.zig").Location;
const Allocator = @import("Allocator.zig");
const DenseHash = @import("../Common/DenseHash.zig");

pub const ParseError = cpp_std.Exception(extern struct {
    location: Location,
    message: cpp_std.String,
});

pub const ParseErrors = cpp_std.Exception(extern struct {
    errors: cpp_std.Vector(ParseError),
    message: cpp_std.String,
});

pub const HotComment = extern struct {
    header: bool,
    location: Location,
    content: cpp_std.String,
};

pub const Comment = extern struct {
    type: Lexer.Lexeme.Type, // Comment, BlockComment, or BrokenComment
    location: Location,
};

pub const ParseOptions = extern struct {
    allowDeclarationSyntax: bool = false,
    captureComments: bool = false,
    parseFragment: cpp_std.Optional(FragmentParseResumeSettings) = .nullopt,
    storeCstData: bool = false,
    noErrorLimit: bool = false,

    pub const FragmentParseResumeSettings = extern struct {
        localMap: DenseHash.DenseHashMap(Ast.Name, *Ast.Local, struct {}) = .init(.{ .value = "" }, 0),
        localStack: cpp_std.Vector(*Ast.Local) = undefined,
        resumePosition: Location.Position,
    };
};

extern "c" fn zig_Luau_Ast_Parser_parse([*]const u8, usize, *Lexer.AstNameTable, *Allocator, *const ParseOptions) *ParseResult;
extern "c" fn zig_Luau_Ast_Parser_parseExpr([*]const u8, usize, *Lexer.AstNameTable, *Allocator, *const ParseOptions) *ParseExprResult;
extern "c" fn zig_Luau_Ast_ParseResult_dtor(*ParseResult) void;
extern "c" fn zig_Luau_Ast_ParseExprResult_dtor(*ParseExprResult) void;

pub fn parse(source: []const u8, nameTable: *Lexer.AstNameTable, allocator: *Allocator, options: ParseOptions) *ParseResult {
    return zig_Luau_Ast_Parser_parse(source.ptr, source.len, nameTable, allocator, &options);
}

pub fn parseExpr(source: []const u8, nameTable: *Lexer.AstNameTable, allocator: *Allocator, options: ParseOptions) *ParseExprResult {
    return zig_Luau_Ast_Parser_parseExpr(source.ptr, source.len, nameTable, allocator, &options);
}

pub const CstNodeMap = DenseHash.DenseHashMap(*Ast.Node, *Cst.Node, struct {});

pub const ParseResult = extern struct {
    root: *Ast.StatBlock,
    lines: usize = 0,

    hotcomments: cpp_std.Vector(HotComment),
    errors: cpp_std.Vector(ParseError),

    commentLocations: cpp_std.Vector(Comment),

    cstNodeMap: CstNodeMap,

    pub inline fn deinit(self: *ParseResult) void {
        zig_Luau_Ast_ParseResult_dtor(self);
    }
};

pub const ParseExprResult = extern struct {
    expr: *Ast.StatExpr,
    lines: usize = 0,

    hotcomments: cpp_std.Vector(HotComment),
    errors: cpp_std.Vector(ParseError),

    commentLocations: cpp_std.Vector(Comment),

    cstNodeMap: CstNodeMap,

    pub inline fn deinit(self: *ParseExprResult) void {
        zig_Luau_Ast_ParseExprResult_dtor(self);
    }
};

test ParseResult {
    {
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

        var parseResult = parse(source, astNameTable, allocator, .{});
        defer parseResult.deinit();

        {
            var iter = parseResult.hotcomments.iterator();
            var count: usize = 0;
            while (iter.next()) |comment| : (count += 1) {
                const string = comment.content.slice();
                try std.testing.expectEqualStrings("test", string);
                try std.testing.expectEqual(true, comment.header);
                try std.testing.expectEqual(0, comment.location.begin.line);
                try std.testing.expectEqual(0, comment.location.begin.column);
                try std.testing.expectEqual(0, comment.location.end.line);
                try std.testing.expectEqual(7, comment.location.end.column);
            }

            try std.testing.expectEqual(1, count);
        }

        {
            try std.testing.expectEqual(1, parseResult.errors.size());
            const first = parseResult.errors.at(0).value;
            try std.testing.expectEqualStrings("Expected identifier when parsing expression, got <eof>", first.message.slice());
            try std.testing.expectEqual(3, first.location.begin.line);
            try std.testing.expectEqual(0, first.location.begin.column);
            try std.testing.expectEqual(3, first.location.end.line);
            try std.testing.expectEqual(0, first.location.end.column);
        }
    }
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Parser.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Parser.cpp
