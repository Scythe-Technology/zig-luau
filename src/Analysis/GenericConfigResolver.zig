const std = @import("std");

const cpp_std = @import("../cpp_std.zig");

const ErrorGroup = extern struct {
    paths: [*][*c]const u8,
    messages: [*][*c]const u8,
    size: usize,
};

const Mode = enum(u8) {
    NoCheck = 0,
    Nonstrict = 1,
    Strict = 2,
    Definition = 3,
};

const ConfigErrors = cpp_std.Vector(cpp_std.Pair(cpp_std.String, cpp_std.String));
const ResolverInterface = extern struct {
    vtable: *const anyopaque,
    errors: ConfigErrors,
};

extern "c" fn zig_Luau_Analysis_GenericConfigResolver_init(u8) *GenericConfigResolver;
extern "c" fn zig_Luau_Analysis_GenericConfigResolver_dtor(*GenericConfigResolver) void;

pub const GenericConfigResolver = opaque {
    pub const AnyErrorGroup = struct {
        group: ErrorGroup,

        pub fn paths(self: AnyErrorGroup) []const [*c]const u8 {
            return self.group.paths[0..self.group.size];
        }
        pub fn messages(self: AnyErrorGroup) []const [*c]const u8 {
            return self.group.messages[0..self.group.size];
        }
    };

    pub fn getErrors(self: *GenericConfigResolver) ConfigErrors {
        return @as(*ResolverInterface, @ptrCast(@alignCast(self))).errors;
    }

    pub fn deinit(self: *GenericConfigResolver) void {
        zig_Luau_Analysis_GenericConfigResolver_dtor(self);
    }
};

pub fn init(mode: Mode) *GenericConfigResolver {
    return zig_Luau_Analysis_GenericConfigResolver_init(@intFromEnum(mode));
}

test GenericConfigResolver {
    const resolver = init(.Strict);
    defer resolver.deinit();

    const errors = resolver.getErrors();

    try std.testing.expect(errors.size() == 0);
}
