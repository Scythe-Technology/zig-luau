const std = @import("std");

const Ast = @import("Ast.zig");
const Allocator = @import("Allocator.zig");
const DenseHash = @import("../Common/DenseHash.zig");

extern "c" fn zig_Luau_Ast_Lexer_AstNameTable_init(*Allocator) *AstNameTable;
extern "c" fn zig_Luau_Ast_Lexer_AstNameTable_dtor(*AstNameTable) void;

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

pub const AstNameTable = extern struct {
    data: DenseHash.DenseHashSet(Entry, EntryHash),
    allocator: *Allocator,

    const Entry = extern struct {
        value: Ast.Name,
        length: u32,
        type: Lexeme.Type,
    };

    const EntryHash = extern struct {
        pub fn hash(e: *const Entry) usize {
            var h: u32 = 2166136261;
            for (0..e.length) |i| {
                h ^= @as(u8, e.value[i]);
                h *= 16777619;
            }
            return h;
        }
        pub fn eq(_: *const Entry, _: *const Entry) bool {
            @compileError("not implemented");
        }
    };

    pub fn init(allocator: *Allocator) *AstNameTable {
        return zig_Luau_Ast_Lexer_AstNameTable_init(allocator);
    }

    pub fn deinit(self: *AstNameTable) void {
        zig_Luau_Ast_Lexer_AstNameTable_dtor(self);
    }
};

test AstNameTable {
    const allocator = Allocator.init();
    defer allocator.deinit();

    const astNameTable = AstNameTable.init(allocator);
    defer astNameTable.deinit();
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Lexer.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Lexer.cpp
