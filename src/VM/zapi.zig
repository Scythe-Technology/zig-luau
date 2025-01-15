const std = @import("std");

const lua = @import("lua.zig");

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

pub inline fn pushfunction(L: *lua.State, comptime f: anytype, name: [:0]const u8) void {
    L.pushcfunction(toCFn(f), name);
}

pub fn Zpushvalue(L: *lua.State, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => L.pushboolean(value),
        .comptime_int => L.pushinteger(@intCast(value)),
        .comptime_float => L.pushnumber(@floatCast(value)),
        .int => |int| {
            if (int.bits <= 32)
                (if (int.signedness == .signed) L.pushinteger else L.pushunsigned)(value)
            else
                (if (int.signedness == .signed) L.pushinteger else L.pushunsigned)(@truncate(value));
        },
        .float => |float| {
            if (float.bits <= 64)
                L.pushnumber(@floatCast(value))
            else
                @compileError("float size too large");
        },
        .pointer => |pointer| {
            if (pointer.size == .One)
                switch (@typeInfo(pointer.child)) {
                    .@"fn" => L.pushcfunction(toCFn(value)),
                    .array => |a| {
                        if (a.child == u8)
                            L.pushlstring(value)
                        else
                            @compileError("Unsupported pointer array type");
                    },
                    else => |t| @compileError("Unsupported pointer type " ++ @tagName(t)),
                }
            else if (pointer.size == .Slice and pointer.child == u8) {
                if (pointer.sentinel) |sentinel| {
                    if (@intFromPtr(sentinel) == 0)
                        L.pushlstring(value)
                    else
                        @compileError("Unsupported pointer sentinel");
                } else L.pushlstring(value);
            } else @compileError("Unsupported pointer type");
        },
        .@"fn" => L.pushcfunction(toCFn(value), "?anon func?"),
        .array => |a| {
            L.createtable(a.len, 0);
            for (value, 0..) |v, i| {
                Zpushvalue(L, i + 1);
                Zpushvalue(L, v);
                L.settable(-3);
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

pub fn Zsetglobal(L: *lua.State, name: [:0]const u8, value: anytype) void {
    Zpushvalue(L, value);
    L.setglobal(name);
}

pub fn Zpushbuffer(L: *lua.State, bytes: []const u8) void {
    const buf = L.newbuffer(bytes.len);
    @memcpy(buf, bytes);
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
