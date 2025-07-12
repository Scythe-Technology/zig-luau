const lua = @import("lua.zig");
const lobject = @import("lobject.zig");
const lvmutils = @import("lvmutils.zig");

pub inline fn equalobj(L: *lua.State, o1: *const lobject.TValue, o2: *const lobject.TValue) bool {
    return o1.ttype() == o2.ttype() and lvmutils.Vequalval(L, o1, o2);
}
