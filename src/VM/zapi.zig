const std = @import("std");

const lua = @import("lua.zig");
const lapi = @import("lapi.zig");

pub const ZigFnInt = *const fn (state: *lua.State) i32;
pub const ZigFnVoid = *const fn (state: *lua.State) void;
pub const ZigFnErrorSet = *const fn (state: *lua.State) anyerror!i32;

pub fn ZigToCFn(comptime fnType: std.builtin.Type.Fn, comptime f: anytype) lua.CFunction {
    const ri = @typeInfo(fnType.return_type orelse @compileError("Fn must return something"));
    switch (ri) {
        .int => |_| {
            _ = @as(ZigFnInt, f);
            return struct {
                fn inner(s: *lua.State) callconv(.C) c_int {
                    return @call(.always_inline, f, .{s});
                }
            }.inner;
        },
        .void => |_| {
            _ = @as(ZigFnVoid, f);
            return struct {
                fn inner(s: *lua.State) callconv(.C) c_int {
                    @call(.always_inline, f, .{s});
                    return 0;
                }
            }.inner;
        },
        .error_union => |_| {
            _ = @as(ZigFnErrorSet, f);
            return struct {
                fn inner(s: *lua.State) callconv(.C) c_int {
                    if (@call(.always_inline, f, .{s})) |res|
                        return res
                    else |err| switch (@as(anyerror, @errorCast(err))) {
                        // else => @panic("Unknown error"),
                        error.RaiseLuauYieldError => s.LerrorL("attempt to yield across metamethod/C-call boundary", .{}),
                        error.RaiseLuauError => s.raiseerror(),
                        else => s.LerrorL("{s}", .{@errorName(err)}),
                    }
                }
            }.inner;
        },
        else => @compileError("Unsupported Fn Return type"),
    }
}

pub fn toCFn(comptime f: anytype) lua.CFunction {
    const t = @TypeOf(f);
    const ti = @typeInfo(t);
    switch (ti) {
        .@"fn" => |Fn| return ZigToCFn(Fn, f),
        .pointer => |ptr| {
            // *const fn ...
            if (!ptr.is_const)
                @compileError("Pointer must be constant");
            const pi = @typeInfo(ptr.child);
            switch (pi) {
                .@"fn" => |Fn| return ZigToCFn(Fn, f),
                else => @compileError("Pointer must be a pointer to a function"),
            }
        },
        else => @compileError("zig_fn must be a Fn or a Fn Pointer"),
    }
    @compileError("Could not determine zig_fn type");
}

pub inline fn Zpushfunction(L: *lua.State, comptime f: anytype, name: [:0]const u8) void {
    L.pushcfunction(toCFn(f), name);
}

pub fn Zpushvalue(L: *lua.State, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => L.pushboolean(value),
        .comptime_int => L.pushinteger(@intCast(value)),
        .comptime_float => L.pushnumber(@floatCast(value)),
        .int => |int| {
            const pushfn = if (int.signedness == .signed) lapi.pushinteger else lapi.pushunsigned;
            if (int.bits <= 32)
                pushfn(L, value)
            else
                pushfn(L, @truncate(value));
        },
        .float => |float| {
            if (float.bits <= 64)
                L.pushnumber(@floatCast(value))
            else
                @compileError("float size too large");
        },
        .pointer => |pointer| {
            if (pointer.size == .one)
                switch (@typeInfo(pointer.child)) {
                    .array => |a| {
                        if (a.child == u8)
                            L.pushlstring(value)
                        else
                            @compileError("Unsupported pointer array type");
                    },
                    else => |t| @compileError("Unsupported pointer type " ++ @tagName(t)),
                }
            else if (pointer.size == .slice and pointer.child == u8) {
                if (pointer.sentinel_ptr) |sentinel| {
                    const s: *const pointer.child = @ptrCast(sentinel);
                    if (s.* == 0)
                        L.pushlstring(value)
                    else
                        @compileError("Unsupported pointer sentinel [:?]" ++ @typeName(pointer.child));
                } else L.pushlstring(value);
            } else if (pointer.size == .slice) {
                if (pointer.sentinel_ptr) |_|
                    @compileError("Unsupported pointer sentinel " ++ @typeName(pointer.child));
                var write = value;
                if (value.len > std.math.maxInt(i32))
                    write = value[0..std.math.maxInt(i32)];
                L.createtable(@intCast(value.len), 0);
                for (write, 1..) |v, i| {
                    Zpushvalue(L, v);
                    L.rawseti(-2, @intCast(i));
                }
            }
        },
        .array => |a| {
            if (comptime a.len > std.math.maxInt(i32))
                @compileError("Array too large");
            L.createtable(a.len, 0);
            for (value, 1..) |v, i| {
                Zpushvalue(L, v);
                L.rawseti(-2, @intCast(i));
            }
        },
        .vector => |info| {
            if (info.len != lua.config.VECTOR_SIZE)
                @compileError("Vector size mismatch");
            switch (info.len) {
                3 => L.pushvector(value[0], value[1], value[2], 0),
                4 => L.pushvector(value[0], value[1], value[2], value[3]),
                else => @compileError("Unsupported vector size"),
            }
        },
        .@"enum" => L.pushlstring(@tagName(value)),
        .@"struct" => |s| {
            L.createtable(0, s.fields.len);
            inline for (s.fields) |field| {
                Zpushvalue(L, field.name);
                Zpushvalue(L, @field(value, field.name));
                L.settable(-3);
            }
        },
        .null => L.pushnil(),
        .optional => {
            if (value) |v|
                Zpushvalue(L, v)
            else
                L.pushnil();
        },
        .void => {},
        else => |t| @compileError("Unsupported type " ++ @tagName(t)),
    }
}

pub fn Zsetfield(L: *lua.State, comptime index: i32, k: [:0]const u8, value: anytype) void {
    const idx = comptime if (index != lua.GLOBALSINDEX and index != lua.REGISTRYINDEX and index < 0) index - 1 else index;
    Zpushvalue(L, value);
    L.setfield(idx, k);
}

pub fn Zsetfieldfn(L: *lua.State, comptime index: i32, comptime k: [:0]const u8, comptime f: anytype) void {
    const idx = comptime if (index != lua.GLOBALSINDEX and index != lua.REGISTRYINDEX and index < 0) index - 1 else index;
    Zpushfunction(L, f, k);
    L.setfield(idx, k);
}

pub fn Zsetglobal(L: *lua.State, name: [:0]const u8, value: anytype) void {
    Zpushvalue(L, value);
    L.setglobal(name);
}

pub fn Zsetglobalfn(L: *lua.State, comptime name: [:0]const u8, comptime f: anytype) void {
    Zpushfunction(L, f, name);
    L.setglobal(name);
}

pub fn Zpushbuffer(L: *lua.State, bytes: []const u8) void {
    const buf = L.newbuffer(bytes.len);
    @memcpy(buf, bytes);
}

pub fn Zresumeerror(L: *lua.State, from: ?*lua.State, msg: []const u8) lua.Status {
    L.pushlstring(msg);
    return L.resumeerror(from);
}

pub fn Zresumeferror(L: *lua.State, from: ?*lua.State, comptime fmt: []const u8, args: anytype) lua.Status {
    L.pushfstring(fmt, args);
    return L.resumeerror(from);
}

pub fn Zerror(L: *lua.State, msg: []const u8) anyerror {
    L.pushlstring(msg);
    return error.RaiseLuauError;
}

pub fn Zerrorf(L: *lua.State, comptime fmt: []const u8, args: anytype) anyerror {
    L.pushfstring(fmt, args);
    return error.RaiseLuauError;
}

test toCFn {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) i32 {
                std.testing.expectEqual(6, l.tonumber(1).?) catch @panic("failed");
                l.pushnumber(2);
                return 1;
            }
        }.inner;

        L.pushcclosure(toCFn(foo), "foo", 0);
        L.pushnumber(6);
        L.call(1, 1);
        try std.testing.expectEqual(2, L.tonumber(-1).?);
    }
    {
        const foo = struct {
            fn inner(_: *lua.State) !i32 {
                return error.TestError;
            }
        }.inner;

        L.pushcclosure(toCFn(foo), "foo", 0);
        try std.testing.expectEqual(error.Runtime, L.pcall(0, 0, 0).check());
        try std.testing.expectEqualStrings("TestError", L.tostring(-1).?);
    }
    {
        const foo = struct {
            fn inner(l: *lua.State) void {
                std.testing.expectEqual(9, l.tonumber(1).?) catch @panic("failed");
            }
        }.inner;

        L.pushcclosure(toCFn(foo), "foo", 0);
        L.pushnumber(9);
        L.call(1, 0);
    }
}

test Zpushfunction {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) i32 {
                std.testing.expectEqual(6, l.tonumber(1).?) catch @panic("failed");
                l.pushnumber(2);
                return 1;
            }
        }.inner;

        Zpushfunction(L, foo, "foo");
        L.pushnumber(6);
        L.call(1, 1);
        try std.testing.expectEqual(2, L.tonumber(-1).?);
    }
}

test Zpushvalue {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    Zpushvalue(L, 455);
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(455, L.tointeger(-1).?);

    Zpushvalue(L, @as(u8, 255));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(255, L.tounsigned(-1).?);

    Zpushvalue(L, @as(i10, std.math.maxInt(i10)));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(std.math.maxInt(i10), L.tointeger(-1).?);

    Zpushvalue(L, 1.24);
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(1.24, L.tonumber(-1).?);

    Zpushvalue(L, @as(f32, 1.24));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectApproxEqRel(1.24, L.tonumber(-1).?, 0.001);

    Zpushvalue(L, @as(f64, 1.24));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(1.24, L.tonumber(-1).?);

    Zpushvalue(L, "Test");
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test", L.tostring(-1).?);

    Zpushvalue(L, @as([]const u8, "Test2"));
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test2", L.tostring(-1).?);

    Zpushvalue(L, @as([:0]const u8, "Test3"));
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test3", L.tostring(-1).?);

    Zpushvalue(L, true);
    try std.testing.expectEqual(.Boolean, L.typeOf(-1));
    try std.testing.expectEqual(true, L.toboolean(-1));

    Zpushvalue(L, null);
    try std.testing.expectEqual(.Nil, L.typeOf(-1));
    try std.testing.expectEqual(false, L.toboolean(-1));

    Zpushvalue(L, .{}); // empty struct
    try std.testing.expectEqual(.Table, L.typeOf(-1));
    L.pushnil();
    try std.testing.expectEqual(false, L.next(-2));

    Zpushvalue(L, .{ .x = 1, .y = 2 });
    {
        try std.testing.expectEqual(.Table, L.typeOf(-1));
        L.pushnil();
        try std.testing.expectEqual(true, L.next(-2));
        try std.testing.expectEqual(.String, L.typeOf(-2));
        try std.testing.expectEqual(.Number, L.typeOf(-1));
        L.pop(1);
        try std.testing.expectEqual(true, L.next(-2));
        try std.testing.expectEqual(.String, L.typeOf(-2));
        try std.testing.expectEqual(.Number, L.typeOf(-1));
        L.pop(1);
        try std.testing.expectEqual(false, L.next(-2));

        try std.testing.expectEqual(.Number, L.getfield(-1, "x"));
        try std.testing.expectEqual(1, L.tointeger(-1).?);
        L.pop(1);
        try std.testing.expectEqual(.Number, L.getfield(-1, "y"));
        try std.testing.expectEqual(2, L.tointeger(-1).?);
        L.pop(1);
    }

    if (comptime lua.config.VECTOR_SIZE == 3) {
        Zpushvalue(L, @Vector(3, f32){ 1.0, 2.0, 3.0 });
    } else {
        Zpushvalue(L, @Vector(4, f32){ 1.0, 2.0, 3.0, 4.0 });
    }
    {
        try std.testing.expectEqual(.Vector, L.typeOf(-1));
        const vec = L.tovector(-1).?;
        try std.testing.expectEqual(lua.config.VECTOR_SIZE, vec.len);
        try std.testing.expectEqual(1.0, vec[0]);
        try std.testing.expectEqual(2.0, vec[1]);
        try std.testing.expectEqual(3.0, vec[2]);
        if (comptime lua.config.VECTOR_SIZE == 4)
            try std.testing.expectEqual(4.0, vec[3]);
    }

    {
        var array: [3]i32 = undefined;
        array[0] = 1;
        array[1] = 2;
        array[2] = 3;

        Zpushvalue(L, array);
        {
            try std.testing.expectEqual(.Table, L.typeOf(-1));
            L.pushnil();
            try std.testing.expectEqual(true, L.next(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-1));
            L.pop(1);
            try std.testing.expectEqual(true, L.next(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-1));
            L.pop(1);
            try std.testing.expectEqual(true, L.next(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-1));
            L.pop(1);
            try std.testing.expectEqual(false, L.next(-2));

            try std.testing.expectEqual(.Number, L.rawgeti(-1, 1));
            try std.testing.expectEqual(1, L.tointeger(-1).?);
            L.pop(1);
            try std.testing.expectEqual(.Number, L.rawgeti(-1, 2));
            try std.testing.expectEqual(2, L.tointeger(-1).?);
            L.pop(1);
            try std.testing.expectEqual(.Number, L.rawgeti(-1, 3));
            try std.testing.expectEqual(3, L.tointeger(-1).?);
            L.pop(1);
        }
    }

    {
        var array: []i32 = try std.testing.allocator.alloc(i32, 3);
        defer std.testing.allocator.free(array);
        array[0] = 4;
        array[1] = 5;
        array[2] = 6;

        Zpushvalue(L, array);
        {
            try std.testing.expectEqual(.Table, L.typeOf(-1));
            L.pushnil();
            try std.testing.expectEqual(true, L.next(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-1));
            L.pop(1);
            try std.testing.expectEqual(true, L.next(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-1));
            L.pop(1);
            try std.testing.expectEqual(true, L.next(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-2));
            try std.testing.expectEqual(.Number, L.typeOf(-1));
            L.pop(1);
            try std.testing.expectEqual(false, L.next(-2));

            try std.testing.expectEqual(.Number, L.rawgeti(-1, 1));
            try std.testing.expectEqual(4, L.tointeger(-1).?);
            L.pop(1);
            try std.testing.expectEqual(.Number, L.rawgeti(-1, 2));
            try std.testing.expectEqual(5, L.tointeger(-1).?);
            L.pop(1);
            try std.testing.expectEqual(.Number, L.rawgeti(-1, 3));
            try std.testing.expectEqual(6, L.tointeger(-1).?);
            L.pop(1);
        }
    }

    Zpushvalue(L, @as(?u8, 255));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(255, L.tounsigned(-1).?);

    Zpushvalue(L, @as(?u8, null));
    try std.testing.expectEqual(.Nil, L.typeOf(-1));
    try std.testing.expectEqual(false, L.toboolean(-1));
}

test Zsetfield {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        L.newtable();
        Zsetfield(L, -1, "a", 455);
        Zsetfield(L, -1, "b", "str");
        Zsetfield(L, -1, "c", true);
        try std.testing.expectEqual(.Number, L.getfield(-1, "a"));
        try std.testing.expectEqual(455, L.tointeger(-1).?);
        L.pop(1);
        try std.testing.expectEqual(.String, L.getfield(-1, "b"));
        try std.testing.expectEqualStrings("str", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectEqual(.Boolean, L.getfield(-1, "c"));
        try std.testing.expectEqual(true, L.toboolean(-1));
    }
    {
        Zsetfield(L, lua.GLOBALSINDEX, "a", 455);
        Zsetfield(L, lua.GLOBALSINDEX, "b", "str");
        Zsetfield(L, lua.GLOBALSINDEX, "c", true);
        try std.testing.expectEqual(.Number, L.getfield(lua.GLOBALSINDEX, "a"));
        try std.testing.expectEqual(455, L.tointeger(-1).?);
        try std.testing.expectEqual(.String, L.getfield(lua.GLOBALSINDEX, "b"));
        try std.testing.expectEqualStrings("str", L.tostring(-1).?);
        try std.testing.expectEqual(.Boolean, L.getfield(lua.GLOBALSINDEX, "c"));
        try std.testing.expectEqual(true, L.toboolean(-1));
    }
    {
        Zsetfield(L, lua.REGISTRYINDEX, "a", 455);
        Zsetfield(L, lua.REGISTRYINDEX, "b", "str");
        Zsetfield(L, lua.REGISTRYINDEX, "c", true);
        try std.testing.expectEqual(.Number, L.getfield(lua.REGISTRYINDEX, "a"));
        try std.testing.expectEqual(455, L.tointeger(-1).?);
        try std.testing.expectEqual(.String, L.getfield(lua.REGISTRYINDEX, "b"));
        try std.testing.expectEqualStrings("str", L.tostring(-1).?);
        try std.testing.expectEqual(.Boolean, L.getfield(lua.REGISTRYINDEX, "c"));
        try std.testing.expectEqual(true, L.toboolean(-1));
    }
}

test Zsetglobal {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    Zsetglobal(L, "a", 455);
    Zsetglobal(L, "b", "str");
    Zsetglobal(L, "c", true);
    try std.testing.expectEqual(.Number, L.getglobal("a"));
    try std.testing.expectEqual(455, L.tointeger(-1).?);
    try std.testing.expectEqual(.String, L.getglobal("b"));
    try std.testing.expectEqualStrings("str", L.tostring(-1).?);
    try std.testing.expectEqual(.Boolean, L.getglobal("c"));
    try std.testing.expectEqual(true, L.toboolean(-1));
}

test Zsetfieldfn {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) i32 {
                std.testing.expectEqual(6, l.tonumber(1).?) catch @panic("failed");
                l.pushnumber(2);
                return 1;
            }
        }.inner;

        L.newtable();
        Zsetfieldfn(L, -1, "foo", foo);
        try std.testing.expectEqual(.Function, L.getfield(-1, "foo"));
        L.pushnumber(6);
        L.call(1, 1);
        try std.testing.expectEqual(2, L.tonumber(-1).?);
    }
}

test Zsetglobalfn {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) i32 {
                std.testing.expectEqual(6, l.tonumber(1).?) catch @panic("failed");
                l.pushnumber(2);
                return 1;
            }
        }.inner;

        Zsetglobalfn(L, "foo", foo);
        try std.testing.expectEqual(.Function, L.getglobal("foo"));
        L.pushnumber(6);
        L.call(1, 1);
        try std.testing.expectEqual(2, L.tonumber(-1).?);
    }
}

test Zpushbuffer {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    Zpushbuffer(L, "Test");
    try std.testing.expectEqual(.Buffer, L.typeOf(-1));
    try std.testing.expectEqualSlices(u8, "Test", L.tobuffer(-1).?);
}

test Zresumeerror {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) i32 {
                return l.yield(0);
            }
        }.inner;

        Zpushfunction(L, foo, "foo");
        try std.testing.expectEqual(.Yield, L.resumethread(null, 0));
        try std.testing.expectEqual(.ErrRun, Zresumeerror(L, null, "Test"));
        try std.testing.expectEqualStrings("Test", L.tostring(-1).?);
    }
}

test Zresumeferror {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) i32 {
                return l.yield(0);
            }
        }.inner;

        Zpushfunction(L, foo, "foo");
        try std.testing.expectEqual(.Yield, L.resumethread(null, 0));
        try std.testing.expectEqual(.ErrRun, Zresumeferror(L, null, "Test {s}", .{"Fmt"}));
        try std.testing.expectEqualStrings("Test Fmt", L.tostring(-1).?);
    }
}

test Zerror {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    try std.testing.expectEqual(error.RaiseLuauError, Zerror(L, "Test"));
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test", L.tostring(-1).?);
}

test Zerrorf {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    try std.testing.expectEqual(error.RaiseLuauError, Zerrorf(L, "Test {s}", .{"Fmt"}));
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test Fmt", L.tostring(-1).?);
}
