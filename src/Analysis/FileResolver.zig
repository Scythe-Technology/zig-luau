const std = @import("std");

const FileResolver_readSource = fn (ud: *anyopaque, name: [*c]const u8, len: usize, outLen: *usize, outType: *u8) callconv(.c) ?[*]const u8;
const FileResolver_resolveModule = fn (ud: *anyopaque, name: [*c]const u8, len: usize, node: [*c]const u8, nodeLen: usize, outLen: *usize) callconv(.c) ?[*]const u8;
const FileResolver_getHumanReadableModuleName = fn (ud: *anyopaque, name: [*c]const u8, len: usize, outLen: *usize) callconv(.c) [*]const u8;
const FileResolver_freeString = fn (ud: *anyopaque, str: [*c]const u8, len: usize) callconv(.c) void;

extern "c" fn zig_Luau_Analysis_FileResolver_init(
    *anyopaque,
    *const FileResolver_readSource,
    *const FileResolver_resolveModule,
    *const FileResolver_getHumanReadableModuleName,
    *const FileResolver_freeString,
) *anyopaque;
extern "c" fn zig_Luau_Analysis_FileResolver_dtor(*anyopaque) *anyopaque;

pub const SourceCodeType = enum {
    Script,
    Module,
    None,
};

pub fn FileResolver(comptime T: type) type {
    return opaque {
        const Self = @This();
        pub fn init(ctx: *T) *Self {
            return @ptrCast(zig_Luau_Analysis_FileResolver_init(
                @ptrCast(@alignCast(ctx)),
                struct {
                    fn inner(ud: *anyopaque, name: [*c]const u8, len: usize, outLen: *usize, outType: *u8) callconv(.c) ?[*]const u8 {
                        const res: struct { []const u8, SourceCodeType } = @call(.always_inline, T.readSource, .{ @as(*T, @ptrCast(@alignCast(ud))), name[0..len] }) orelse return null;
                        const buf, const t = res;
                        outLen.* = buf.len;
                        outType.* = @intFromEnum(t);
                        return buf.ptr;
                    }
                }.inner,
                struct {
                    fn inner(ud: *anyopaque, name: [*c]const u8, len: usize, node: [*c]const u8, nodeLen: usize, outLen: *usize) callconv(.c) ?[*]const u8 {
                        const res: []const u8 = @call(.always_inline, T.resolveModule, .{ @as(*T, @ptrCast(@alignCast(ud))), name[0..len], node[0..nodeLen] }) orelse return null;
                        outLen.* = res.len;
                        return res.ptr;
                    }
                }.inner,
                struct {
                    fn inner(ud: *anyopaque, name: [*c]const u8, len: usize, outLen: *usize) callconv(.c) [*]const u8 {
                        const res: []const u8 = @call(.always_inline, T.getHumanReadableModuleName, .{ @as(*T, @ptrCast(@alignCast(ud))), name[0..len] });
                        outLen.* = res.len;
                        return res.ptr;
                    }
                }.inner,
                struct {
                    fn inner(ud: *anyopaque, str: [*c]const u8, len: usize) callconv(.c) void {
                        @call(.always_inline, T.freeString, .{ @as(*T, @ptrCast(@alignCast(ud))), str[0..len] });
                    }
                }.inner,
            ));
        }

        pub fn deinit(self: *Self) void {
            const ctx = zig_Luau_Analysis_FileResolver_dtor(self);
            if (@hasDecl(T, "deinit")) {
                @call(.always_inline, T.deinit, .{@as(*T, @ptrCast(@alignCast(ctx)))});
            }
        }
    };
}

test "FileResolver" {
    const Sample = struct {
        const Self = @This();
        pub fn readSource(_: *Self, _: []const u8) ?struct { []const u8, SourceCodeType } {
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

    const SampleResolver = FileResolver(Sample);

    var sample: Sample = .{};
    const resolver = SampleResolver.init(&sample);
    defer resolver.deinit();
}
