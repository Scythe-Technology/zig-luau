const std = @import("std");

const Ast = @import("Ast.zig");
const Allocator = @import("Allocator.zig");
const DenseHash2 = @import("../Common/DenseHash2.zig");

pub const Lexeme = struct {
    pub const Type = enum(c_int) {
        Eof = 0,

        // 1..255 means actual character values
        Char_END = 256,

        Equal,
        LessEqual,
        GreaterEqual,
        NotEqual,
        Dot2,
        Dot3,
        SkinnyArrow,
        DoubleColon,
        FloorDiv,

        InterpStringBegin,
        InterpStringMid,
        InterpStringEnd,
        // An interpolated string with no expressions (like `x`)
        InterpStringSimple,

        AddAssign,
        SubAssign,
        MulAssign,
        DivAssign,
        FloorDivAssign,
        ModAssign,
        PowAssign,
        ConcatAssign,

        RawString,
        QuotedString,
        Number,
        Name,

        Comment,
        BlockComment,

        Attribute,
        AttributeOpen,

        BrokenString,
        BrokenComment,
        BrokenUnicode,
        BrokenInterpDoubleBrace,
        Error,

        // Reserved_BEGIN,
        ReservedAnd,
        ReservedBreak,
        ReservedDo,
        ReservedElse,
        ReservedElseif,
        ReservedEnd,
        ReservedFalse,
        ReservedFor,
        ReservedFunction,
        ReservedIf,
        ReservedIn,
        ReservedLocal,
        ReservedNil,
        ReservedNot,
        ReservedOr,
        ReservedRepeat,
        ReservedReturn,
        ReservedThen,
        ReservedTrue,
        ReservedUntil,
        ReservedWhile,
        Reserved_END,

        pub const Reserved_BEGIN = Type.ReservedAnd;
    };
};

pub const kReserved = [_][:0]const u8{
    "and",   "break", "do",  "else", "elseif", "end",    "false", "for",  "function", "if",    "in",
    "local", "nil",   "not", "or",   "repeat", "return", "then",  "true", "until",    "while",
};

pub const AstNameTable = extern struct {
    data: DenseHash2.DenseHashSet2(Entry, EntryHash),
    allocator: *Allocator,

    const Entry = extern struct {
        value: Ast.Name,
        length: u32,
        type: Lexeme.Type,
    };

    const EntryHash = extern struct {
        pub fn hash(e: Entry) usize {
            var h: u32 = 2166136261;
            for (0..e.length) |i| {
                h ^= @as(u8, e.value.value[i]);
                h *%= 16777619;
            }
            return h;
        }
        pub fn eq(_: *const Entry, _: *const Entry) bool {
            @compileError("not implemented");
        }
    };

    pub fn init(allocator: *Allocator) !AstNameTable {
        comptime std.debug.assert(kReserved.len == @intFromEnum(Lexeme.Type.Reserved_END) - @intFromEnum(Lexeme.Type.Reserved_BEGIN));
        var ast: AstNameTable = .{
            .data = try .init(128),
            .allocator = allocator,
        };
        errdefer ast.data.deinit();
        for (kReserved, 0..) |name, i|
            _ = try ast.addStatic(name, @enumFromInt(@intFromEnum(Lexeme.Type.Reserved_BEGIN) + @as(c_int, @intCast(i))));

        return ast;
    }

    pub fn addStatic(self: *AstNameTable, name: [:0]const u8, @"type": Lexeme.Type) !Ast.Name {
        const entry: Entry = .{
            .value = .initK(name),
            .length = @intCast(name.len),
            .type = @"type",
        };

        std.debug.assert(!self.data.contains(entry));
        _ = try self.data.insert(entry);

        return entry.value;
    }
    pub fn deinit(self: *AstNameTable) void {
        self.data.deinit();
    }
};

test AstNameTable {
    var allocator = try Allocator.init();
    defer allocator.deinit();

    var astNameTable = try AstNameTable.init(&allocator);
    defer astNameTable.deinit();
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Lexer.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Lexer.cpp
