const std = @import("std");

const lua = @import("lua.zig");
const lobject = @import("lobject.zig");

pub fn Vtonumber(obj: *const lobject.TValue, n: *lobject.TValue) ?*const lobject.TValue {
    if (obj.ttisnumber())
        return obj;
    if (obj.ttisstring()) {
        const num = std.fmt.parseFloat(f64, std.mem.span(obj.svalue())) catch return null;
        n.setnvalue(num);
        return n;
    }
    return null;
}

test Vtonumber {
    const allocator = std.testing.allocator;

    {
        var n = lobject.TValue{ .tt = @intFromEnum(lua.Type.None), .value = undefined };
        const obj = lobject.TValue{ .tt = @intFromEnum(lua.Type.Number), .value = .{ .n = 1.0 } };
        try std.testing.expect(Vtonumber(&obj, &n) == &obj);
    }
    {
        var n = lobject.TValue{ .tt = @intFromEnum(lua.Type.None), .value = undefined };
        const obj = lobject.TValue{ .tt = @intFromEnum(lua.Type.Boolean), .value = .{ .b = 1 } };
        try std.testing.expect(Vtonumber(&obj, &n) == null);
    }
    {
        const GCObject = @import("lstate.zig").GCObject;
        const gc_buf = try allocator.alloc(u8, @sizeOf(GCObject) + 4);
        defer allocator.free(gc_buf);
        const gc: *GCObject = @ptrCast(@alignCast(gc_buf[0..@sizeOf(GCObject)]));
        gc.* = .{
            .gch = .{
                .tt = @intFromEnum(lua.Type.String),
                .marked = 0,
                .memcat = 0,
            },
        };

        const data = gc_buf[@offsetOf(lobject.TString, "data")..];
        data[0] = '1';
        data[1] = '2';
        data[2] = '3';
        data[3] = 0;

        var n = lobject.TValue{ .tt = @intFromEnum(lua.Type.None), .value = undefined };
        const obj = lobject.TValue{ .tt = @intFromEnum(lua.Type.String), .value = .{ .gc = gc } };
        try std.testing.expect(Vtonumber(&obj, &n) == &n);
        try std.testing.expect(n.ttisnumber());
        try std.testing.expect(n.nvalue() == 123.0);
    }
    {
        const GCObject = @import("lstate.zig").GCObject;
        const gc_buf = try allocator.alloc(u8, @sizeOf(GCObject) + 2);
        defer allocator.free(gc_buf);
        const gc: *GCObject = @ptrCast(@alignCast(gc_buf[0..@sizeOf(GCObject)]));
        gc.* = .{
            .gch = .{
                .tt = @intFromEnum(lua.Type.String),
                .marked = 0,
                .memcat = 0,
            },
        };

        const data = gc_buf[@offsetOf(lobject.TString, "data")..];
        data[0] = 'b';
        data[1] = 0;

        var n = lobject.TValue{ .tt = @intFromEnum(lua.Type.None), .value = undefined };
        const obj = lobject.TValue{ .tt = @intFromEnum(lua.Type.String), .value = .{ .gc = gc } };
        try std.testing.expect(Vtonumber(&obj, &n) == null);
    }
}
