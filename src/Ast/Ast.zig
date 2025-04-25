const std = @import("std");

const Location = @import("Location.zig").Location;

const cpp_std = @import("../cpp_std.zig");

const Ast = @This();

pub const Name = extern struct {
    value: [*:0]const u8,
};

pub const Local = extern struct {
    name: Name,
    location: Location,
    shadow: ?*Local,
    functionDepth: usize,
    loopDepth: usize,
    annotation: ?*Type,
};

pub fn Array(comptime T: type) type {
    return extern struct {
        data: ?[*]T = null,
        size: usize = 0,

        const This = @This();

        pub fn slice(self: This) []T {
            return if (self.data) |d| d[0..self.size] else &.{};
        }
    };
}

pub const TypeList = extern struct {
    types: Array(*Type),
    /// Null indicates no tail, not an untyped tail.
    tailType: ?*TypePack = null,
};

pub const Node = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    pub const Kind = enum(u32) {
        unknown,
        attr,
        generic_type,
        generic_type_pack,
        expr_group,
        expr_constant_nil,
        expr_constant_bool,
        expr_constant_number,
        expr_constant_string,
        expr_local,
        expr_global,
        expr_varargs,
        expr_call,
        expr_index_name,
        expr_index_expr,
        expr_function,
        expr_table,
        expr_unary,
        expr_binary,
        expr_type_assertion,
        expr_if_else,
        expr_interp_string,
        stat_block,
        stat_if,
        stat_while,
        stat_repeat,
        stat_break,
        stat_continue,
        stat_return,
        stat_expr,
        stat_local,
        stat_for,
        stat_for_in,
        stat_assign,
        stat_compound_assign,
        stat_function,
        stat_local_function,
        stat_type_alias,
        stat_type_function,
        stat_declare_global,
        stat_declare_function,
        stat_declare_class,
        type_reference,
        type_table,
        type_function,
        type_typeof,
        type_optional,
        type_union,
        type_intersection,
        expr_error,
        stat_error,
        type_error,
        type_singleton_bool,
        type_singleton_string,
        type_group,
        type_pack_explicit,
        type_pack_variadic,
        type_pack_generic,

        pub fn Type(self: Kind) type {
            return switch (self) {
                .unknown => Node,
                .attr => Attr,
                .generic_type => GenericType,
                .generic_type_pack => GenericTypePack,
                .expr_group => ExprGroup,
                .expr_constant_nil => ExprConstantNil,
                .expr_constant_bool => ExprConstantBool,
                .expr_constant_number => ExprConstantNumber,
                .expr_constant_string => ExprConstantString,
                .expr_local => ExprLocal,
                .expr_global => ExprGlobal,
                .expr_varargs => ExprVarargs,
                .expr_call => ExprCall,
                .expr_index_name => ExprIndexName,
                .expr_index_expr => ExprIndexExpr,
                .expr_function => ExprFunction,
                .expr_table => ExprTable,
                .expr_unary => ExprUnary,
                .expr_binary => ExprBinary,
                .expr_type_assertion => ExprTypeAssertion,
                .expr_if_else => ExprIfElse,
                .expr_interp_string => ExprInterpString,
                .stat_block => StatBlock,
                .stat_if => StatIf,
                .stat_while => StatWhile,
                .stat_repeat => StatRepeat,
                .stat_break => StatBreak,
                .stat_continue => StatContinue,
                .stat_return => StatReturn,
                .stat_expr => StatExpr,
                .stat_local => StatLocal,
                .stat_for => StatFor,
                .stat_for_in => StatForIn,
                .stat_assign => StatAssign,
                .stat_compound_assign => StatCompoundAssign,
                .stat_function => StatFunction,
                .stat_local_function => StatLocalFunction,
                .stat_type_alias => StatTypeAlias,
                .stat_type_function => StatTypeFunction,
                .stat_declare_global => StatDeclareGlobal,
                .stat_declare_function => StatDeclareFunction,
                .stat_declare_class => StatDeclareClass,
                .type_reference => TypeReference,
                .type_table => TypeTable,
                .type_function => TypeFunction,
                .type_typeof => TypeTypeof,
                .type_optional => TypeOptional,
                .type_union => TypeUnion,
                .type_intersection => TypeIntersection,
                .expr_error => ExprError,
                .stat_error => StatError,
                .type_error => TypeError,
                .type_singleton_bool => TypeSingletonBool,
                .type_singleton_string => TypeSingletonString,
                .type_group => TypeGroup,
                .type_pack_explicit => TypePackExplicit,
                .type_pack_variadic => TypePackVariadic,
                .type_pack_generic => TypePackGeneric,
            };
        }

        pub fn Parent(self: Kind) type {
            return switch (self) {
                .unknown => Node,
                .attr,
                .generic_type,
                .generic_type_pack,
                => Node,
                .expr_group,
                .expr_constant_nil,
                .expr_constant_bool,
                .expr_constant_number,
                .expr_constant_string,
                .expr_local,
                .expr_global,
                .expr_varargs,
                .expr_call,
                .expr_index_name,
                .expr_index_expr,
                .expr_function,
                .expr_table,
                .expr_unary,
                .expr_binary,
                .expr_type_assertion,
                .expr_if_else,
                .expr_interp_string,
                .expr_error,
                => Expr,
                .stat_block,
                .stat_if,
                .stat_while,
                .stat_repeat,
                .stat_break,
                .stat_continue,
                .stat_return,
                .stat_expr,
                .stat_local,
                .stat_for,
                .stat_for_in,
                .stat_assign,
                .stat_compound_assign,
                .stat_function,
                .stat_local_function,
                .stat_type_alias,
                .stat_type_function,
                .stat_declare_global,
                .stat_declare_function,
                .stat_declare_class,
                .stat_error,
                => Stat,
                .type_reference,
                .type_table,
                .type_function,
                .type_typeof,
                .type_optional,
                .type_union,
                .type_intersection,
                .type_error,
                .type_singleton_bool,
                .type_singleton_string,
                .type_group,
                => Ast.Type,
                .type_pack_explicit,
                .type_pack_variadic,
                .type_pack_generic,
                => Ast.TypePack,
            };
        }
    };

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;
};

pub fn IsFn(base: anytype, comptime to: Node.Kind) bool {
    return base.classIndex == to;
}

pub fn AsCastFn(base: anytype, comptime to: Node.Kind) ?*to.Type() {
    return if (base.classIndex == to) @ptrCast(@alignCast(base)) else null;
}

pub fn AsStatCastFn(base: anytype) *Stat {
    return @ptrCast(@alignCast(base));
}

pub fn AsExprCastFn(base: anytype) *Expr {
    return @ptrCast(@alignCast(base));
}

pub fn AsTypeCastFn(base: anytype) *Type {
    return @ptrCast(@alignCast(base));
}

pub const Attr = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    type: Attr.Type,

    pub const Type = enum(c_int) {
        Checked = 0,
        Native = 1,
        Deprecated = 2,
    };

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const Expr = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        Visitor.selfVisit(visitor, self);
    }

    pub fn isLValue(expr: *const Expr) bool {
        return switch (expr.classIndex) {
            .expr_local, .expr_global, .expr_index_name, .expr_index_expr => true,
            else => false,
        };
    }

    pub fn getIdentifier(node: *Expr) ?Name {
        if (node.as(.expr_global)) |expr|
            return expr.name;

        if (node.as(.expr_local)) |expr|
            return expr.local.name;

        return null;
    }
};

pub const Stat = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    hasSemicolon: bool,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        Visitor.selfVisit(visitor, self);
    }
};

pub const GenericType = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    name: Name,
    defaultValue: ?*Type = null,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            if (self.defaultValue) |node|
                node.visit(visitor);
        }
    }
};

pub const GenericTypePack = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    name: Name,
    defaultValue: ?*TypePack = null,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            if (self.defaultValue) |node|
                node.visit(visitor);
        }
    }
};

pub const ExprGroup = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    expr: *Expr,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.expr.visit(visitor);
        }
    }
};

pub const ExprConstantNil = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const ExprConstantBool = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    value: bool,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const ConstantNumberParseResult = enum(c_int) {
    Ok = 0,
    Imprecise = 1,
    Malformed = 2,
    BinOverflow = 3,
    HexOverflow = 4,
};

pub const ExprConstantNumber = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    value: f64,
    parseResult: ConstantNumberParseResult,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const ExprConstantString = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    value: Array(u8),
    quoteStyle: QuoteStyle,

    pub const QuoteStyle = enum(c_int) {
        QuotedSimple = 0,
        QuotedRaw = 1,
        Unquoted = 2,
    };

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const ExprLocal = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    local: ?*Local,
    upvalue: bool,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const ExprGlobal = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    name: Name,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const ExprVarargs = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const ExprCall = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    func: *Expr,
    args: Array(*Expr),
    self: bool,
    argLocation: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.func.visit(visitor);

            for (self.args.slice()) |arg|
                arg.visit(visitor);
        }
    }
};

pub const ExprIndexName = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    expr: *Expr,
    index: Name,
    indexLocation: Location,
    opPosition: Location.Position,
    op: u8 = '.',

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.expr.visit(visitor);
        }
    }
};

pub const ExprIndexExpr = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    expr: *Expr,
    index: *Expr,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.expr.visit(visitor);
            self.index.visit(visitor);
        }
    }
};

pub const ExprFunction = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    attributes: Array(*Attr),
    generics: Array(*GenericType),
    genericPacks: Array(*GenericTypePack),
    self: *Local,
    args: Array(*Local),
    returnAnnotation: cpp_std.Optional(TypeList),
    vararg: bool = false,
    varargLocation: Location,
    varargAnnotation: ?*TypePack,
    body: *StatBlock,
    functionDepth: usize,
    debugname: Name,
    argLocation: cpp_std.Optional(Location),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.args.slice()) |arg|
                if (arg.annotation) |node|
                    node.visit(visitor);

            if (self.varargAnnotation) |node|
                node.visit(visitor);

            if (self.returnAnnotation.has)
                Visitor.visitTypeList(visitor, self.returnAnnotation.value);

            self.body.visit(visitor);
        }
    }

    pub fn hasNativeAttribute(self: *ExprFunction) bool {
        for (self.attributes.slice()) |attr| {
            if (attr.type == .Native)
                return true;
        }
        return false;
    }

    pub fn hasAttribute(self: *ExprFunction, attrType: Attr.Type) bool {
        for (self.attributes.slice()) |attr| {
            if (attr.type == attrType)
                return true;
        }
        return false;
    }
};

pub const ExprTable = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    items: Array(Item),

    pub const Item = extern struct {
        pub const Kind = enum(c_int) {
            List, // foo, in which case key is a nullptr
            Record, // foo=bar, in which case key is a AstExprConstantString
            General, // [foo]=bar
        };

        kind: Kind,
        /// can be nullptr!
        key: ?*Expr,
        value: *Expr,

        pub const as = AsCastFn;
        pub const asExpr = AsExprCastFn;
        pub const asStat = AsStatCastFn;
    };

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.items.slice()) |item| {
                if (item.key) |key|
                    key.visit(visitor);

                item.value.visit(visitor);
            }
        }
    }
};

pub const ExprUnary = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    op: Op,
    expr: *Expr,

    pub const Op = enum(c_int) {
        Not = 0,
        Minus = 1,
        Len = 2,

        pub fn toString(self: Op) []const u8 {
            return switch (self) {
                .Not => "not",
                .Minus => "-",
                .Len => "#",
            };
        }
    };

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.expr.visit(visitor);
        }
    }
};

pub const ExprBinary = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    op: Op,
    left: *Expr,
    right: *Expr,

    pub const Op = enum(c_int) {
        Add = 0,
        Sub = 1,
        Mul = 2,
        Div = 3,
        FloorDiv = 4,
        Mod = 5,
        Pow = 6,
        Concat = 7,
        CompareNe = 8,
        CompareEq = 9,
        CompareLt = 10,
        CompareLe = 11,
        CompareGt = 12,
        CompareGe = 13,
        And = 14,
        Or = 15,
        __Count = 16,

        pub fn toString(self: Op) []const u8 {
            return switch (self) {
                .Add => "+",
                .Sub => "-",
                .Mul => "*",
                .Div => "/",
                .FloorDiv => "//",
                .Mod => "%",
                .Pow => "^",
                .Concat => "..",
                .CompareNe => "~=",
                .CompareEq => "==",
                .CompareLt => "<",
                .CompareLe => "<=",
                .CompareGt => ">",
                .CompareGe => ">=",
                .And => "and",
                .Or => "or",
            };
        }
    };

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.left.visit(visitor);
            self.right.visit(visitor);
        }
    }
};

pub const ExprTypeAssertion = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    expr: *Expr,
    annotation: *Type,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.expr.visit(visitor);
            self.annotation.visit(visitor);
        }
    }
};

pub const ExprIfElse = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    condition: *Expr,
    hasThen: bool,
    trueExpr: *Expr,
    hasElse: bool,
    falseExpr: *Expr,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.condition.visit(visitor);
            self.trueExpr.visit(visitor);
            self.falseExpr.visit(visitor);
        }
    }
};

pub const ExprInterpString = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    /// An interpolated string such as `foo{bar}baz` is represented as
    /// an array of strings for "foo" and "bar", and an array of expressions for "baz".
    /// `strings` will always have one more element than `expressions`.
    strings: Array(Array(u8)),
    expressions: Array(*Expr),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.expressions.slice()) |expr|
                expr.visit(visitor);
        }
    }
};

pub const StatBlock = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    body: Array(*Stat),
    /// Indicates whether or not this block has been terminated in a
    /// syntactically valid way.
    ///
    /// This is usually but not always done with the 'end' keyword.  StatIf
    /// and StatRepeat are the two main exceptions to this.
    ///
    /// The 'then' clause of an if statement can properly be closed by the
    /// keywords 'else' or 'elseif'.  A 'repeat' loop's body is closed with the
    /// 'until' keyword.
    hasEnd: bool = false,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *StatBlock, visitor: anytype) void {
        if (Visitor.visit(visitor, self))
            for (self.body.slice()) |stat|
                stat.visit(visitor);
    }
};

pub const StatIf = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    condition: *Expr,
    thenbody: *StatBlock,
    elsebody: ?*Stat,
    thenLocation: cpp_std.Optional(Location),
    /// Active for 'elseif' as well
    elseLocation: cpp_std.Optional(Location),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.condition.visit(visitor);
            self.thenbody.visit(visitor);

            if (self.elsebody) |elsebody|
                elsebody.visit(visitor);
        }
    }
};

pub const StatWhile = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    condition: *Expr,
    body: *StatBlock,
    hasDo: bool = false,
    doLocation: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.condition.visit(visitor);
            self.body.visit(visitor);
        }
    }
};

pub const StatRepeat = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    condition: *Expr,
    body: *StatBlock,
    DEPRECATED_hasUntil: bool = false,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.body.visit(visitor);
            self.condition.visit(visitor);
        }
    }
};

pub const StatBreak = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const StatContinue = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const StatReturn = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    list: Array(*Expr),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.list.slice()) |expr|
                expr.visit(visitor);
        }
    }
};

pub const StatExpr = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    expr: *Expr,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self))
            self.expr.visit(visitor);
    }
};

pub const StatLocal = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    vars: Array(*Local),
    values: Array(*Expr),
    equalsSignLocation: cpp_std.Optional(Location),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.vars.slice()) |@"var"|
                if (@"var".annotation) |node|
                    node.visit(visitor);

            for (self.values.slice()) |expr|
                expr.visit(visitor);
        }
    }
};

pub const StatFor = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    variable: *Local,
    from: *Expr,
    to: *Expr,
    step: ?*Expr,
    body: *StatBlock,
    hasDo: bool = false,
    doLocation: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            if (self.variable.annotation) |node|
                node.visit(visitor);

            self.from.visit(visitor);
            self.to.visit(visitor);

            if (self.step) |step|
                step.visit(visitor);

            self.body.visit(visitor);
        }
    }
};

pub const StatForIn = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    vars: Array(*Local),
    values: Array(*Expr),
    body: *StatBlock,
    hasIn: bool = false,
    inLocation: Location,
    hasDo: bool = false,
    doLocation: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.vars.slice()) |@"var"|
                if (@"var".annotation) |node|
                    node.visit(visitor);

            for (self.values.slice()) |expr|
                expr.visit(visitor);

            self.body.visit(visitor);
        }
    }
};

pub const StatAssign = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    vars: Array(*Expr),
    values: Array(*Expr),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.vars.slice()) |lvalue|
                lvalue.visit(visitor);

            for (self.values.slice()) |expr|
                expr.visit(visitor);
        }
    }
};

pub const StatCompoundAssign = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    op: ExprBinary.Op,
    variable: *Expr,
    value: *Expr,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.variable.visit(visitor);
            self.value.visit(visitor);
        }
    }
};

pub const StatFunction = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    name: *Expr,
    func: *ExprFunction,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.name.visit(visitor);
            self.func.visit(visitor);
        }
    }
};

pub const StatLocalFunction = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    name: *Local,
    func: *ExprFunction,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.func.visit(visitor);
        }
    }
};

pub const StatTypeAlias = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    name: Name,
    nameLocation: Location,
    generics: Array(*GenericType),
    genericPacks: Array(*GenericTypePack),
    type: *Type,
    exported: bool,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.generics.slice()) |el|
                el.visit(visitor);

            for (self.genericPacks.slice()) |el|
                el.visit(visitor);

            self.type.visit(visitor);
        }
    }
};

pub const StatTypeFunction = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    name: Name,
    nameLocation: Location,
    body: *ExprFunction = undefined,
    exported: bool = false,
    hasErrors: bool = false,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.body.visit(visitor);
        }
    }
};

pub const StatDeclareGlobal = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    name: Name,
    nameLocation: Location,
    type: *Type,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.type.visit(visitor);
        }
    }
};

pub const ArgumentName = extern struct {
    name: Name,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;
};

pub const StatDeclareFunction = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    attributes: Array(*Attr),
    name: Name,
    nameLocation: Location,
    generics: Array(*GenericType),
    genericPacks: Array(*GenericTypePack),
    params: TypeList,
    paramNames: Array(ArgumentName),
    vararg: bool = false,
    varargLocation: Location,
    retTypes: TypeList,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            Visitor.visitTypeList(visitor, self.params);
            Visitor.visitTypeList(visitor, self.retTypes);
        }
    }

    pub fn isCheckedFunction(self: *StatDeclareFunction) bool {
        for (self.attributes.slice()) |attr| {
            if (attr.type == .Checked)
                return true;
        }
        return false;
    }

    pub fn hasAttribute(self: *StatDeclareFunction, attrType: Attr.Type) bool {
        for (self.attributes.slice()) |attr| {
            if (attr.type == attrType)
                return true;
        }
        return false;
    }
};

pub const DeclaredClassProp = extern struct {
    name: Name,
    nameLocation: Location,
    ty: *Type = undefined,
    isMethod: bool = false,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;
};

pub const TableAccess = enum(c_int) {
    Read = 1,
    Write = 2,
    ReadWrite = 3,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;
};

pub const TableIndexer = extern struct {
    indexType: *Type,
    resultType: *Type,
    location: Location,
    access: TableAccess = .ReadWrite,
    accessLocation: cpp_std.Optional(Location),
};

pub const StatDeclareClass = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    hasSemicolon: bool = false,

    name: Name,
    superName: cpp_std.Optional(Name),
    props: Array(DeclaredClassProp),
    indexer: *TableIndexer,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.props.slice()) |prop|
                prop.ty.visit(visitor);
        }
    }
};

pub const Type = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        Visitor.selfVisit(visitor, self);
    }
};

/// Don't have Luau::Variant available, it's a bit of an overhead, but a plain struct is nice to use
pub const TypeOrPack = extern struct {
    type: ?*Type = null,
    typePack: ?*TypePack = null,
};

pub const TypeReference = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    hasParameterList: bool,
    prefix: cpp_std.Optional(Name),
    prefixLocation: cpp_std.Optional(Location),
    name: Name,
    nameLocation: Location,
    parameters: Array(TypeOrPack),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.parameters.slice()) |param|
                if (param.type) |node| {
                    node.visit(visitor);
                } else {
                    param.typePack.?.visit(visitor);
                };
        }
    }
};

pub const TableProp = extern struct {
    name: Name,
    location: Location,
    type: *Type,
    access: TableAccess = .ReadWrite,
    accessLocation: cpp_std.Optional(Location),
};

pub const TypeTable = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    props: Array(TableProp),
    indexer: ?*TableIndexer,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.props.slice()) |node|
                node.type.visit(visitor);

            if (self.indexer) |indexer| {
                indexer.indexType.visit(visitor);
                indexer.resultType.visit(visitor);
            }
        }
    }
};

pub const TypeFunction = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    attributes: Array(*Attr),
    generics: Array(*GenericType),
    genericPacks: Array(*GenericTypePack),
    argTypes: TypeList,
    argNames: Array(cpp_std.Optional(ArgumentName)),
    returnTypes: TypeList,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            Visitor.visitTypeList(visitor, self.argTypes);
            Visitor.visitTypeList(visitor, self.returnTypes);
        }
    }

    pub fn isCheckedFunction(self: *TypeFunction) bool {
        for (self.attributes.slice()) |attr| {
            if (attr.type == .Checked)
                return true;
        }
        return false;
    }

    pub fn hasAttribute(self: *TypeFunction, attrType: Attr.Type) bool {
        for (self.attributes.slice()) |attr| {
            if (attr.type == attrType)
                return true;
        }
        return false;
    }
};

pub const TypeTypeof = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    expr: *Expr,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.expr.visit(visitor);
        }
    }
};

pub const TypeOptional = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const TypeUnion = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    types: Array(*Type),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.types.slice()) |node|
                node.visit(visitor);
        }
    }
};

pub const TypeIntersection = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    types: Array(*Type),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.types.slice()) |node|
                node.visit(visitor);
        }
    }
};

pub const ExprError = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    expressions: Array(*Expr),
    messageIndex: c_uint,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.expressions.slice()) |expression|
                expression.visit(visitor);
        }
    }
};

pub const StatError = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,
    MAYBE_hasSemicolon: bool = false,

    expressions: Array(*Expr),
    statements: Array(*Stat),
    messageIndex: c_uint,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.expressions.slice()) |expression|
                expression.visit(visitor);

            for (self.statements.slice()) |statement|
                statement.visit(visitor);
        }
    }
};

pub const TypeError = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    types: Array(*Type),
    isMissing: bool,
    messageIndex: c_uint,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.types.slice()) |node|
                node.visit(visitor);
        }
    }
};

pub const TypeSingletonBool = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    value: bool,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const TypeSingletonString = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    value: Array(u8),

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const TypeGroup = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    type: *Type,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            self.type.visit(visitor);
        }
    }
};

pub const TypePack = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        Visitor.selfVisit(visitor, self);
    }
};

pub const TypePackExplicit = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    typeList: TypeList,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self)) {
            for (self.typeList.types.slice()) |node|
                node.visit(visitor);

            if (self.typeList.tailType) |node|
                node.visit(visitor);
        }
    }
};

pub const TypePackVariadic = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    variadicType: *Type,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        if (Visitor.visit(visitor, self))
            self.variadicType.visit(visitor);
    }
};

pub const TypePackGeneric = extern struct {
    vtable: *const anyopaque,

    classIndex: Node.Kind,
    location: Location,

    genericName: Name,

    pub const is = IsFn;
    pub const as = AsCastFn;
    pub const asExpr = AsExprCastFn;
    pub const asStat = AsStatCastFn;
    pub const asType = AsTypeCastFn;

    pub fn visit(self: *@This(), visitor: anytype) void {
        _ = Visitor.visit(visitor, self);
    }
};

pub const Visitor = struct {
    pub fn visitTypeList(self: anytype, this: TypeList) void {
        for (this.types.slice()) |node|
            node.visit(self);

        if (this.tailType) |node|
            node.visit(self);
    }

    fn getVisitorStruct(comptime self: type) type {
        return switch (@typeInfo(self)) {
            .pointer => |ptr| ptr.child,
            .@"struct" => |s| s,
            else => |t| @compileError("Visitor type unsupported: " ++ @typeName(t)),
        };
    }

    fn hasVistDecl(comptime self: type, comptime name: [:0]const u8) bool {
        return @hasDecl(getVisitorStruct(self), name);
    }

    fn callVisitorDecl(self: anytype, comptime name: [:0]const u8, this: anytype) bool {
        const visitor_type = @TypeOf(self);
        const visitor_struct = getVisitorStruct(visitor_type);
        const visitor_fn = @field(visitor_struct, name);
        return switch (@typeInfo(visitor_type)) {
            .type => visitor_fn(@ptrCast(@alignCast(this))),
            .pointer, .@"struct" => visitor_fn(self, @ptrCast(@alignCast(this))),
            else => unreachable,
        };
    }

    fn visitByName(self: anytype, comptime name: [:0]const u8, this: anytype) ?bool {
        const namespace = @typeName(Ast);
        const ast_name = name[namespace.len + 1 ..];
        const fn_name = "visit" ++ ast_name;

        if (comptime hasVistDecl(@TypeOf(self), fn_name))
            return callVisitorDecl(self, fn_name, this);
        return null;
    }

    fn getParent(comptime ast: type) type {
        const namespace = @typeName(Ast);
        const ast_name = @typeName(ast)[namespace.len + 1 ..];
        if (std.mem.eql(u8, ast_name, "Attr") or
            std.mem.eql(u8, ast_name, "GenericType") or
            std.mem.eql(u8, ast_name, "GenericTypePack") or
            std.mem.eql(u8, ast_name, "Expr") or
            std.mem.eql(u8, ast_name, "Stat"))
            return Ast.Node
        else if (std.mem.startsWith(u8, ast_name, "Expr"))
            return Ast.Expr
        else if (std.mem.startsWith(u8, ast_name, "Stat"))
            return Ast.Stat
        else if (std.mem.startsWith(u8, ast_name, "TypePack"))
            return Ast.TypePack
        else if (std.mem.startsWith(u8, ast_name, "Type"))
            return Ast.Type;
        @compileError("Invalid Ast type");
    }

    pub fn selfVisit(self: anytype, this: anytype) void {
        switch (this.classIndex) {
            inline else => |kind| {
                const kind_type = kind.Type();
                if (@hasDecl(kind_type, "visit"))
                    kind_type.visit(@ptrCast(@alignCast(this)), self);
            },
        }
    }

    pub fn visit(self: anytype, this: anytype) bool {
        const node_type = @typeInfo(@TypeOf(this));
        const ast_type = node_type.pointer.child;
        comptime if (node_type != .pointer)
            @compileError("Invalid Ast type");
        comptime if (!std.mem.startsWith(u8, @typeName(ast_type), @typeName(Ast)))
            @compileError("Invalid Ast type");

        const namespace = @typeName(Ast);
        if (ast_type == Ast.Node) {
            if (comptime hasVistDecl(@TypeOf(self), "visit"))
                return callVisitorDecl(self, "visit", this);
            return true;
        } else if (ast_type == Ast.Type or ast_type == Ast.TypePack) {
            const ast_name = @typeName(ast_type)[namespace.len + 1 ..];
            if (comptime hasVistDecl(@TypeOf(self), "visit" ++ ast_name))
                return callVisitorDecl(self, "visit" ++ ast_name, this);
            return false;
        } else {
            const ast_name = @typeName(ast_type)[namespace.len + 1 ..];
            const fn_name = "visit" ++ ast_name;

            if (comptime hasVistDecl(@TypeOf(self), fn_name))
                return callVisitorDecl(self, fn_name, this);

            const parent = comptime getParent(ast_type);
            return Visitor.visit(self, @as(*parent, @ptrCast(@alignCast(this))));
        }
    }
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
            \\local x = 1;
            \\local x = 2
            \\local x = 3
            \\
        ;

        var parse_result = Parser.parse(source, table, allocator);
        defer parse_result.deinit();

        const root = parse_result.root;

        try std.testing.expectEqual(Node.Kind.stat_block, root.classIndex);

        const stats = root.body.slice();
        try std.testing.expectEqual(3, stats.len);

        for (stats) |node| {
            switch (node.classIndex) {
                .stat_local => {
                    const local: *StatLocal = node.as(.stat_local).?;
                    try std.testing.expectEqualStrings("x", std.mem.span(local.vars.slice()[0].name.value));
                    std.debug.print("{}\n", .{(local.values.slice()[0].as(.expr_constant_number).?.value)});
                },
                else => {},
            }
        }
    }

    {
        const allocator = Allocator.init();
        defer allocator.deinit();

        const astNameTable = Lexer.AstNameTable.init(allocator);
        defer astNameTable.deinit();
        const source =
            \\@native
            \\function test()
            \\end
            \\
        ;

        const parseResult = Parser.parse(source, astNameTable, allocator);
        defer parseResult.deinit();

        const FunctionVisitor = struct {
            hasNativeFunction: bool = false,

            pub fn visitExprFunction(self: *@This(), node: *Ast.ExprFunction) bool {
                node.body.visit(self);

                if (!self.hasNativeFunction and node.hasNativeAttribute())
                    self.hasNativeFunction = true;

                return false;
            }
        };
        var visitor: FunctionVisitor = .{};

        parseResult.root.visit(&visitor);

        try std.testing.expect(visitor.hasNativeFunction);
    }
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Ast.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Ast.cpp
