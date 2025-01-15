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
