const c = @import("c");

const lua = @import("lua.zig");

pub inline fn iveceq(a: []const f32, b: []const f32) bool {
    if (comptime lua.config.VECTOR_SIZE == 4)
        return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
    else
        return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

pub inline fn inum2int(x: f64) i32 {
    return @truncate(@as(i53, @intFromFloat(x)));
}
