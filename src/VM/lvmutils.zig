const std = @import("std");

const lua = @import("lua.zig");
const ltm = @import("ltm.zig");
const ldebug = @import("ldebug.zig");
const lobject = @import("lobject.zig");
const lstring = @import("lstring.zig");
const lnumutils = @import("lnumutils.zig");

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

pub fn Vtostring(L: *lua.State, obj: *lobject.TValue) bool {
    if (!obj.ttisnumber())
        return false
    else {
        var s: [lnumutils.I_MAXNUM2STR]u8 = undefined;
        const n = obj.nvalue();
        const e = lnumutils.inum2str(&s, n);
        obj.setsvalue(L, lstring.Snewlstr(L, e) catch return false);
        return true;
    }
}

// pub fn Vlessthan(L: *lua.State, l: *const lobject.TValue, r: *const lobject.TValue) bool {
//     if (l.ttype() != r.ttype()) {
//         ldebug.Gordererror();
//     }
// }

fn get_compTM(L: *lua.State, mt1: *lobject.LuaTable, mt2: *lobject.LuaTable, event: ltm.TMS) ?*const lobject.TValue {
    const tm1 = ltm.gfasttm(L.global, mt1, event) orelse return null;
    if (mt1 == mt2)
        return tm1;
    const tm2 = ltm.gfasttm(L.global, mt2, event) orelse return null;
    if (lobject.OrawequalObj(tm1, tm2))
        return tm1;
    return null;
}

// pub fn Vequalval(L: *lua.State, t1: *const lobject.TValue, t2: *const lobject.TValue) bool {
//     std.debug.assert(t1.ttype() == t2.ttype());
//     switch (t1.ttype()) {
//         .Nil => return true,
//         .Number => return t1.nvalue() == t2.nvalue(),
//         .Vector => lnumutils.iveceq(t1.vvalue(), t2.vvalue()),
//         .Boolean => return t1.bvalue() == t2.bvalue(),
//         .LightUserdata => return t1.pvalue() == t2.pvalue() and t1.lightuserdatatag() == t2.lightuserdatatag(),
//         .Userdata => {
//             const tm = get_compTM(L, t1.u.table, t2.u.table, ltm.TMS.TM_EQ) orelse return t1.hvalue() == t2.hvalue();
//             callTMres(L, L.top, tm, t1, t2);
//             return !(L.top.ttisnil() or L.top.ttisboolean() and !L.top.bvalue());
//         },
//     }
// }

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
                .header = .{
                    .tt = @intFromEnum(lua.Type.String),
                    .marked = 0,
                    .memcat = 0,
                },
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
                .header = .{
                    .tt = @intFromEnum(lua.Type.String),
                    .marked = 0,
                    .memcat = 0,
                },
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
