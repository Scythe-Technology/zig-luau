const std = @import("std");

const Ast = @import("Ast.zig");
const Location = @import("Location.zig").Location;

const cpp_std = @import("../cpp_std.zig");

const Cst = @This();

pub const Node = extern struct {
    classIndex: Kind,

    pub const Kind = enum(i32) {
        unknown,
        attr,
        parametrized_attr,
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
                .attr => Attr,
                .parametrized_attr => ParametrizedAttr,
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

pub const Attr = extern struct {
    classIndex: Node.Kind = .attr,

    /// false when inside an attribute list, ie @[native checked]
    hasAt: bool,
};

pub const ParametrizedAttr = extern struct {
    classIndex: Node.Kind = .parametrized_attr,

    /// for `@x(args)` form
    openParenPosition: Location.Position,
    closeParenPosition: Location.Position,

    /// Commas inside the `(a, b, c)` arg list
    argsCommaPositions: Ast.Array(Location.Position),
};

pub const AttrList = extern struct {
    atBracketPosition: Location.Position,
    closeBracketPosition: Location.Position,
    commaPositions: Ast.Array(Location.Position),
};

pub const ExprGroup = extern struct {
    classIndex: Node.Kind = .expr_group,

    closePosition: Location.Position,
};

pub const ExprConstantNumber = extern struct {
    classIndex: Node.Kind = .expr_constant_number,

    value: Ast.Array(u8),
};

pub const ExprConstantInteger = extern struct {
    classIndex: Node.Kind = .expr_constant_integer,

    value: Ast.Array(u8),
};

pub const ExprConstantString = extern struct {
    classIndex: Node.Kind = .expr_constant_string,

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
    leftArrow1Position: Location.Position = .missing,
    leftArrow2Position: Location.Position = .missing,

    commaPositions: Ast.Array(Location.Position),

    rightArrow1Position: Location.Position = .missing,
    rightArrow2Position: Location.Position = .missing,
};

pub const ExprCall = extern struct {
    classIndex: Node.Kind = .expr_call,

    openParens: Location.Position,
    closeParens: Location.Position,
    commaPositions: Ast.Array(Location.Position),
    explicitTypes: ?*TypeInstantiation = null,
};

pub const ExprIndexExpr = extern struct {
    classIndex: Node.Kind = .expr_index_expr,

    openBracketPosition: Location.Position,
    closeBracketPosition: Location.Position,
};

pub const ExprFunction = extern struct {
    classIndex: Node.Kind = .expr_function,

    attrLists: Ast.Array(*AttrList) = .{},
    functionKeywordPosition: Location.Position = .missing,
    openGenericsPosition: Location.Position = .missing,
    genericsCommaPositions: Ast.Array(Location.Position),
    closeGenericsPosition: Location.Position = .missing,
    argsAnnotationColonPositions: Ast.Array(Location.Position),
    argsCommaPositions: Ast.Array(Location.Position),
    varargAnnotationColonPosition: Location.Position = .missing,
    returnSpecifierPosition: Location.Position = .missing,
};

pub const ExprTable = extern struct {
    classIndex: Node.Kind = .expr_table,

    items: Ast.Array(Item),

    pub const Separator = enum(u32) {
        comma,
        semicolon,
        missing,
    };

    pub const Item = extern struct {
        /// '[', only if Kind == General
        indexerOpenPosition: Location.Position,
        /// ']', only if Kind == General
        indexerClosePosition: Location.Position,
        /// only if Kind != List
        equalsPosition: Location.Position,
        /// may be missing for last Item
        separator: Separator,
        /// may be missing for last Item
        separatorPosition: Location.Position,
    };
};

pub const ExprOp = extern struct {
    classIndex: Node.Kind = .expr_op,

    opPosition: Location.Position,
};

pub const ExprTypeAssertion = extern struct {
    classIndex: Node.Kind = .expr_type_assertion,

    opPosition: Location.Position,
};

pub const ExprIfElse = extern struct {
    classIndex: Node.Kind = .expr_if_else,

    thenPosition: Location.Position,
    elsePosition: Location.Position,
    isElseIf: bool,
};

pub const ExprInterpString = extern struct {
    classIndex: Node.Kind = .expr_interp_string,

    sourceStrings: Ast.Array(Ast.Array(u8)),
    stringPositions: Ast.Array(Location.Position),
};

pub const ExprExplicitTypeInstantiation = extern struct {
    classIndex: Node.Kind = .expr_explicit_type_instantiation,

    instantiation: TypeInstantiation,
};

pub const StatDo = extern struct {
    classIndex: Node.Kind = .stat_do,

    statsStartPosition: Location.Position,
    endPosition: Location.Position,
};

pub const StatRepeat = extern struct {
    classIndex: Node.Kind = .stat_repeat,

    untilPosition: Location.Position,
};

pub const StatReturn = extern struct {
    classIndex: Node.Kind = .stat_return,

    commaPositions: Ast.Array(Location.Position),
};

pub const StatLocal = extern struct {
    classIndex: Node.Kind = .stat_local,

    varsAnnotationColonPositions: Ast.Array(Location.Position),
    varsCommaPositions: Ast.Array(Location.Position),
    valuesCommaPositions: Ast.Array(Location.Position),
};

pub const StatFor = extern struct {
    classIndex: Node.Kind = .stat_for,

    annotationColonPosition: Location.Position,
    equalsPosition: Location.Position,
    endCommaPosition: Location.Position,
    stepCommaPosition: Location.Position,
};

pub const StatForIn = extern struct {
    classIndex: Node.Kind = .stat_for_in,

    varsAnnotationColonPositions: Ast.Array(Location.Position),
    varsCommaPositions: Ast.Array(Location.Position),
    valuesCommaPositions: Ast.Array(Location.Position),
};

pub const StatAssign = extern struct {
    classIndex: Node.Kind = .stat_assign,

    varsCommaPositions: Ast.Array(Location.Position),
    equalsPosition: Location.Position,
    valuesCommaPositions: Ast.Array(Location.Position),
};

pub const StatCompoundAssign = extern struct {
    classIndex: Node.Kind = .stat_compound_assign,

    opPosition: Location.Position,
};

pub const StatFunction = extern struct {
    classIndex: Node.Kind = .stat_function,

    attrLists: Ast.Array(*AttrList),
    functionKeywordPosition: Location.Position,
};

pub const StatLocalFunction = extern struct {
    classIndex: Node.Kind = .stat_local_function,

    attrLists: Ast.Array(*AttrList),
    localKeywordPosition: Location.Position,
    functionKeywordPosition: Location.Position,
};

pub const GenericType = extern struct {
    classIndex: Node.Kind = .generic_type,

    defaultEqualsPosition: Location.Position,
};

pub const GenericTypePack = extern struct {
    classIndex: Node.Kind = .generic_type_pack,

    ellipsisPosition: Location.Position,
    defaultEqualsPosition: Location.Position,
};

pub const StatTypeAlias = extern struct {
    classIndex: Node.Kind = .stat_type_alias,

    typeKeywordPosition: Location.Position,
    genericsOpenPosition: Location.Position,
    genericsCommaPositions: Ast.Array(Location.Position),
    genericsClosePosition: Location.Position,
    equalsPosition: Location.Position,
};

pub const StatTypeFunction = extern struct {
    classIndex: Node.Kind = .stat_type_function,

    typeKeywordPosition: Location.Position,
    functionKeywordPosition: Location.Position,
};

pub const TypeReference = extern struct {
    classIndex: Node.Kind = .type_reference,

    prefixPointPosition: Location.Position,
    openParametersPosition: Location.Position,
    parametersCommaPositions: Ast.Array(Location.Position),
    closeParametersPosition: Location.Position,
};

pub const TypeTable = extern struct {
    classIndex: Node.Kind = .type_table,

    items: Ast.Array(Item),
    isArray: bool,

    pub const Item = extern struct {
        kind: Kind,
        indexerOpenPosition: Location.Position, // '[', only if Kind != Property
        indexerClosePosition: Location.Position, // ']' only if Kind != Property
        colonPosition: Location.Position,
        separator: ExprTable.Separator, // may be missing for last Item
        separatorPosition: Location.Position,

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
    classIndex: Node.Kind = .type_function,

    openGenericsPosition: Location.Position,
    genericsCommaPositions: Ast.Array(Location.Position),
    closeGenericsPosition: Location.Position,
    openArgsPosition: Location.Position,
    argumentNameColonPositions: Ast.Array(Location.Position),
    argumentsCommaPositions: Ast.Array(Location.Position),
    closeArgsPosition: Location.Position,
    returnArrowPosition: Location.Position,
};

pub const TypeTypeof = extern struct {
    classIndex: Node.Kind = .type_typeof,

    openPosition: Location.Position,
    closePosition: Location.Position,
};

pub const TypeUnion = extern struct {
    classIndex: Node.Kind = .type_union,

    leadingPosition: Location.Position,
    separatorPositions: Ast.Array(Location.Position),
};

pub const TypeIntersection = extern struct {
    classIndex: Node.Kind = .type_intersection,

    leadingPosition: Location.Position,
    separatorPositions: Ast.Array(Location.Position),
};

pub const TypeSingletonString = extern struct {
    classIndex: Node.Kind = .type_singleton_string,

    sourceString: Ast.Array(u8),
    quoteStyle: ExprConstantString.QuoteStyle,
    blockDepth: u32,
};

pub const TypeGroup = extern struct {
    classIndex: Node.Kind = .type_group,

    closePosition: Location.Position,
};

pub const TypePackExplicit = extern struct {
    classIndex: Node.Kind = .type_pack_explicit,

    openParenthesesPosition: Location.Position,
    closeParenthesesPosition: Location.Position,
    commaPositions: Ast.Array(Location.Position),
};

pub const TypePackGeneric = extern struct {
    classIndex: Node.Kind = .type_pack_generic,

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

test "CstValuesCheck" {
    if (@import("builtin").cpu.arch.isWasm() or @import("builtin").os.tag == .windows)
        return error.SkipZigTest;
    const CstValues = struct {
        pub extern "c" const CstAttrIndex: u8;
        pub extern "c" const CstParametrizedAttrIndex: u8;
        pub extern "c" const CstExprGroupIndex: u8;
        pub extern "c" const CstExprConstantNumberIndex: u8;
        pub extern "c" const CstExprConstantIntegerIndex: u8;
        pub extern "c" const CstExprConstantStringIndex: u8;
        pub extern "c" const CstExprCallIndex: u8;
        pub extern "c" const CstExprIndexExprIndex: u8;
        pub extern "c" const CstExprFunctionIndex: u8;
        pub extern "c" const CstExprTableIndex: u8;
        pub extern "c" const CstExprOpIndex: u8;
        pub extern "c" const CstExprTypeAssertionIndex: u8;
        pub extern "c" const CstExprIfElseIndex: u8;
        pub extern "c" const CstExprInterpStringIndex: u8;
        pub extern "c" const CstExprExplicitTypeInstantiationIndex: u8;
        pub extern "c" const CstStatDoIndex: u8;
        pub extern "c" const CstStatRepeatIndex: u8;
        pub extern "c" const CstStatReturnIndex: u8;
        pub extern "c" const CstStatLocalIndex: u8;
        pub extern "c" const CstStatForIndex: u8;
        pub extern "c" const CstStatForInIndex: u8;
        pub extern "c" const CstStatAssignIndex: u8;
        pub extern "c" const CstStatCompoundAssignIndex: u8;
        pub extern "c" const CstStatFunctionIndex: u8;
        pub extern "c" const CstStatLocalFunctionIndex: u8;
        pub extern "c" const CstGenericTypeIndex: u8;
        pub extern "c" const CstGenericTypePackIndex: u8;
        pub extern "c" const CstStatTypeAliasIndex: u8;
        pub extern "c" const CstStatTypeFunctionIndex: u8;
        pub extern "c" const CstTypeReferenceIndex: u8;
        pub extern "c" const CstTypeTableIndex: u8;
        pub extern "c" const CstTypeTableItemKindIndexer: u8;
        pub extern "c" const CstTypeTableItemKindProperty: u8;
        pub extern "c" const CstTypeTableItemKindStringProperty: u8;
        pub extern "c" const CstTypeFunctionIndex: u8;
        pub extern "c" const CstTypeTypeofIndex: u8;
        pub extern "c" const CstTypeUnionIndex: u8;
        pub extern "c" const CstTypeIntersectionIndex: u8;
        pub extern "c" const CstTypeSingletonStringIndex: u8;
        pub extern "c" const CstTypeGroupIndex: u8;
        pub extern "c" const CstTypePackExplicitIndex: u8;
        pub extern "c" const CstTypePackGenericIndex: u8;

        pub extern "c" const CstExprGroupSize: usize;
        pub extern "c" const CstExprConstantNumberSize: usize;
        pub extern "c" const CstExprConstantIntegerSize: usize;
        pub extern "c" const CstExprConstantStringSize: usize;
        pub extern "c" const CstExprCallSize: usize;
        pub extern "c" const CstExprIndexExprSize: usize;
        pub extern "c" const CstExprFunctionSize: usize;
        pub extern "c" const CstExprTableSize: usize;
        pub extern "c" const CstExprOpSize: usize;
        pub extern "c" const CstExprTypeAssertionSize: usize;
        pub extern "c" const CstExprIfElseSize: usize;
        pub extern "c" const CstExprInterpStringSize: usize;
        pub extern "c" const CstExprExplicitTypeInstantiationSize: usize;
        pub extern "c" const CstStatDoSize: usize;
        pub extern "c" const CstStatRepeatSize: usize;
        pub extern "c" const CstStatReturnSize: usize;
        pub extern "c" const CstStatLocalSize: usize;
        pub extern "c" const CstStatForSize: usize;
        pub extern "c" const CstStatForInSize: usize;
        pub extern "c" const CstStatAssignSize: usize;
        pub extern "c" const CstStatCompoundAssignSize: usize;
        pub extern "c" const CstStatFunctionSize: usize;
        pub extern "c" const CstStatLocalFunctionSize: usize;
        pub extern "c" const CstGenericTypeSize: usize;
        pub extern "c" const CstGenericTypePackSize: usize;
        pub extern "c" const CstStatTypeAliasSize: usize;
        pub extern "c" const CstStatTypeFunctionSize: usize;
        pub extern "c" const CstTypeReferenceSize: usize;
        pub extern "c" const CstTypeTableSize: usize;
        pub extern "c" const CstTypeFunctionSize: usize;
        pub extern "c" const CstTypeTypeofSize: usize;
        pub extern "c" const CstTypeUnionSize: usize;
        pub extern "c" const CstTypeIntersectionSize: usize;
        pub extern "c" const CstTypeSingletonStringSize: usize;
        pub extern "c" const CstTypeGroupSize: usize;
        pub extern "c" const CstTypePackExplicitSize: usize;
        pub extern "c" const CstTypePackGenericSize: usize;
    };

    try std.testing.expect(CstValues.CstTypeTableItemKindIndexer == @intFromEnum(TypeTable.Item.Kind.indexer));
    try std.testing.expect(CstValues.CstTypeTableItemKindProperty == @intFromEnum(TypeTable.Item.Kind.property));
    try std.testing.expect(CstValues.CstTypeTableItemKindStringProperty == @intFromEnum(TypeTable.Item.Kind.string_property));

    @setEvalBranchQuota(2000);
    inline for (@typeInfo(CstValues).@"struct".decls) |decl| {
        if (comptime std.mem.endsWith(u8, decl.name, "Index")) {
            const name = decl.name[3 .. decl.name.len - 5];

            const cst_node_type = @field(Cst, name);
            const info = @typeInfo(cst_node_type).@"struct";

            comptime var field: ?std.builtin.Type.StructField = null;
            inline for (info.fields) |f| {
                if (comptime std.mem.eql(u8, f.name, "classIndex")) {
                    field = f;
                    break;
                }
            }
            if (field == null)
                @compileError("classIndex field not found");
            const default_value_ptr = field.?.default_value_ptr orelse @compileError("classIndex field does not have a default value");
            const enum_value = @as(*const Cst.Node.Kind, @ptrCast(@alignCast(default_value_ptr))).*;

            std.testing.expectEqual(@intFromEnum(enum_value), @field(CstValues, decl.name)) catch |err| {
                std.debug.print("error for {s}\n", .{name});
                return err;
            };
        } else if (comptime std.mem.endsWith(u8, decl.name, "Size")) {
            const name = decl.name[3 .. decl.name.len - 4];

            const cst_node_type = @field(Cst, name);

            std.testing.expectEqual(@sizeOf(cst_node_type), @field(CstValues, decl.name)) catch |err| {
                std.debug.print("error for {s}\n", .{name});
                return err;
            };
        }
    }
}

// sources:
// https://github.com/luau-lang/luau/blob/40d4815888f63362a6cb79b3e74c4aafa0b2cbf4/Ast/include/Luau/Cst.h
// https://github.com/luau-lang/luau/blob/40d4815888f63362a6cb79b3e74c4aafa0b2cbf4/Ast/src/Cst.cpp
