const std = @import("std");

const lua = @import("lua.zig");
const ltm = @import("ltm.zig");
const lapi = @import("lapi.zig");
const laux = @import("laux.zig");

pub fn LuaZigFn(comptime ReturnType: type) type {
    switch (@typeInfo(ReturnType)) {
        .int => {
            if (ReturnType != i32)
                @compileError("Unsupported Fn Return type, must be i32");
        },
        else => {},
    }
    return *const fn (state: *lua.State) ReturnType;
}

fn handleError(L: *lua.State, err: anyerror) noreturn {
    switch (err) {
        // else => @panic("Unknown error"),
        error.RaiseLuauYieldError => L.LerrorL("attempt to yield across metamethod/C-call boundary", .{}),
        error.RaiseLuauError => L.raiseerror(),
        else => L.LerrorL("{s}", .{@errorName(err)}),
    }
}

pub fn ZigToCFn(comptime fnType: std.builtin.Type.Fn, comptime f: anytype) lua.CFunction {
    if (fnType.params.len != 1)
        @compileError("Fn must have exactly 1 parameter");
    const param_type = fnType.params[0].type orelse @compileError("Param must have a type");
    if (param_type != *lua.State)
        @compileError("Fn parameter must be *lua.State");
    switch (@typeInfo(fnType.return_type orelse @compileError("Fn must return something"))) {
        .int => {
            if (fnType.return_type != i32)
                @compileError("Unsupported Fn Return type, must be i32");
            return struct {
                fn inner(s: *lua.State) callconv(.C) c_int {
                    return @call(.always_inline, f, .{s});
                }
            }.inner;
        },
        .void => {
            return struct {
                fn inner(s: *lua.State) callconv(.C) c_int {
                    @call(.always_inline, f, .{s});
                    return 0;
                }
            }.inner;
        },
        .error_union => |error_union| {
            switch (@typeInfo(error_union.payload)) {
                .int => {
                    if (error_union.payload != i32)
                        @compileError("Unsupported Fn Return type, must be i32");
                    return struct {
                        fn inner(s: *lua.State) callconv(.C) c_int {
                            if (@call(.always_inline, f, .{s})) |res|
                                return res
                            else |err|
                                handleError(s, err);
                        }
                    }.inner;
                },
                .void => {
                    return struct {
                        fn inner(s: *lua.State) callconv(.C) c_int {
                            if (@call(.always_inline, f, .{s}))
                                return 0
                            else |err|
                                handleError(s, err);
                        }
                    }.inner;
                },
                else => |t| @compileError("Unsupported Fn Return type " ++ @tagName(t)),
            }
        },
        else => |t| @compileError("Unsupported Fn Return type " ++ @tagName(t)),
    }
}

pub fn ZigToCFnV(comptime fnType: std.builtin.Type.Fn, comptime f: anytype) lua.CFunction {
    if (fnType.params.len != 1)
        @compileError("Fn must have exactly 1 parameter");
    const param_type = fnType.params[0].type orelse @compileError("Param must have a type");
    if (param_type != *lua.State)
        @compileError("Fn parameter must be *lua.State");
    switch (@typeInfo(fnType.return_type orelse @compileError("Fn must return something"))) {
        .void, .noreturn => {
            return struct {
                fn inner(L: *lua.State) callconv(.C) c_int {
                    @call(.always_inline, f, .{L});
                    return 0;
                }
            }.inner;
        },
        .comptime_int, .comptime_float, .bool, .int, .float, .@"struct", .array, .@"enum", .null, .optional => {
            return struct {
                fn inner(L: *lua.State) callconv(.C) c_int {
                    Zpushvalue(L, @call(.always_inline, f, .{L}));
                    return 1;
                }
            }.inner;
        },
        .error_union => |error_union| {
            switch (@typeInfo(error_union.payload)) {
                .void, .noreturn => {
                    return struct {
                        fn inner(L: *lua.State) callconv(.C) c_int {
                            if (@call(.always_inline, f, .{L}))
                                return 0
                            else |err|
                                handleError(L, err);
                        }
                    }.inner;
                },
                .comptime_int, .comptime_float, .bool, .int, .float, .@"struct", .array, .@"enum", .null, .optional => {
                    return struct {
                        fn inner(L: *lua.State) callconv(.C) c_int {
                            if (@call(.always_inline, f, .{L})) |res| {
                                Zpushvalue(L, res);
                                return 1;
                            } else |err| handleError(L, err);
                        }
                    }.inner;
                },
                else => |t| @compileError("Unsupported Fn Return type " ++ @tagName(t)),
            }
        },
        .error_set => |_| {
            return struct {
                fn inner(L: *lua.State) callconv(.C) c_int {
                    const err = @call(.always_inline, f, .{L});
                    return handleError(L, err);
                }
            }.inner;
        },
        else => |t| @compileError("Unsupported Fn Return type " ++ @tagName(t)),
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

pub fn toCFnV(comptime f: anytype) lua.CFunction {
    const t = @TypeOf(f);
    const ti = @typeInfo(t);
    switch (ti) {
        .@"fn" => |Fn| return ZigToCFnV(Fn, f),
        .pointer => |ptr| {
            // *const fn ...
            if (!ptr.is_const)
                @compileError("Pointer must be constant");
            const pi = @typeInfo(ptr.child);
            switch (pi) {
                .@"fn" => |Fn| return ZigToCFnV(Fn, f),
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

pub inline fn ZpushfunctionV(L: *lua.State, comptime f: anytype, name: [:0]const u8) void {
    L.pushcfunction(toCFnV(f), name);
}

pub fn Zpushvalue(L: *lua.State, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => L.pushboolean(value),
        .comptime_int => L.pushinteger(@intCast(value)),
        .comptime_float => L.pushnumber(@floatCast(value)),
        .int => |int| {
            const pushfn = if (int.signedness == .signed) lapi.pushinteger else lapi.pushunsigned;
            if (int.bits <= 32)
                pushfn(L, @intCast(value))
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
        .@"enum" => |e| {
            switch (@typeInfo(e.tag_type)) {
                .int => |int| {
                    if (int.signedness == .unsigned)
                        L.pushunsigned(@intFromEnum(value))
                    else
                        L.pushinteger(@intFromEnum(value));
                },
                else => @compileError("Unsupported enum type " ++ @tagName(e.tag_type)),
            }
        },
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
pub fn ZsetfieldfnV(L: *lua.State, comptime index: i32, comptime k: [:0]const u8, comptime f: anytype) void {
    const idx = comptime if (index != lua.GLOBALSINDEX and index != lua.REGISTRYINDEX and index < 0) index - 1 else index;
    ZpushfunctionV(L, f, k);
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
pub fn ZsetglobalfnV(L: *lua.State, comptime name: [:0]const u8, comptime f: anytype) void {
    ZpushfunctionV(L, f, name);
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

/// Calls a metamethod and pushes the result on the stack.
/// If the metamethod fails, it returns an error & error value on stack.
pub fn Zcallmeta(L: *lua.State, obj: i32, event: [:0]const u8) !bool {
    const idx = lapi.absindex(L, obj);
    if (!L.Lgetmetafield(idx, event))
        return false;
    L.pushvalue(idx);
    _ = try L.pcall(1, 1, 0).check();
    return true;
}

/// Converts value to string & pushes to stack.
pub fn Ztolstringk(L: *lua.State, idx: i32) [:0]const u8 {
    const MAX_NUM_BUF = std.fmt.format_float.bufferSize(.decimal, f64);
    const VEC_SIZE = lua.config.VECTOR_SIZE;
    switch (L.typeOf(idx)) {
        .Nil => L.pushlstring("nil"),
        .Boolean => L.pushlstring(if (L.toboolean(idx)) "true" else "false"),
        .Number => {
            const number = L.tonumber(idx).?;
            var s: [MAX_NUM_BUF]u8 = undefined;
            const buf = std.fmt.bufPrint(&s, "{d}", .{number}) catch unreachable; // should be able to fit
            L.pushlstring(buf);
        },
        .Vector => {
            const vec = L.tovector(idx).?;
            var s: [(MAX_NUM_BUF * VEC_SIZE) + ((VEC_SIZE - 1) * 2)]u8 = undefined;
            const buf = if (VEC_SIZE == 3)
                std.fmt.bufPrint(&s, "{d}, {d}, {d}", .{ vec[0], vec[1], vec[2] }) catch unreachable // should be able to fit
            else
                std.fmt.bufPrint(&s, "{d}, {d}, {d}, {d}", .{ vec[0], vec[1], vec[2], vec[3] }) catch unreachable; // should be able to fit
            L.pushlstring(buf);
        },
        .String => L.pushvalue(idx),
        else => {
            const ptr = L.topointer(idx);
            var s: [20 + ltm.LONGEST_TYPENAME_SIZE]u8 = undefined; // 16 + 2 + 2(extra) + size
            const buf = std.fmt.bufPrint(&s, "{s}: 0x{x:016}", .{ lapi.typename(L.typeOf(idx)), @intFromPtr(ptr) }) catch unreachable; // should be able to fit
            L.pushlstring(buf);
        },
    }
    return L.tolstring(-1) orelse unreachable;
}

/// Converts value to string & pushes to stack. Calls a __tostring metamethod when it exists.
/// If the metamethod fails, it returns an error & error value on stack.
pub fn Ztolstring(L: *lua.State, idx: i32) ![:0]const u8 {
    if (try Zcallmeta(L, idx, "__tostring")) {
        return L.tolstring(-1) orelse return error.BadReturnType;
    }
    return Ztolstringk(L, idx);
}

fn tag_error(L: *lua.State, narg: i32, tag: lua.Type, comptime msg: ?[]const u8) anyerror {
    const curr_type = L.typeOf(narg);
    const fname = laux.currfuncname(L);
    if (narg > 0) {
        if (msg) |m| {
            if (fname) |name|
                return Zerrorf(L, "{s}, argument #{d} to '{s}' (expected {s}, got {s})", .{ m, narg, name, lapi.typename(tag), lapi.typename(curr_type) })
            else
                return Zerrorf(L, "{s}, argument #{d} (expected {s}, got {s})", .{ m, narg, lapi.typename(tag), lapi.typename(curr_type) });
        } else {
            if (fname) |name|
                return Zerrorf(L, "invalid argument #{d} to '{s}' (expected {s}, got {s})", .{ narg, name, lapi.typename(tag), lapi.typename(curr_type) })
            else
                return Zerrorf(L, "invalid argument #{d} (expected {s}, got {s})", .{ narg, lapi.typename(tag), lapi.typename(curr_type) });
        }
    } else {
        return Zerrorf(L, "{s} (expected {s}, got {s})", .{ msg orelse "invalid value", lapi.typename(tag), lapi.typename(curr_type) });
    }
}

pub fn Zcheckstack(L: *lua.State, space: i32, msg: ?[]const u8) !void {
    if (!L.checkstack(space))
        if (msg) |m|
            return Zerrorf(L, "stack overflow ({s})", .{m})
        else
            return Zerrorf(L, "stack overflow", .{});
}

pub fn Zchecktype(L: *lua.State, narg: i32, t: lua.Type) !void {
    if (L.typeOf(narg) != t)
        return tag_error(L, narg, t, null);
}

pub fn Zcheckvalue(L: *lua.State, comptime T: type, narg: i32, comptime msg: ?[]const u8) !T {
    switch (@typeInfo(T)) {
        .bool => if (L.isboolean(narg))
            return L.toboolean(narg)
        else
            return tag_error(L, narg, .Boolean, msg),
        .int => |int| {
            if (!L.isnumber(narg))
                return tag_error(L, narg, .Number, msg);
            if (int.bits < 32) {
                const value = lapi.tointeger(L, narg) orelse unreachable;
                const max = std.math.maxInt(T);
                const min = std.math.minInt(T);
                if (value > max or value < min) {
                    if (narg > 0) {
                        return L.Zerrorf("invalid argument #{d} (expected number between {d} and {d}, got {d})", .{ narg, min, max, value });
                    } else {
                        return L.Zerrorf("{s} (expected number between {d} and {d}, got {d})", .{ msg orelse "invalid value", min, max, value });
                    }
                }
                return @intCast(value);
            } else if (int.bits == 32) {
                const getfn = if (int.signedness == .signed) lapi.tointeger else lapi.tounsigned;
                return getfn(L, narg) orelse unreachable;
            } else @compileError("int size too large, 32 bits or lower is supported");
        },
        .float => |float| {
            if (!L.isnumber(narg))
                return tag_error(L, narg, .Number, msg);
            if (float.bits <= 64)
                return @floatCast(L.tonumber(narg) orelse unreachable)
            else
                @compileError("float size too large");
        },
        .pointer => |pointer| {
            if (pointer.size == .one)
                switch (L.typeOf(narg)) {
                    .LightUserdata, .Userdata => return L.touserdata(pointer.child, narg) orelse unreachable,
                    else => return tag_error(L, narg, .Userdata, msg),
                }
            else if (pointer.size == .slice) {
                if (pointer.child == u8) {
                    if (pointer.sentinel_ptr) |sentinel| {
                        const s: *const pointer.child = @ptrCast(sentinel);
                        if (s.* == 0) {
                            if (!pointer.is_const)
                                @compileError("Pointer must be [:0]const u8 when using a sentinel, string only");
                            if (L.typeOf(narg) != .String)
                                return tag_error(L, narg, .String, msg);
                            return L.tostring(narg) orelse unreachable;
                        } else @compileError("Unsupported pointer sentinel [:?]" ++ @typeName(pointer.child));
                    } else {
                        if (pointer.is_const)
                            switch (L.typeOf(narg)) {
                                .String => return L.tolstring(narg) orelse unreachable,
                                .Buffer => return L.tobuffer(narg) orelse unreachable,
                                else => return tag_error(L, narg, .String, msg),
                            }
                        else switch (L.typeOf(narg)) {
                            .Buffer => return L.tobuffer(narg) orelse unreachable,
                            else => return tag_error(L, narg, .Buffer, msg),
                        }
                    }
                } else if (pointer.child == f32) {
                    if (pointer.is_const and pointer.sentinel_ptr == null) {
                        if (L.isvector(narg))
                            return L.tovector(narg) orelse unreachable
                        else
                            return tag_error(L, narg, .Vector, msg);
                    } else @compileError("Unsupported pointer type, you would need to make []f32 const and exclude sentinel" ++ @typeName(T));
                } else @compileError("Unsupported pointer type " ++ @typeName(T));
            } else @compileError("Unsupported pointer type " ++ @typeName(T));
        },
        .@"enum" => |e| {
            switch (@typeInfo(e.tag_type)) {
                .int => |int| {
                    if (int.bits > 32)
                        @compileError("int size too large, 32 bits or lower is supported");
                    if (!L.isnumber(narg))
                        return tag_error(L, narg, .Number, msg);
                    if (int.signedness == .unsigned) {
                        const value = L.tounsigned(narg) orelse unreachable;
                        comptime var can_cast = true;
                        comptime for (e.fields, 0..) |field, order| {
                            if (field.value != order) {
                                can_cast = false;
                                break;
                            }
                        };
                        if (comptime can_cast) {
                            if (value < e.fields.len)
                                return @enumFromInt(value);
                        } else {
                            inline for (e.fields) |field| {
                                if (field.value == value)
                                    return @enumFromInt(value);
                            }
                        }
                        return Zerror(L, "Invalid enum value");
                    } else {
                        const value = L.tointeger(narg) orelse unreachable;
                        inline for (e.fields) |field| {
                            if (field.value == value)
                                return @enumFromInt(value);
                        }
                        return Zerror(L, "Invalid enum value");
                    }
                },
                else => @compileError("Unsupported enum type " ++ @tagName(e.tag_type)),
            }
        },
        .null => if (L.typeOf(narg) == .Nil)
            return null
        else
            return tag_error(L, narg, .Nil, msg),
        .optional => |optional| {
            if (L.isnoneornil(narg))
                return null;
            return try Zcheckvalue(L, optional.child, narg, msg);
        },
        .void => if (L.typeOf(narg) == .None)
            return
        else {
            return tag_error(L, narg, .None, msg);
        },
        else => |t| @compileError("Unsupported type " ++ @tagName(t)),
    }
}

pub fn Zcheckfield(L: *lua.State, comptime T: type, idx: i32, comptime field: [:0]const u8) !T {
    _ = L.getfield(idx, field);
    return try Zcheckvalue(L, T, -1, "invalid field '" ++ field ++ "'");
}

const EXCEPTIONS_ENABLED = !@import("builtin").cpu.arch.isWasm();

test "toCFn + Zchecktype" {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) !i32 {
                try Zchecktype(l, 1, .Number);
                std.testing.expectEqual(6, l.tonumber(1).?) catch @panic("failed");
                l.pushnumber(2);
                return 1;
            }
        }.inner;

        L.pushcclosure(toCFn(foo), "foo", 0);
        L.pushnumber(6);
        L.call(1, 1);
        defer L.pop(1);
        try std.testing.expectEqual(2, L.tonumber(-1).?);
    }
    if (comptime EXCEPTIONS_ENABLED) {
        const foo = struct {
            fn inner(l: *lua.State) !i32 {
                try Zchecktype(l, 1, .Number);
                return 0;
            }
        }.inner;

        L.pushcclosure(toCFn(foo), "foo", 0);
        try std.testing.expectEqual(error.Runtime, L.pcall(0, 0, 0).check());
        try std.testing.expectEqualStrings("invalid argument #1 to 'foo' (expected number, got nil)", L.tostring(-1).?);
        defer L.pop(1);
    }
    if (comptime EXCEPTIONS_ENABLED) {
        const foo = struct {
            fn inner(_: *lua.State) !i32 {
                return error.TestError;
            }
        }.inner;

        L.pushcclosure(toCFn(foo), "foo", 0);
        try std.testing.expectEqual(error.Runtime, L.pcall(0, 0, 0).check());
        try std.testing.expectEqualStrings("TestError", L.tostring(-1).?);
        defer L.pop(1);
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

test toCFnV {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    {
        const foo = struct {
            fn inner(l: *lua.State) i32 {
                std.testing.expectEqual(6, l.tonumber(1).?) catch @panic("failed");
                return 2;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.pushnumber(6);
        L.call(1, 1);
        defer L.pop(1);
        try std.testing.expectEqual(2, L.tonumber(-1).?);
    }
    {
        const foo = struct {
            fn inner(_: *lua.State) comptime_int {
                return 8;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.call(0, 1);
        defer L.pop(1);
        try std.testing.expectEqual(8, L.tonumber(-1).?);
    }
    {
        const foo = struct {
            fn inner(_: *lua.State) comptime_float {
                return 123.456;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.call(0, 1);
        defer L.pop(1);
        try std.testing.expectEqual(123.456, L.tonumber(-1).?);
    }
    {
        const foo = struct {
            fn inner(_: *lua.State) f64 {
                return 234.567;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.call(0, 1);
        defer L.pop(1);
        try std.testing.expectEqual(234.567, L.tonumber(-1).?);
    }
    {
        const Dummy = struct {
            a: f64,
            b: enum { A, B, C },
            c: []const u8,
            d: i4,
        };
        const foo = struct {
            fn inner(_: *lua.State) Dummy {
                return Dummy{
                    .a = 3.14,
                    .b = .A,
                    .c = "Test",
                    .d = 6,
                };
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.call(0, 1);
        defer L.pop(1);
        try std.testing.expectEqual(.Number, L.getfield(-1, "a"));
        try std.testing.expectEqual(3.14, L.tonumber(-1).?);
        L.pop(1);
        try std.testing.expectEqual(.Number, L.getfield(-1, "b"));
        try std.testing.expectEqual(0, L.tointeger(-1).?);
        L.pop(1);
        try std.testing.expectEqual(.String, L.getfield(-1, "c"));
        try std.testing.expectEqualStrings("Test", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectEqual(.Number, L.getfield(-1, "d"));
        try std.testing.expectEqual(6, L.tointeger(-1).?);
        L.pop(1);
    }
    {
        const foo = struct {
            fn inner(_: *lua.State) ?i32 {
                return 123;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.call(0, 1);
        defer L.pop(1);
        try std.testing.expectEqual(123, L.tonumber(-1).?);
    }
    {
        const foo = struct {
            fn inner(_: *lua.State) !?i32 {
                return 123;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.call(0, 1);
        defer L.pop(1);
        try std.testing.expectEqual(123, L.tonumber(-1).?);
    }
    {
        const foo = struct {
            fn inner(_: *lua.State) enum { A, B, C } {
                return .C;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        L.call(0, 1);
        defer L.pop(1);
        try std.testing.expectEqual(2, L.tointeger(-1).?);
    }
    if (comptime EXCEPTIONS_ENABLED) {
        const foo = struct {
            fn inner(_: *lua.State) !?i32 {
                return error.Failed;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        try std.testing.expectEqual(error.Runtime, L.pcall(0, 0, 0).check());
        try std.testing.expectEqualStrings("Failed", L.tostring(-1).?);
        defer L.pop(1);
    }
    if (comptime EXCEPTIONS_ENABLED) {
        const foo = struct {
            fn inner(_: *lua.State) !i32 {
                return error.TestError;
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
        try std.testing.expectEqual(error.Runtime, L.pcall(0, 0, 0).check());
        try std.testing.expectEqualStrings("TestError", L.tostring(-1).?);
        defer L.pop(1);
    }
    {
        const foo = struct {
            fn inner(l: *lua.State) void {
                std.testing.expectEqual(9, l.tonumber(1).?) catch @panic("failed");
            }
        }.inner;

        L.pushcclosure(toCFnV(foo), "foo", 0);
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
    L.pop(1);

    Zpushvalue(L, @as(u8, 255));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(255, L.tounsigned(-1).?);
    L.pop(1);

    Zpushvalue(L, @as(i10, std.math.maxInt(i10)));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(std.math.maxInt(i10), L.tointeger(-1).?);
    L.pop(1);

    Zpushvalue(L, 1.24);
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(1.24, L.tonumber(-1).?);
    L.pop(1);

    Zpushvalue(L, @as(f32, 1.24));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectApproxEqRel(1.24, L.tonumber(-1).?, 0.001);
    L.pop(1);

    Zpushvalue(L, @as(f64, 1.24));
    try std.testing.expectEqual(.Number, L.typeOf(-1));
    try std.testing.expectEqual(1.24, L.tonumber(-1).?);
    L.pop(1);

    Zpushvalue(L, "Test");
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test", L.tostring(-1).?);
    L.pop(1);

    Zpushvalue(L, @as([]const u8, "Test2"));
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test2", L.tostring(-1).?);
    L.pop(1);

    Zpushvalue(L, @as([:0]const u8, "Test3"));
    try std.testing.expectEqual(.String, L.typeOf(-1));
    try std.testing.expectEqualStrings("Test3", L.tostring(-1).?);
    L.pop(1);

    Zpushvalue(L, true);
    try std.testing.expectEqual(.Boolean, L.typeOf(-1));
    try std.testing.expectEqual(true, L.toboolean(-1));
    L.pop(1);

    Zpushvalue(L, null);
    try std.testing.expectEqual(.Nil, L.typeOf(-1));
    try std.testing.expectEqual(false, L.toboolean(-1));
    L.pop(1);

    Zpushvalue(L, .{}); // empty struct
    try std.testing.expectEqual(.Table, L.typeOf(-1));
    L.pushnil();
    try std.testing.expectEqual(false, L.next(-2));
    L.pop(1);

    Zpushvalue(L, .{ .x = 1, .y = 2 });
    {
        defer L.pop(1);
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
        defer L.pop(1);
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
        defer L.pop(1);
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
        defer L.pop(1);
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
    L.pop(1);

    Zpushvalue(L, @as(?u8, null));
    try std.testing.expectEqual(.Nil, L.typeOf(-1));
    try std.testing.expectEqual(false, L.toboolean(-1));
    L.pop(1);

    {
        Zpushvalue(L, .{
            .x = 1,
            .y = 2,
        });
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
}

test Zcheckvalue {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.deinit();

    Zpushvalue(L, 455);
    try std.testing.expectEqual(455, try Zcheckvalue(L, i32, -1, null));
    L.pop(1);

    Zpushvalue(L, 1.24);
    try std.testing.expectEqual(1.24, try Zcheckvalue(L, f64, -1, null));
    L.pop(1);

    Zpushvalue(L, "Test");
    try std.testing.expectEqualStrings("Test", try Zcheckvalue(L, []const u8, -1, null));
    L.pop(1);

    Zpushvalue(L, true);
    try std.testing.expectEqual(true, try Zcheckvalue(L, bool, -1, null));
    L.pop(1);

    Zpushvalue(L, null);
    try std.testing.expectEqual(null, try Zcheckvalue(L, ?i32, -1, null));
    L.pop(1);
    Zpushvalue(L, 2);
    try std.testing.expectEqual(2, try Zcheckvalue(L, ?i32, -1, null));
    L.pop(1);

    const e = enum { A, B, C };
    Zpushvalue(L, e.A);
    try std.testing.expectEqual(e.A, try Zcheckvalue(L, e, -1, null));
    L.pop(1);

    const odd_e = enum(u4) { A = 2, B = 3, C = 4 };
    Zpushvalue(L, odd_e.A);
    try std.testing.expectEqual(odd_e.A, try Zcheckvalue(L, odd_e, -1, null));
    L.pop(1);

    const signed_e = enum(i32) { A = -1, B = 2, C = 4 };
    Zpushvalue(L, signed_e.B);
    try std.testing.expectEqual(signed_e.B, try Zcheckvalue(L, signed_e, -1, null));
    L.pop(1);

    {
        const ud = struct { b: i32, c: i32 };
        const ptr = L.newuserdata(ud);
        ptr.* = .{ .b = 1, .c = 2 };
        const checked_ud = try Zcheckvalue(L, *ud, -1, null);
        try std.testing.expectEqual(1, checked_ud.b);
        try std.testing.expectEqual(2, checked_ud.c);
    }

    {
        const vec = if (lua.config.VECTOR_SIZE == 3)
            @Vector(3, f32){ 1.0, 2.0, 3.0 }
        else
            @Vector(4, f32){ 1.0, 2.0, 3.0, 4.0 };
        Zpushvalue(L, vec);
        const checked_vec = try Zcheckvalue(L, []const f32, -1, null);
        try std.testing.expectEqual(1.0, checked_vec[0]);
        try std.testing.expectEqual(2.0, checked_vec[1]);
        try std.testing.expectEqual(3.0, checked_vec[2]);
        if (lua.config.VECTOR_SIZE == 4)
            try std.testing.expectEqual(4.0, checked_vec[3]);
        L.pop(1);
    }

    {
        Zpushbuffer(L, "Test");
        const checked_buf = try Zcheckvalue(L, []const u8, -1, null);
        try std.testing.expectEqualSlices(u8, "Test", checked_buf);
        const checked_buf2 = try Zcheckvalue(L, []u8, -1, null);
        try std.testing.expectEqualSlices(u8, "Test", checked_buf2);
        L.pop(1);
    }

    {
        L.pushlstring("Test2");
        const checked_buf = try Zcheckvalue(L, []const u8, -1, null);
        try std.testing.expectEqualSlices(u8, "Test2", checked_buf);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, []u8, @intCast(L.gettop()), null));
        try std.testing.expectEqualStrings("invalid argument #2 (expected buffer, got string)", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, []u8, @intCast(L.gettop()), "custom"));
        try std.testing.expectEqualStrings("custom, argument #2 (expected buffer, got string)", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, []u8, -1, null));
        try std.testing.expectEqualStrings("invalid value (expected buffer, got string)", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, []u8, -1, "custom"));
        try std.testing.expectEqualStrings("custom (expected buffer, got string)", L.tostring(-1).?);
        L.pop(2);
    }

    {
        L.pushinteger(255);
        const num = try Zcheckvalue(L, u8, -1, null);
        try std.testing.expectEqual(255, num);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, u2, @intCast(L.gettop()), null));
        try std.testing.expectEqualStrings("invalid argument #2 (expected number between 0 and 3, got 255)", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, i2, @intCast(L.gettop()), null));
        try std.testing.expectEqualStrings("invalid argument #2 (expected number between -2 and 1, got 255)", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, u2, -1, null));
        try std.testing.expectEqualStrings("invalid value (expected number between 0 and 3, got 255)", L.tostring(-1).?);
        L.pop(2);
    }
    {
        L.pushinteger(-20);
        const num = try Zcheckvalue(L, i8, -1, null);
        try std.testing.expectEqual(-20, num);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, u2, @intCast(L.gettop()), null));
        try std.testing.expectEqualStrings("invalid argument #2 (expected number between 0 and 3, got -20)", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, i2, @intCast(L.gettop()), null));
        try std.testing.expectEqualStrings("invalid argument #2 (expected number between -2 and 1, got -20)", L.tostring(-1).?);
        L.pop(1);
        try std.testing.expectError(error.RaiseLuauError, Zcheckvalue(L, i3, -1, null));
        try std.testing.expectEqualStrings("invalid value (expected number between -4 and 3, got -20)", L.tostring(-1).?);
        L.pop(2);
    }
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

test Ztolstring {
    const L = try @import("lstate.zig").Lnewstate();
    defer L.close();

    {
        L.pushnil();
        try std.testing.expectEqualStrings("nil", try Ztolstring(L, -1));
        L.pop(1);
    }
    {
        L.pushboolean(true);
        try std.testing.expectEqualStrings("true", try Ztolstring(L, -1));
        L.pop(1);
    }
    {
        if (lua.config.VECTOR_SIZE == 3) {
            L.pushvector(1.2, 44.0, 123.0, 0.0);
            try std.testing.expectEqualStrings("1.2, 44, 123", try Ztolstring(L, -1));
        } else {
            L.pushvector(1.2, 44.0, 123.0, 1205.0);
            try std.testing.expectEqualStrings("1.2, 44, 123, 1205", try Ztolstring(L, -1));
        }
        L.pop(1);
    }
    {
        L.pushstring("hello");
        try std.testing.expectEqualStrings("hello", try Ztolstring(L, -1));
        L.pop(1);
    }
    {
        L.pushinteger(-123);
        try std.testing.expectEqualStrings("-123", try Ztolstring(L, -1));
        L.pop(1);
    }
    {
        L.pushunsigned(123);
        try std.testing.expectEqualStrings("123", try Ztolstring(L, -1));
        L.pop(1);
    }
    {
        L.pushnumber(123.0);
        try std.testing.expectEqualStrings("123", try Ztolstring(L, -1));
        L.pop(1);
    }
    {
        L.pushlightuserdata(@ptrFromInt(0));
        try std.testing.expectEqualStrings("userdata: 0x0000000000000000", try Ztolstring(L, -1));
        L.pop(1);
    }
    {
        _ = L.newuserdata(struct {});
        L.newtable();
        L.Zpushfunction(struct {
            fn inner(l: *lua.State) i32 {
                l.pushlstring("meta_test");
                return 1;
            }
        }.inner, "__tostring");
        L.setfield(-2, "__tostring");
        _ = L.setmetatable(-2);
        try std.testing.expectEqualStrings("meta_test", try Ztolstring(L, -1));
        L.pop(2);
    }
    if (comptime EXCEPTIONS_ENABLED) {
        _ = L.newuserdata(struct {});
        L.newtable();
        L.Zpushfunction(struct {
            fn inner(l: *lua.State) i32 {
                l.pushstring("error");
                l.raiseerror();
            }
        }.inner, "__tostring");
        L.setfield(-2, "__tostring");
        _ = L.setmetatable(-2);
        try std.testing.expectEqual(error.Runtime, Ztolstring(L, -1));
        try std.testing.expectEqual(.String, L.typeOf(-1));
        try std.testing.expectEqualStrings("error", L.tostring(-1).?);
        L.pop(2);
    }
    {
        _ = L.newuserdata(struct {});
        L.newtable();
        L.Zpushfunction(struct {
            fn inner(l: *lua.State) i32 {
                l.newtable();
                return 1;
            }
        }.inner, "__tostring");
        L.setfield(-2, "__tostring");
        _ = L.setmetatable(-2);
        try std.testing.expectEqual(error.BadReturnType, Ztolstring(L, -1));
        try std.testing.expectEqual(.Table, L.typeOf(-1));
        L.pop(2);
    }
}
