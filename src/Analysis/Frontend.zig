const std = @import("std");

const Location = @import("../Ast/Location.zig").Location;

const GenericConfigResolver = @import("GenericConfigResolver.zig");

pub const LoadDefinitionResult = extern struct {
    success: bool,
};

pub const Options = extern struct {
    /// When true, we retain full type information about every term in the AST.
    /// Setting this to false cuts back on RAM and is a good idea for batch
    /// jobs where the type graph is not deeply inspected after typechecking
    /// is complete.
    retainFullTypeGraphs: bool = false,

    /// Run typechecking only in mode required for autocomplete (strict mode in
    /// order to get more precise type information)
    forAutocomplete: bool = false,

    runLintChecks: bool = false,

    /// When true, some internal complexity limits will be scaled down for modules that miss the limit set by moduleTimeLimitSec
    applyInternalLimitScaling: bool = false,
};

pub const CheckResultStatus = enum(u8) {
    None,
    Success,
    Error,
};

pub const CheckResultErrorKind = enum(u8) {
    Error,
    LintError,
    LintWarning,
};

const loadDefinitionFileErrorFn = fn (?*anyopaque, [*c]const u8, usize, Location) callconv(.c) void;
const CheckedModuleFn = fn (?*anyopaque, [*c]const u8, usize) callconv(.c) bool;
const CheckedModuleErrorFn = fn (?*anyopaque, [*c]const u8, usize, [*c]const u8, usize, Location) callconv(.c) void;
const CheckedResultFn = fn (?*anyopaque, u8, [*c]const u8, usize, [*c]const u8, usize, [*c]const u8, Location) callconv(.c) void;

extern "c" fn zig_luau_free(ptr: *anyopaque) void;

extern "c" fn zig_Luau_Analysis_Frontend_init(*anyopaque, *GenericConfigResolver.GenericConfigResolver, Options) *Frontend;
extern "c" fn zig_Luau_Analysis_Frontend_registerBuiltinGlobals(*Frontend) void;
extern "c" fn zig_Luau_Analysis_Frontend_freeze(*Frontend) void;
extern "c" fn zig_Luau_Analysis_Frontend_loadDefinitionFile(*Frontend, [*c]const u8, usize, [*c]const u8, bool, bool, ?*anyopaque, ?*const loadDefinitionFileErrorFn) bool;
extern "c" fn zig_Luau_Analysis_Frontend_queueModuleCheck(*Frontend, [*c]const u8, usize) void;
extern "c" fn zig_Luau_Analysis_Frontend_checkQueuedModules(*Frontend, ?*anyopaque, *const CheckedModuleFn, ?*const CheckedModuleErrorFn) bool;
extern "c" fn zig_Luau_Analysis_Frontend_getCheckResult(*Frontend, [*c]const u8, usize, bool, bool, ?*anyopaque, *const CheckedResultFn) u8;
extern "c" fn zig_Luau_Analysis_Frontend_dtor(*Frontend) void;

pub const Frontend = opaque {
    pub fn registerBuiltinGlobals(self: *Frontend) void {
        zig_Luau_Analysis_Frontend_registerBuiltinGlobals(self);
    }

    pub fn freeze(self: *Frontend) void {
        zig_Luau_Analysis_Frontend_freeze(self);
    }

    pub fn queueModuleCheck(self: *Frontend, path: []const u8) void {
        return zig_Luau_Analysis_Frontend_queueModuleCheck(self, path.ptr, path.len);
    }

    pub fn checkQueuedModules(
        self: *Frontend,
        context: anytype,
        comptime checkedModule: *const fn (@TypeOf(context), [:0]const u8) bool,
        comptime checkedModuleError: *const fn (@TypeOf(context), moduleName: [:0]const u8, errMsg: [:0]const u8, Location) void,
    ) bool {
        const T = @TypeOf(context);
        if (@typeInfo(T) != .pointer and T != void)
            @compileError("context must be a pointer type or void");
        if (T != void and @typeInfo(T).pointer.is_const)
            @compileError("context must be a mutable pointer type or void");
        return zig_Luau_Analysis_Frontend_checkQueuedModules(
            self,
            if (T == void) null else @ptrCast(@alignCast(context)),
            struct {
                fn inner(
                    ud: ?*anyopaque,
                    name: [*c]const u8,
                    len: usize,
                ) callconv(.c) bool {
                    return @call(.always_inline, checkedModule, .{
                        if (T == void) undefined else @as(T, @ptrCast(@alignCast(ud.?))),
                        name[0..len :0],
                    });
                }
            }.inner,
            struct {
                fn inner(
                    ud: ?*anyopaque,
                    name: [*c]const u8,
                    len: usize,
                    msg: [*c]const u8,
                    msgLen: usize,
                    loc: Location,
                ) callconv(.c) void {
                    @call(.always_inline, checkedModuleError, .{
                        if (T == void) undefined else @as(T, @ptrCast(@alignCast(ud.?))),
                        name[0..len :0],
                        msg[0..msgLen :0],
                        loc,
                    });
                }
            }.inner,
        );
    }

    pub fn getCheckResult(
        self: *Frontend,
        moduleName: []const u8,
        captureComments: bool,
        typeCheckForAutocomplete: bool,
        context: anytype,
        comptime checkFn: *const fn (@TypeOf(context), CheckResultErrorKind, [:0]const u8, [:0]const u8, [:0]const u8, Location) void,
    ) CheckResultStatus {
        const T = @TypeOf(context);
        if (@typeInfo(T) != .pointer and T != void)
            @compileError("context must be a pointer type or void");
        if (T != void and @typeInfo(T).pointer.is_const)
            @compileError("context must be a mutable pointer type or void");
        const result = zig_Luau_Analysis_Frontend_getCheckResult(
            self,
            moduleName.ptr,
            moduleName.len,
            captureComments,
            typeCheckForAutocomplete,
            if (T == void) null else @as(*anyopaque, @ptrCast(@alignCast(context))),
            struct {
                fn inner(
                    ud: ?*anyopaque,
                    kind: u8,
                    readableModuleName: [*c]const u8,
                    readableModuleNameLen: usize,
                    errorMessage: [*c]const u8,
                    errorMessageLen: usize,
                    contextName: [*c]const u8,
                    loc: Location,
                ) callconv(.c) void {
                    @call(.always_inline, checkFn, .{
                        if (T == void) undefined else @as(T, @ptrCast(@alignCast(ud.?))),
                        @as(CheckResultErrorKind, @enumFromInt(kind)),
                        readableModuleName[0..readableModuleNameLen :0],
                        errorMessage[0..errorMessageLen :0],
                        std.mem.span(contextName),
                        loc,
                    });
                }
            }.inner,
        );
        return @enumFromInt(result);
    }

    pub fn loadDefinitionFile(
        self: *Frontend,
        src: []const u8,
        packageName: [:0]const u8,
        captureComments: bool,
        typeCheckForAutocomplete: ?bool,
    ) bool {
        return zig_Luau_Analysis_Frontend_loadDefinitionFile(self, src.ptr, src.len, packageName, captureComments, typeCheckForAutocomplete orelse false, null, null);
    }

    const LoadDefintionResult = struct {
        message: []const u8,
        location: Location,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *LoadDefintionResult) void {
            self.allocator.free(self.message);
        }
    };

    pub fn loadDefinitionFileWithAlloc(
        self: *Frontend,
        allocator: std.mem.Allocator,
        src: []const u8,
        packageName: [:0]const u8,
        captureComments: bool,
        typeCheckForAutocomplete: ?bool,
    ) !?LoadDefintionResult {
        var result: struct { anyerror, LoadDefintionResult } = .{ error.None, .{
            .allocator = allocator,
            .message = undefined,
            .location = undefined,
        } };
        const success = zig_Luau_Analysis_Frontend_loadDefinitionFile(self, src.ptr, src.len, packageName, captureComments, typeCheckForAutocomplete orelse false, &result, struct {
            fn inner(
                ud: ?*anyopaque,
                msg: [*c]const u8,
                len: usize,
                loc: Location,
            ) callconv(.c) void {
                const res: *struct { anyerror, LoadDefintionResult } = @ptrCast(@alignCast(ud.?));
                res.@"1".location = loc;
                res.@"1".message = res.@"1".allocator.dupe(u8, msg[0..len]) catch |err| {
                    res.@"0" = err;
                    return;
                };
            }
        }.inner);
        if (success) {
            return null;
        }
        if (result.@"0" != error.None) {
            return result.@"0";
        }
        return result.@"1";
    }

    pub fn deinit(self: *Frontend) void {
        zig_Luau_Analysis_Frontend_dtor(self);
    }
};

pub fn init(fileResolver: anytype, configResolver: *GenericConfigResolver.GenericConfigResolver, opts: Options) *Frontend {
    return zig_Luau_Analysis_Frontend_init(@ptrCast(@alignCast(fileResolver)), configResolver, opts);
}

test Frontend {
    const FileResolver = @import("FileResolver.zig");

    {
        const FileImpl = struct {
            const Self = @This();
            pub fn readSource(_: *Self, _: []const u8) ?struct { []const u8, FileResolver.SourceCodeType } {
                return null;
            }

            pub fn resolveModule(_: *Self, _: []const u8, _: []const u8) ?[]const u8 {
                return null;
            }

            pub fn getHumanReadableModuleName(_: *Self, name: []const u8) []const u8 {
                return name;
            }

            pub fn freeString(_: *Self, _: []const u8) void {}
        };

        const FileImplResolver = FileResolver.FileResolver(FileImpl);

        var file_impl: FileImpl = .{};
        const file_resolver = FileImplResolver.init(&file_impl);
        defer file_resolver.deinit();
        const config_resolver = GenericConfigResolver.init(.Strict);
        defer config_resolver.deinit();

        const frontend = init(file_resolver, config_resolver, .{});
        defer frontend.deinit();

        frontend.registerBuiltinGlobals();

        var load_result = try frontend.loadDefinitionFileWithAlloc(
            std.testing.allocator,
            \\ - This is a test
        ,
            "@test",
            false,
            null,
        ) orelse @panic("no fail");
        defer load_result.deinit();
        try std.testing.expectEqualStrings("Expected identifier when parsing expression, got '-'", load_result.message);
        try std.testing.expectEqual(0, load_result.location.begin.line);
        try std.testing.expectEqual(1, load_result.location.begin.column);
        try std.testing.expectEqual(0, load_result.location.end.line);
        try std.testing.expectEqual(2, load_result.location.end.column);
    }
    {
        const StaticFileTree = std.StaticStringMap([]const u8).initComptime(.{
            .{
                "./main.luau",
                \\local module = require("./module.luau")
                ,
            },
            .{
                "./module.luau",
                \\print("module");
                \\return {};
                ,
            },
            .{
                "./sub/test.luau",
                \\local test = global.foo;
                \\local test2 = g.foo;
                \\
                ,
            },
        });

        const FileImpl = struct {
            const Self = @This();
            pub fn readSource(_: *Self, path: []const u8) ?struct { []const u8, FileResolver.SourceCodeType } {
                const source = StaticFileTree.get(path) orelse @panic("failed to find source");
                return .{ source, .Module };
            }

            pub fn resolveModule(_: *Self, _: []const u8, to: []const u8) ?[]const u8 {
                return to;
            }

            pub fn getHumanReadableModuleName(_: *Self, name: []const u8) []const u8 {
                return name;
            }

            pub fn freeString(_: *Self, _: []const u8) void {}
        };

        const FileImplResolver = FileResolver.FileResolver(FileImpl);

        var file_impl: FileImpl = .{};
        const file_resolver = FileImplResolver.init(&file_impl);
        defer file_resolver.deinit();
        const config_resolver = GenericConfigResolver.init(.Strict);
        defer config_resolver.deinit();

        const frontend = init(file_resolver, config_resolver, .{});
        defer frontend.deinit();

        frontend.registerBuiltinGlobals();

        try std.testing.expectEqual(null, try frontend.loadDefinitionFileWithAlloc(
            std.testing.allocator,
            \\declare global: {
            \\    foo: string,
            \\}
        ,
            "@main",
            false,
            null,
        ));

        frontend.queueModuleCheck("./main.luau");
        frontend.queueModuleCheck("./sub/test.luau");

        const success = frontend.checkQueuedModules(
            frontend,
            struct {
                fn checkedModule(f: *Frontend, name: [:0]const u8) bool {
                    switch (f.getCheckResult(name, false, false, @as(void, undefined), struct {
                        fn inner(_: void, kind: CheckResultErrorKind, readableModuleName: [:0]const u8, errorMessage: [:0]const u8, typeName: [:0]const u8, loc: Location) void {
                            if (!std.mem.eql(u8, readableModuleName, "./sub/test.luau"))
                                @panic("Expected no errors in main module");
                            std.testing.expectEqual(.Error, kind) catch @panic("failed");
                            std.testing.expectEqualStrings("Unknown global 'g'", errorMessage) catch @panic("failed");
                            std.testing.expectEqualStrings("TypeError", typeName) catch @panic("failed");
                            std.testing.expectEqual(1, loc.begin.line) catch @panic("failed");
                            std.testing.expectEqual(14, loc.begin.column) catch @panic("failed");
                            std.testing.expectEqual(1, loc.end.line) catch @panic("failed");
                            std.testing.expectEqual(15, loc.end.column) catch @panic("failed");
                        }
                    }.inner)) {
                        .None => unreachable,
                        .Success => {},
                        .Error => if (!std.mem.eql(u8, name, "./sub/test.luau")) @panic("Expected no errors in main module"),
                    }
                    return true;
                }
            }.checkedModule,
            struct {
                fn checkedModuleError(_: *Frontend, name: [:0]const u8, errMsg: [:0]const u8, loc: Location) void {
                    std.debug.print("Error in module {s}: {s} at {d}:{d}-{d}:{d}\n", .{
                        name,
                        errMsg,
                        loc.begin.line,
                        loc.begin.column,
                        loc.end.line,
                        loc.end.column,
                    });
                    @panic("Module check failed");
                }
            }.checkedModuleError,
        );

        try std.testing.expect(success);
    }
}
