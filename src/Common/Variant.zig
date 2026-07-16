const std = @import("std");

pub fn Variant(comptime Ts: []const type) type {
    comptime {
        if (Ts.len == 0) @compileError("variant must have at least 1 type");
    }

    const storage_size = comptime blk: {
        var max: usize = 0;
        for (Ts) |T|
            max = @max(max, @sizeOf(T));
        break :blk max;
    };

    const storage_align = comptime blk: {
        var max: usize = 1;
        for (Ts) |T|
            max = @max(max, @alignOf(T));
        break :blk max;
    };

    const TaggedUnion = blk: {
        var fields: [Ts.len]std.builtin.Type.UnionField = undefined;
        inline for (Ts, 0..) |T, i| {
            fields[i] = .{
                .name = std.fmt.comptimePrint("{d}", .{i}), // becomes @"0", @"1", etc.
                .type = T,
                .alignment = @alignOf(T),
            };
        }
        break :blk @Type(.{
            .@"union" = .{
                .layout = .auto,
                .tag_type = null,
                .fields = &fields,
                .decls = &.{},
            },
        });
    };

    return extern struct {
        typeId: c_int,
        storage: [storage_size]u8 align(storage_align),

        pub const Union = TaggedUnion;

        pub fn @"union"(self: *const @This()) Union {
            inline for (Ts, 0..) |T, i| {
                if (self.typeId == @as(c_int, @intCast(i))) {
                    const active_ptr: *const T = @ptrCast(@alignCast(&self.storage));
                    return @unionInit(
                        Union,
                        std.fmt.comptimePrint("{d}", .{i}),
                        active_ptr.*,
                    );
                }
            }
            unreachable;
        }

        pub fn index(self: *const @This()) c_int {
            return self.typeId;
        }
    };
}
