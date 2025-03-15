const c = @import("c");

const lua = @import("lua.zig");

pub inline fn inumisnan(x: anytype) bool {
    comptime switch (@typeInfo(@TypeOf(x))) {
        .comptime_float, .float => {},
        .comptime_int, .int => {},
        else => @compileError("Unsupported type"),
    };
    return x != x;
}

pub inline fn iveceq(a: []const f32, b: []const f32) bool {
    if (comptime lua.config.VECTOR_SIZE == 4)
        return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
    else
        return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

pub inline fn ivecisnan(x: []const f32) bool {
    if (comptime lua.config.VECTOR_SIZE == 4)
        return x[0] != x[0] or x[1] != x[1] or x[2] != x[2] or x[3] != x[3]
    else
        return x[0] != x[0] or x[1] != x[1] or x[2] != x[2];
}

pub inline fn inum2int(x: f64) i32 {
    return @truncate(@as(i53, @intFromFloat(x)));
}
