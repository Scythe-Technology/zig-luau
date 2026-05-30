const std = @import("std");

const Ast = @import("Ast.zig");
const Location = @import("Location.zig").Location;

const cpp_std = @import("../cpp_std.zig");

const Cst = @This();

pub const Node = extern struct {
    classIndex: Kind,

    pub const Kind = enum(i32) {
        unknown,
        expr_group,
        expr_constant_number,
        expr_constant_integer,
        expr_constant_string,
        expr_call,
        expr_index_expr,
        expr_function,
        expr_table,
        expr_op,
        expr_type_assertion,
        expr_if_else,
        expr_interp_string,
        expr_explicit_type_instantiation,
        stat_do,
        stat_repeat,
        stat_return,
        stat_local,
        stat_for,
        stat_for_in,
        stat_assign,
        stat_compound_assign,
        stat_function,
        stat_local_function,
        generic_type,
        generic_type_pack,
        stat_type_alias,
        stat_type_function,
        type_reference,
        type_table,
        type_function,
        type_typeof,
        type_union,
        type_intersection,
        type_singleton_string,
        type_group,
        type_pack_explicit,
        type_pack_generic,

        pub fn Type(comptime self: Kind) type {
            return switch (self) {
                .unknown => Node,
                .expr_group => ExprGroup,
                .expr_constant_number => ExprConstantNumber,
                .expr_constant_integer => ExprConstantInteger,
                .expr_constant_string => ExprConstantString,
                .expr_call => ExprCall,
                .expr_index_expr => ExprIndexExpr,
                .expr_function => ExprFunction,
                .expr_table => ExprTable,
                .expr_op => ExprOp,
                .expr_type_assertion => ExprTypeAssertion,
                .expr_if_else => ExprIfElse,
                .expr_interp_string => ExprInterpString,
                .expr_explicit_type_instantiation => ExprExplicitTypeInstantiation,
                .stat_do => StatDo,
                .stat_repeat => StatRepeat,
                .stat_return => StatReturn,
                .stat_local => StatLocal,
                .stat_for => StatFor,
                .stat_for_in => StatForIn,
                .stat_assign => StatAssign,
                .stat_compound_assign => StatCompoundAssign,
                .stat_function => StatFunction,
                .stat_local_function => StatLocalFunction,
                .generic_type => GenericType,
                .generic_type_pack => GenericTypePack,
                .stat_type_alias => StatTypeAlias,
                .stat_type_function => StatTypeFunction,
                .type_reference => TypeReference,
                .type_table => TypeTable,
                .type_function => TypeFunction,
                .type_typeof => TypeTypeof,
                .type_union => TypeUnion,
                .type_intersection => TypeIntersection,
                .type_singleton_string => TypeSingletonString,
                .type_group => TypeGroup,
                .type_pack_explicit => TypePackExplicit,
                .type_pack_generic => TypePackGeneric,
            };
        }
    };

    pub const is = IsFn;
    pub const as = AsCastFn;
};

pub fn IsFn(base: anytype, comptime to: Node.Kind) bool {
    return base.classIndex == to;
}

pub fn AsCastFn(base: anytype, comptime to: Node.Kind) ?*to.Type() {
    return if (base.classIndex == to) @ptrCast(@alignCast(base)) else null;
}

pub const ExprGroup = extern struct {
    classIndex: Node.Kind,

    closePosition: Location.Position,
};

pub const ExprConstantNumber = extern struct {
    classIndex: Node.Kind,

    value: Ast.Array(u8),
};

pub const ExprConstantInteger = extern struct {
    classIndex: Node.Kind,

    value: Ast.Array(u8),
};

pub const ExprConstantString = extern struct {
    classIndex: Node.Kind,

    sourceString: Ast.Array(u8),
    quoteStyle: QuoteStyle,
    blockDepth: u32,

    pub const QuoteStyle = enum(u32) {
        quoted_single,
        quoted_double,
        quoted_raw,
        quoted_interp,
    };
};

pub const TypeInstantiation = extern struct {
    leftArrow1Position: Location.Position = .zeros,
    leftArrow2Position: Location.Position = .zeros,

    commaPositions: Ast.Array(Location.Position),

    rightArrow1Position: Location.Position = .zeros,
    rightArrow2Position: Location.Position = .zeros,
};

pub const ExprCall = extern struct {
    classIndex: Node.Kind,

    openParens: cpp_std.Optional(Location.Position),
    closeParens: cpp_std.Optional(Location.Position),
    commaPositions: Ast.Array(Location.Position),
    explicitTypes: ?*TypeInstantiation = null,
};

pub const ExprIndexExpr = extern struct {
    classIndex: Node.Kind,

    openBracketPosition: Location.Position,
    closeBracketPosition: Location.Position,
};

pub const ExprFunction = extern struct {
    classIndex: Node.Kind,

    functionKeywordPosition: Location.Position,
    openGenericsPosition: Location.Position,
    genericsCommaPositions: Ast.Array(Location.Position),
    closeGenericsPosition: Location.Position,
    argsAnnotationColonPositions: Ast.Array(Location.Position),
    argsCommaPositions: Ast.Array(Location.Position),
    varargAnnotationColonPosition: Location.Position,
    returnSpecifierPosition: Location.Position,
};

pub const ExprTable = extern struct {
    classIndex: Node.Kind,

    items: Ast.Array(Item),

    pub const Separator = enum(u32) {
        comma,
        semicolon,
    };

    pub const Item = extern struct {
        /// '[', only if Kind == General
        indexerOpenPosition: cpp_std.Optional(Location.Position),
        /// ']', only if Kind == General
        indexerClosePosition: cpp_std.Optional(Location.Position),
        /// only if Kind != List
        equalsPosition: cpp_std.Optional(Location.Position),
        /// may be missing for last Item
        separator: cpp_std.Optional(Separator),
        /// may be missing for last Item
        separatorPosition: cpp_std.Optional(Location.Position),
    };
};

pub const ExprOp = extern struct {
    classIndex: Node.Kind,

    opPosition: Location.Position,
};

pub const ExprTypeAssertion = extern struct {
    classIndex: Node.Kind,

    opPosition: Location.Position,
};

pub const ExprIfElse = extern struct {
    classIndex: Node.Kind,

    thenPosition: Location.Position,
    elsePosition: Location.Position,
    isElseIf: bool,
};

pub const ExprInterpString = extern struct {
    classIndex: Node.Kind,

    sourceStrings: Ast.Array(Ast.Array(u8)),
    stringPositions: Ast.Array(Location.Position),
};

pub const ExprExplicitTypeInstantiation = extern struct {
    classIndex: Node.Kind,

    instantiation: TypeInstantiation,
};

pub const StatDo = extern struct {
    classIndex: Node.Kind,

    statsStartPosition: Location.Position,
    endPosition: Location.Position,
};

pub const StatRepeat = extern struct {
    classIndex: Node.Kind,

    untilPosition: Location.Position,
};

pub const StatReturn = extern struct {
    classIndex: Node.Kind,

    commaPositions: Ast.Array(Location.Position),
};

pub const StatLocal = extern struct {
    classIndex: Node.Kind,

    varsAnnotationColonPositions: Ast.Array(Location.Position),
    varsCommaPositions: Ast.Array(Location.Position),
    valuesCommaPositions: Ast.Array(Location.Position),
};

pub const StatFor = extern struct {
    classIndex: Node.Kind,

    annotationColonPosition: Location.Position,
    equalsPosition: Location.Position,
    endCommaPosition: Location.Position,
    stepCommaPosition: cpp_std.Optional(Location.Position),
};

pub const StatForIn = extern struct {
    classIndex: Node.Kind,

    varsAnnotationColonPositions: Ast.Array(Location.Position),
    varsCommaPositions: Ast.Array(Location.Position),
    valuesCommaPositions: Ast.Array(Location.Position),
};

pub const StatAssign = extern struct {
    classIndex: Node.Kind,

    varsCommaPositions: Ast.Array(Location.Position),
    equalsPosition: Location.Position,
    valuesCommaPositions: Ast.Array(Location.Position),
};

pub const StatCompoundAssign = extern struct {
    classIndex: Node.Kind,

    opPosition: Location.Position,
};

pub const StatFunction = extern struct {
    classIndex: Node.Kind,

    functionKeywordPosition: Location.Position,
};

pub const StatLocalFunction = extern struct {
    classIndex: Node.Kind,

    localKeywordPosition: Location.Position,
    functionKeywordPosition: Location.Position,
};

pub const GenericType = extern struct {
    classIndex: Node.Kind,

    defaultEqualsPosition: cpp_std.Optional(Location.Position),
};

pub const GenericTypePack = extern struct {
    classIndex: Node.Kind,

    ellipsisPosition: Location.Position,
    defaultEqualsPosition: cpp_std.Optional(Location.Position),
};

pub const StatTypeAlias = extern struct {
    classIndex: Node.Kind,

    typeKeywordPosition: Location.Position,
    genericsOpenPosition: Location.Position,
    genericsCommaPositions: Ast.Array(Location.Position),
    genericsClosePosition: Location.Position,
    equalsPosition: Location.Position,
};

pub const StatTypeFunction = extern struct {
    classIndex: Node.Kind,

    typeKeywordPosition: Location.Position,
    functionKeywordPosition: Location.Position,
};

pub const TypeReference = extern struct {
    classIndex: Node.Kind,

    prefixPointPosition: cpp_std.Optional(Location.Position),
    openParametersPosition: Location.Position,
    parametersCommaPositions: Ast.Array(Location.Position),
    closeParametersPosition: Location.Position,
};

pub const TypeTable = extern struct {
    classIndex: Node.Kind,

    items: Ast.Array(Item),
    isArray: bool,

    pub const Item = extern struct {
        kind: Kind,
        indexerOpenPosition: Location.Position, // '[', only if Kind != Property
        indexerClosePosition: Location.Position, // ']' only if Kind != Property
        colonPosition: Location.Position,
        separator: cpp_std.Optional(ExprTable.Separator), // may be missing for last Item
        separatorPosition: cpp_std.Optional(Location.Position),

        stringInfo: ?*ExprConstantString, // only if Kind == StringProperty
        stringPosition: Location.Position, // only if Kind == StringProperty

        pub const Kind = enum(u32) {
            indexer,
            property,
            string_property,
        };
    };
};

pub const TypeFunction = extern struct {
    classIndex: Node.Kind,

    openGenericsPosition: Location.Position,
    genericsCommaPositions: Ast.Array(Location.Position),
    closeGenericsPosition: Location.Position,
    openArgsPosition: Location.Position,
    argumentNameColonPositions: Ast.Array(cpp_std.Optional(Location.Position)),
    argumentsCommaPositions: Ast.Array(Location.Position),
    closeArgsPosition: Location.Position,
    returnArrowPosition: Location.Position,
};

pub const TypeTypeof = extern struct {
    classIndex: Node.Kind,

    openPosition: Location.Position,
    closePosition: Location.Position,
};

pub const TypeUnion = extern struct {
    classIndex: Node.Kind,

    leadingPosition: cpp_std.Optional(Location.Position),
    separatorPositions: Ast.Array(Location.Position),
};

pub const TypeIntersection = extern struct {
    classIndex: Node.Kind,

    leadingPosition: cpp_std.Optional(Location.Position),
    separatorPositions: Ast.Array(Location.Position),
};

pub const TypeSingletonString = extern struct {
    classIndex: Node.Kind,

    sourceString: Ast.Array(u8),
    quoteStyle: ExprConstantString.QuoteStyle,
    blockDepth: u32,
};

pub const TypeGroup = extern struct {
    classIndex: Node.Kind,

    closePosition: Location.Position,
};

pub const TypePackExplicit = extern struct {
    classIndex: Node.Kind,

    hasParentheses: bool,
    openParenthesesPosition: Location.Position,
    closeParenthesesPosition: Location.Position,
    commaPositions: Ast.Array(Location.Position),
};

pub const TypePackGeneric = extern struct {
    classIndex: Node.Kind,

    ellipsisPosition: Location.Position,
};

test Node {
    const Lexer = @import("Lexer.zig");
    const Parser = @import("Parser.zig");
    const Allocator = @import("Allocator.zig");

    {
        const allocator = Allocator.init();
        defer allocator.deinit();

        const table = Lexer.AstNameTable.init(allocator);
        defer table.deinit();
        const source =
            \\local x: number = 1;
            \\local x = 2
            \\local x = 3
            \\
        ;

        var parse_result = Parser.parse(source, table, allocator, .{
            .storeCstData = true,
        });
        defer parse_result.deinit();

        const root = parse_result.root;

        try std.testing.expectEqual(Ast.Node.Kind.stat_block, root.classIndex);

        const stats = root.body.slice();
        try std.testing.expectEqual(3, stats.len);

        try std.testing.expectEqual(7, parse_result.cstNodeMap.count);

        try std.testing.expect(parse_result.cstNodeMap.find(@ptrCast(@alignCast(root))) == null);

        for (stats, 1..) |node, order| {
            switch (node.classIndex) {
                .stat_local => {
                    const local: *Ast.StatLocal = node.as(.stat_local).?;
                    const cst_node = (parse_result.cstNodeMap.find(@ptrCast(@alignCast(node))) orelse @panic("Not found")).second;
                    const cst_local: *StatLocal = cst_node.as(.stat_local).?;
                    try std.testing.expect(cst_local.varsCommaPositions.size == 0);
                    try std.testing.expect(cst_local.valuesCommaPositions.size == 0);
                    try std.testing.expect(cst_local.varsAnnotationColonPositions.size == 1);
                    try std.testing.expectEqualStrings("x", std.mem.span(local.vars.slice()[0].name.value));
                    try std.testing.expect(@as(f64, @floatFromInt(order)) == local.values.slice()[0].as(.expr_constant_number).?.value);
                },
                else => {},
            }
        }
    }
}

test "Index" {
    if (@import("builtin").cpu.arch.isWasm() or @import("builtin").os.tag == .windows)
        return error.SkipZigTest;
    const Indexes = struct {
        extern "c" const CstExprGroupIndex: u8;
        extern "c" const CstExprConstantNumberIndex: u8;
        extern "c" const CstExprConstantIntegerIndex: u8;
        extern "c" const CstExprConstantStringIndex: u8;
        extern "c" const CstExprCallIndex: u8;
        extern "c" const CstExprIndexExprIndex: u8;
        extern "c" const CstExprFunctionIndex: u8;
        extern "c" const CstExprTableIndex: u8;
        extern "c" const CstExprOpIndex: u8;
        extern "c" const CstExprTypeAssertionIndex: u8;
        extern "c" const CstExprIfElseIndex: u8;
        extern "c" const CstExprInterpStringIndex: u8;
        extern "c" const CstExprExplicitTypeInstantiationIndex: u8;
        extern "c" const CstStatDoIndex: u8;
        extern "c" const CstStatRepeatIndex: u8;
        extern "c" const CstStatReturnIndex: u8;
        extern "c" const CstStatLocalIndex: u8;
        extern "c" const CstStatForIndex: u8;
        extern "c" const CstStatForInIndex: u8;
        extern "c" const CstStatAssignIndex: u8;
        extern "c" const CstStatCompoundAssignIndex: u8;
        extern "c" const CstStatFunctionIndex: u8;
        extern "c" const CstStatLocalFunctionIndex: u8;
        extern "c" const CstGenericTypeIndex: u8;
        extern "c" const CstGenericTypePackIndex: u8;
        extern "c" const CstStatTypeAliasIndex: u8;
        extern "c" const CstStatTypeFunctionIndex: u8;
        extern "c" const CstTypeReferenceIndex: u8;
        extern "c" const CstTypeTableIndex: u8;
        extern "c" const CstTypeTableItemKindIndexer: u8;
        extern "c" const CstTypeTableItemKindProperty: u8;
        extern "c" const CstTypeTableItemKindStringProperty: u8;
        extern "c" const CstTypeFunctionIndex: u8;
        extern "c" const CstTypeTypeofIndex: u8;
        extern "c" const CstTypeUnionIndex: u8;
        extern "c" const CstTypeIntersectionIndex: u8;
        extern "c" const CstTypeSingletonStringIndex: u8;
        extern "c" const CstTypeGroupIndex: u8;
        extern "c" const CstTypePackExplicitIndex: u8;
        extern "c" const CstTypePackGenericIndex: u8;
    };

    try std.testing.expect(Indexes.CstExprGroupIndex == @intFromEnum(Node.Kind.expr_group));
    try std.testing.expect(Indexes.CstExprConstantNumberIndex == @intFromEnum(Node.Kind.expr_constant_number));
    try std.testing.expect(Indexes.CstExprConstantIntegerIndex == @intFromEnum(Node.Kind.expr_constant_integer));
    try std.testing.expect(Indexes.CstExprConstantStringIndex == @intFromEnum(Node.Kind.expr_constant_string));
    try std.testing.expect(Indexes.CstExprCallIndex == @intFromEnum(Node.Kind.expr_call));
    try std.testing.expect(Indexes.CstExprIndexExprIndex == @intFromEnum(Node.Kind.expr_index_expr));
    try std.testing.expect(Indexes.CstExprFunctionIndex == @intFromEnum(Node.Kind.expr_function));
    try std.testing.expect(Indexes.CstExprTableIndex == @intFromEnum(Node.Kind.expr_table));
    try std.testing.expect(Indexes.CstExprOpIndex == @intFromEnum(Node.Kind.expr_op));
    try std.testing.expect(Indexes.CstExprTypeAssertionIndex == @intFromEnum(Node.Kind.expr_type_assertion));
    try std.testing.expect(Indexes.CstExprIfElseIndex == @intFromEnum(Node.Kind.expr_if_else));
    try std.testing.expect(Indexes.CstExprInterpStringIndex == @intFromEnum(Node.Kind.expr_interp_string));
    try std.testing.expect(Indexes.CstExprExplicitTypeInstantiationIndex == @intFromEnum(Node.Kind.expr_explicit_type_instantiation));
    try std.testing.expect(Indexes.CstStatDoIndex == @intFromEnum(Node.Kind.stat_do));
    try std.testing.expect(Indexes.CstStatRepeatIndex == @intFromEnum(Node.Kind.stat_repeat));
    try std.testing.expect(Indexes.CstStatReturnIndex == @intFromEnum(Node.Kind.stat_return));
    try std.testing.expect(Indexes.CstStatLocalIndex == @intFromEnum(Node.Kind.stat_local));
    try std.testing.expect(Indexes.CstStatForIndex == @intFromEnum(Node.Kind.stat_for));
    try std.testing.expect(Indexes.CstStatForInIndex == @intFromEnum(Node.Kind.stat_for_in));
    try std.testing.expect(Indexes.CstStatAssignIndex == @intFromEnum(Node.Kind.stat_assign));
    try std.testing.expect(Indexes.CstStatCompoundAssignIndex == @intFromEnum(Node.Kind.stat_compound_assign));
    try std.testing.expect(Indexes.CstStatFunctionIndex == @intFromEnum(Node.Kind.stat_function));
    try std.testing.expect(Indexes.CstStatLocalFunctionIndex == @intFromEnum(Node.Kind.stat_local_function));
    try std.testing.expect(Indexes.CstGenericTypeIndex == @intFromEnum(Node.Kind.generic_type));
    try std.testing.expect(Indexes.CstGenericTypePackIndex == @intFromEnum(Node.Kind.generic_type_pack));
    try std.testing.expect(Indexes.CstStatTypeAliasIndex == @intFromEnum(Node.Kind.stat_type_alias));
    try std.testing.expect(Indexes.CstStatTypeFunctionIndex == @intFromEnum(Node.Kind.stat_type_function));
    try std.testing.expect(Indexes.CstTypeReferenceIndex == @intFromEnum(Node.Kind.type_reference));
    try std.testing.expect(Indexes.CstTypeTableIndex == @intFromEnum(Node.Kind.type_table));
    try std.testing.expect(Indexes.CstTypeTableItemKindIndexer == @intFromEnum(TypeTable.Item.Kind.indexer));
    try std.testing.expect(Indexes.CstTypeTableItemKindProperty == @intFromEnum(TypeTable.Item.Kind.property));
    try std.testing.expect(Indexes.CstTypeTableItemKindStringProperty == @intFromEnum(TypeTable.Item.Kind.string_property));
    try std.testing.expect(Indexes.CstTypeFunctionIndex == @intFromEnum(Node.Kind.type_function));
    try std.testing.expect(Indexes.CstTypeTypeofIndex == @intFromEnum(Node.Kind.type_typeof));
    try std.testing.expect(Indexes.CstTypeUnionIndex == @intFromEnum(Node.Kind.type_union));
    try std.testing.expect(Indexes.CstTypeIntersectionIndex == @intFromEnum(Node.Kind.type_intersection));
    try std.testing.expect(Indexes.CstTypeSingletonStringIndex == @intFromEnum(Node.Kind.type_singleton_string));
    try std.testing.expect(Indexes.CstTypeGroupIndex == @intFromEnum(Node.Kind.type_group));
    try std.testing.expect(Indexes.CstTypePackExplicitIndex == @intFromEnum(Node.Kind.type_pack_explicit));
    try std.testing.expect(Indexes.CstTypePackGenericIndex == @intFromEnum(Node.Kind.type_pack_generic));
}

// sources:
// https://github.com/luau-lang/luau/blob/40d4815888f63362a6cb79b3e74c4aafa0b2cbf4/Ast/include/Luau/Cst.h
// https://github.com/luau-lang/luau/blob/40d4815888f63362a6cb79b3e74c4aafa0b2cbf4/Ast/src/Cst.cpp
