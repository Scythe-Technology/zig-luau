const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const luau = @import("luau");

const AllocFn = luau.AllocFn;
const StringBuffer = luau.StringBuffer;
const DebugInfo = luau.DebugInfo;
const State = luau.VM.lua.State;

const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;

const EXCEPTIONS_ENABLED = !builtin.cpu.arch.isWasm();

fn expectStringContains(actual: []const u8, expected_contains: []const u8) !void {
    if (std.mem.indexOf(u8, actual, expected_contains) == null)
        return;
    return error.TestExpectedStringContains;
}

fn alloc(data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    _ = data;

    const alignment = @alignOf(std.c.max_align_t);
    if (@as(?[*]align(alignment) u8, @ptrCast(@alignCast(ptr)))) |prev_ptr| {
        const prev_slice = prev_ptr[0..osize];
        if (nsize == 0) {
            testing.allocator.free(prev_slice);
            return null;
        }
        const new_ptr = testing.allocator.realloc(prev_slice, nsize) catch return null;
        return new_ptr.ptr;
    } else if (nsize == 0) {
        return null;
    } else {
        const new_ptr = testing.allocator.alignedAlloc(u8, alignment, nsize) catch return null;
        return new_ptr.ptr;
    }
}

fn failing_alloc(data: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    _ = data;
    _ = ptr;
    _ = osize;
    _ = nsize;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

test "initialization" {
    // initialize the Zig wrapper
    var lua = try luau.init(&testing.allocator);
    try expectEqual(luau.VM.lua.Status.Ok, lua.status());
    lua.deinit();

    // attempt to initialize the Zig wrapper with no memory
    try expectError(error.OutOfMemory, luau.init(&testing.failing_allocator));

    // use the library directly
    lua = try luau.VM.lstate.newstate(alloc, null);
    lua.close();

    // use the library with a bad AllocFn
    try expectError(error.OutOfMemory, luau.VM.lstate.newstate(failing_alloc, null));

    // use the auxiliary library (uses libc realloc and cannot be checked for leaks!)
    lua = try luau.VM.lstate.Lnewstate();
    lua.close();
}

test "alloc functions" {
    var lua = try luau.VM.lstate.newstate(alloc, null);
    defer lua.deinit();

    // get default allocator
    var data: *anyopaque = undefined;
    try expectEqual(alloc, lua.getallocf(&data));
}

test "Zig allocator access" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const inner = struct {
        fn inner(l: *State) i32 {
            const allocator = luau.getallocator(l);

            const num = l.tointeger(1) orelse @panic("expected integer");

            // Use the allocator
            const nums = allocator.alloc(i32, @intCast(num)) catch unreachable;
            defer allocator.free(nums);

            // Do something pointless to use the slice
            var sum: i32 = 0;
            for (nums, 0..) |*n, i| n.* = @intCast(i);
            for (nums) |n| sum += n;

            l.pushinteger(sum);
            return 1;
        }
    }.inner;

    lua.Zpushfunction(inner, "test");
    lua.pushinteger(10);
    _ = lua.pcall(1, 1, 0);

    try expectEqual(45, lua.tointeger(-1).?);
}

test "standard library loading" {
    // open all standard libraries
    {
        var lua = try luau.init(&testing.allocator);
        defer lua.deinit();
        lua.Lopenlibs();
    }

    // open all standard libraries with individual functions
    // these functions are only useful if you want to load the standard
    // packages into a non-standard table
    {
        var lua = try luau.init(&testing.allocator);
        defer lua.deinit();

        lua.openbase();
        lua.openstring();
        lua.opentable();
        lua.openmath();
        lua.openos();
        lua.opendebug();
        lua.opencoroutine();
        lua.openutf8();
        lua.openbit32();
        lua.openbuffer();
        lua.openvector();
    }
}

test "number conversion success and failure" {
    const lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    _ = lua.pushstring("1234.5678");
    try expectEqual(1234.5678, lua.tonumber(-1) orelse return error.InvalidType);

    _ = lua.pushstring("1234");
    try expectEqual(1234, lua.tointeger(-1) orelse return error.InvalidType);

    lua.pushnil();
    try expectError(error.Fail, lua.tonumber(-1) orelse error.Fail);
    try expectError(error.Fail, lua.tointeger(-1) orelse error.Fail);

    _ = lua.pushstring("fail");
    try expectError(error.Fail, lua.tonumber(-1) orelse error.Fail);
    try expectError(error.Fail, lua.tointeger(-1) orelse error.Fail);
}

test "compare" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.pushnumber(1);
    lua.pushnumber(2);

    try testing.expect(!lua.equal(1, 2));
    try testing.expect(lua.lessthan(1, 2));

    lua.pushinteger(2);
    try testing.expect(lua.equal(2, 3));
}

const add = struct {
    fn addInner(l: *State) i32 {
        const a = l.tointeger(1) orelse 0;
        const b = l.tointeger(2) orelse 0;
        l.pushinteger(a + b);
        return 1;
    }
}.addInner;

test "type of and getting values" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.pushnil();
    try expect(lua.isnil(1));
    try expect(lua.isnoneornil(1));
    try expect(lua.isnoneornil(2));
    try expect(lua.isnone(2));
    try expectEqual(.Nil, lua.typeOf(1));

    lua.pushboolean(true);
    try expectEqual(.Boolean, lua.typeOf(-1));
    try expect(lua.isboolean(-1));

    lua.newtable();
    try expectEqual(.Table, lua.typeOf(-1));
    try expect(lua.istable(-1));

    lua.pushinteger(1);
    try expectEqual(.Number, lua.typeOf(-1));
    try expect(lua.isnumber(-1));
    try expectEqual(1, lua.tointeger(-1) orelse @panic("bad"));
    try expectEqualStrings("number", lua.Ltypename(-1));

    lua.pushunsigned(4);
    try expectEqual(.Number, lua.typeOf(-1));
    try expect(lua.isnumber(-1));
    try expectEqual(4, lua.tounsigned(-1) orelse @panic("bad"));
    try expectEqualStrings("number", lua.Ltypename(-1));

    var value: i32 = 0;
    lua.pushlightuserdata(&value);
    try expectEqual(.LightUserdata, lua.typeOf(-1));
    try expect(lua.islightuserdata(-1));
    try expect(lua.isuserdata(-1));

    lua.pushnumber(0.1);
    try expectEqual(.Number, lua.typeOf(-1));
    try expect(lua.isnumber(-1));
    try expectEqual(0.1, lua.tonumber(-1) orelse @panic("bad"));

    _ = lua.pushthread();
    try expectEqual(.Thread, lua.typeOf(-1));
    try expect(lua.isthread(-1));
    try expectEqual(lua, lua.tothread(-1) orelse @panic("bad"));

    lua.pushstring("all your codebase are belong to us");
    try expectEqualStrings("all your codebase are belong to us", lua.tolstring(-1) orelse @panic("bad"));
    try expectEqual(.String, lua.typeOf(-1));
    try expect(lua.isstring(-1));

    lua.Zpushfunction(add, "func");
    try expectEqual(.Function, lua.typeOf(-1));
    try expect(lua.iscfunction(-1));
    try expect(lua.isfunction(-1));
    try expectEqual(luau.VM.zapi.toCFn(add), lua.tocfunction(-1).?);

    lua.pushstring("hello world");
    try expectEqualStrings("hello world", lua.tostring(-1) orelse @panic("bad"));
    try expectEqual(.String, lua.typeOf(-1));
    try expect(lua.isstring(-1));

    lua.pushfstring("{s} {s} {d}", .{ "hello", "world", @as(i32, 10) });
    try expectEqual(.String, lua.typeOf(-1));
    try expect(lua.isstring(-1));
    try expectEqualStrings("hello world 10", lua.tostring(-1) orelse @panic("bad"));

    // Comptime known
    lua.pushfstring("{s} {s} {d}", .{ "hello", "world", @as(i32, 10) });
    try expectEqual(.String, lua.typeOf(-1));
    try expect(lua.isstring(-1));
    try expectEqualStrings("hello world 10", lua.tostring(-1) orelse @panic("bad"));

    // Runtime known
    const arg1 = try std.testing.allocator.dupe(u8, "Hello");
    defer std.testing.allocator.free(arg1);
    const arg2 = try std.testing.allocator.dupe(u8, "World");
    defer std.testing.allocator.free(arg2);

    lua.pushfstring("{s} {s} {d}", .{ arg1, arg2, @as(i32, 10) });
    try expectEqual(.String, lua.typeOf(-1));
    try expect(lua.isstring(-1));
    try expectEqualStrings("Hello World 10", lua.tostring(-1) orelse @panic("bad"));

    lua.pushvalue(2);
    try expectEqual(.Boolean, lua.typeOf(-1));
    try expect(lua.isboolean(-1));
}

test "typenames" {
    try expectEqualStrings("no value", luau.VM.lapi.typename(.None));
    try expectEqualStrings("nil", luau.VM.lapi.typename(.Nil));
    try expectEqualStrings("boolean", luau.VM.lapi.typename(.Boolean));
    try expectEqualStrings("userdata", luau.VM.lapi.typename(.LightUserdata));
    try expectEqualStrings("number", luau.VM.lapi.typename(.Number));
    try expectEqualStrings("string", luau.VM.lapi.typename(.String));
    try expectEqualStrings("table", luau.VM.lapi.typename(.Table));
    try expectEqualStrings("function", luau.VM.lapi.typename(.Function));
    try expectEqualStrings("userdata", luau.VM.lapi.typename(.Userdata));
    try expectEqualStrings("thread", luau.VM.lapi.typename(.Thread));
    try expectEqualStrings("vector", luau.VM.lapi.typename(.Vector));
    try expectEqualStrings("buffer", luau.VM.lapi.typename(.Buffer));
}

// test "executing string contents" {
//     var lua = try luau.init(&testing.allocator);
//     defer lua.deinit();
//     lua.Lopenlibs();

//     try lua.loadString("f = function(x) return x + 10 end");
//     _ = lua.pcall(0, 0, 0);
//     try lua.loadString("a = f(2)");
//     _ = lua.pcall(0, 0, 0);

//     try expectEqual(.number, try lua.getglobal("a"));
//     try expectEqual(12, try lua.toInteger(1));

//     try expectError(error.Fail, lua.loadString("bad syntax"));
//     try lua.loadString("a = g()");
//     try expectError(error.Runtime, lua.pcall(0, 0, 0));
// }

test "filling and checking the stack" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    try expectEqual(0, lua.gettop());

    // We want to push 30 values onto the stack
    // this should work without fail
    try expectEqual(true, lua.checkstack(30));

    var count: i32 = 0;
    while (count < 30) : (count += 1) {
        lua.pushnil();
    }

    try expectEqual(30, lua.gettop());

    // this should fail (beyond max stack size)
    try expectEqual(false, lua.checkstack(1_000_000));

    // this is small enough it won't fail (would raise an error if it did)
    lua.Lcheckstack(40, null);
    while (count < 40) : (count += 1) {
        lua.pushnil();
    }

    try expectEqual(40, lua.gettop());
}

test "stack manipulation" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    var num: i32 = 1;
    while (num <= 10) : (num += 1) {
        lua.pushinteger(num);
    }
    try expectEqual(10, lua.gettop());

    lua.settop(12);
    try expectEqual(12, lua.gettop());
    try expect(lua.isnil(-1));

    lua.remove(1);
    try expect(lua.isnil(-1));

    lua.insert(1);
    try expect(lua.isnil(1));

    lua.settop(0);
    try expectEqual(0, lua.gettop());
}

test "calling a function" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.Zsetglobalc("zigadd", add);

    _ = lua.getglobal("zigadd");
    lua.pushinteger(10);
    lua.pushinteger(32);

    // pcall is preferred, but we might as well test call when we know it is safe
    lua.call(2, 1);
    try expectEqual(42, lua.tointeger(1).?);
}

// test "string buffers" {
//     var lua = try luau.init(&testing.allocator);
//     defer lua.deinit();

// var buffer: StringBuffer = undefined;
// buffer.init(lua);

// buffer.addChar('z');
// buffer.addString("igl");

// var str = buffer.prep();
// str[0] = 'u';
// str[1] = 'a';
// str[2] = 'u';
// buffer.addSize(3);

// buffer.addString(" api ");
// lua.pushnumber(5.1);
// buffer.addValue();
// buffer.pushResult();
// try expectEqualStrings("zigluau api 5.1", try lua.toString(-1));

// // now test a small buffer
// buffer.init(lua);
// var b = buffer.prep();
// b[0] = 'a';
// b[1] = 'b';
// b[2] = 'c';
// buffer.addSize(3);

// b = buffer.prep();
// @memcpy(b[0..23], "defghijklmnopqrstuvwxyz");
// buffer.addSize(23);
// buffer.pushResult();
// try expectEqualStrings("abcdefghijklmnopqrstuvwxyz", try lua.toString(-1));
// lua.pop(1);

// buffer.init(lua);
// b = buffer.prep();
// @memcpy(b[0..3], "abc");
// buffer.pushResultSize(3);
// try expectEqualStrings("abc", try lua.toString(-1));
// lua.pop(1);
// }

const sub = struct {
    fn subInner(l: *State) i32 {
        const a = l.toInteger(1) catch 0;
        const b = l.toInteger(2) catch 0;
        l.pushinteger(a - b);
        return 1;
    }
}.subInner;

test "function registration" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const funcs = [_]luau.VM.laux.Reg{
        .{ .name = "add", .func = luau.VM.zapi.toCFn(add) },
    };
    lua.newtable();
    lua.Lregister(null, &funcs);

    _ = lua.getfield(-1, "add");
    lua.pushinteger(1);
    lua.pushinteger(2);
    _ = lua.pcall(2, 1, 0);
    try expectEqual(3, lua.tointeger(-1).?);
    lua.settop(0);

    // register functions as globals in a library table
    lua.Lregister("testlib", &funcs);

    // testlib.add(1, 2)
    _ = lua.getglobal("testlib");
    _ = lua.getfield(-1, "add");
    lua.pushinteger(1);
    lua.pushinteger(2);
    _ = lua.pcall(2, 1, 0);
    try expectEqual(3, lua.tointeger(-1).?);
}

test "warn fn" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const warnFn = struct {
        fn inner(L: *State) void {
            const msg = L.tostring(1) orelse @panic("bad");
            if (!std.mem.eql(u8, msg, "this will be caught by the warnFn"))
                std.debug.panic("test failed", .{});
        }
    }.inner;

    lua.Zpushfunction(warnFn, "newWarn");
    lua.pushvalue(-1);
    lua.setfield(luau.VM.lua.GLOBALSINDEX, "warn");
    lua.pushstring("this will be caught by the warnFn");
    lua.call(1, 0);
}

test "string literal" {
    const allocator = testing.allocator;
    var lua = try luau.init(&allocator);
    defer lua.deinit();

    const zbytes = [_:0]u8{ 'H', 'e', 'l', 'l', 'o', ' ', 0, 'W', 'o', 'r', 'l', 'd' };
    try testing.expectEqual(zbytes.len, 12);

    lua.pushstring(&zbytes);
    const str1 = lua.tostring(-1) orelse @panic("bad");
    try testing.expectEqual(str1.len, 6);
    try testing.expectEqualStrings("Hello ", str1);

    lua.pushlstring(&zbytes);
    const str2 = lua.tostring(-1) orelse @panic("bad");
    try testing.expectEqual(str2.len, 12);
    try testing.expectEqualStrings(&zbytes, str2);
}

test "concat" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    _ = lua.pushstring("hello ");
    lua.pushnumber(10);
    _ = lua.pushstring(" wow!");
    lua.concat(3);

    try expectEqualStrings("hello 10 wow!", lua.tostring(-1) orelse @panic("bad"));
}

test "garbage collector" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    // because the garbage collector is an opaque, unmanaged
    // thing, it is hard to test, so just run each function
    _ = lua.gc(.Stop, 0);
    _ = lua.gc(.Collect, 0);
    _ = lua.gc(.Restart, 0);
    _ = lua.gc(.Count, 0);
    _ = lua.gc(.CountB, 0);

    _ = lua.gc(.IsRunning, 0);
    _ = lua.gc(.Step, 0);

    _ = lua.gc(.SetGoal, 10);
    _ = lua.gc(.SetStepMul, 2);
    _ = lua.gc(.SetStepSize, 1);
}

test "threads" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    var new_thread = lua.newthread();

    try expectEqual(1, lua.gettop());
    try expectEqual(0, new_thread.gettop());

    lua.pushinteger(10);
    lua.pushnil();

    try expectEqual(3, lua.gettop());

    lua.xmove(new_thread, 2);

    try expectEqual(2, new_thread.gettop());
    try expectEqual(1, lua.gettop());

    var new_thread2 = lua.newthread();

    try expectEqual(2, lua.gettop());
    try expectEqual(0, new_thread2.gettop());

    lua.pushnil();

    lua.xpush(new_thread2, -1);

    try expectEqual(3, lua.gettop());
    try expectEqual(1, new_thread2.gettop());
    try expectEqual(.Nil, new_thread2.typeOf(1));
}

test "userdata and uservalues" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const Data = struct {
        val: i32,
        code: [4]u8,
    };

    // create a Luau-owned pointer to a Data with 2 associated user values
    var data = lua.newuserdata(Data);
    data.val = 1;
    @memcpy(&data.code, "abcd");

    try expectEqual(data, lua.touserdata(Data, 1) orelse @panic("bad"));
    try expectEqual(@as(*const anyopaque, @ptrCast(data)), lua.topointer(1) orelse @panic("bad"));
}

test "upvalues" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    // counter from PIL
    const counter = struct {
        fn inner(l: *State) i32 {
            var counter = l.tointeger(luau.VM.lua.upvalueindex(1)) orelse 0;
            counter += 1;
            l.pushinteger(counter);
            l.pushinteger(counter);
            l.replace(luau.VM.lua.upvalueindex(1));
            return 1;
        }
    }.inner;

    // Initialize the counter at 0
    lua.pushinteger(0);
    lua.pushcclosure(luau.VM.zapi.toCFn(counter), "counter", 1);
    lua.setglobal("counter");

    // call the function repeatedly, each time ensuring the result increases by one
    var expected: i32 = 1;
    while (expected <= 10) : (expected += 1) {
        _ = lua.getglobal("counter");
        lua.call(0, 1);
        try expectEqual(expected, lua.tointeger(-1).?);
        lua.pop(1);
    }
}

test "raise error" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const makeError = struct {
        fn inner(l: *State) i32 {
            _ = l.pushstring("makeError made an error");
            l.raiseerror();
            return 0;
        }
    }.inner;

    lua.Zpushfunction(makeError, "func");
    lua.pushinteger(1256);
    try expectError(error.Runtime, lua.pcall(1, 0, 0).check());
    try expectEqualStrings("makeError made an error", lua.tostring(-1).?);
}

fn continuation(l: *State, status: luau.Status, ctx: isize) i32 {
    _ = status;

    if (ctx == 5) {
        _ = l.pushstring("done");
        return 1;
    } else {
        // yield the current context value
        l.pushinteger(ctx);
        return l.yieldCont(1, ctx + 1, luau.wrap(continuation));
    }
}

fn continuation52(l: *State) i32 {
    const ctxOrNull = l.getContext() catch unreachable;
    const ctx = ctxOrNull orelse 0;
    if (ctx == 5) {
        _ = l.pushstring("done");
        return 1;
    } else {
        // yield the current context value
        l.pushinteger(ctx);
        return l.yieldCont(1, ctx + 1, luau.wrap(continuation52));
    }
}

test "yielding no continuation" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const thread = lua.newthread();
    const func = struct {
        fn inner(l: *State) i32 {
            l.pushinteger(1);
            return l.yield(1);
        }
    }.inner;
    thread.Zpushfunction(func, "func");

    try expectEqual(.Suspended, lua.costatus(thread));

    _ = try thread.resumethread(null, 0).check();

    try expectEqual(.Suspended, lua.costatus(thread));
    try expectEqual(1, thread.tointeger(-1).?);
    thread.resetthread();
    try expect(thread.isthreadreset());
    try expectEqual(.Finished, lua.costatus(thread));
}

test "aux check functions" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const function = struct {
        fn inner(l: *State) i32 {
            l.Lcheckany(1);
            _ = l.Lcheckinteger(2);
            _ = l.Lchecknumber(3);
            _ = l.Lcheckstring(4);
            l.Lchecktype(5, .Boolean);
            return 0;
        }
    }.inner;

    lua.Zpushfunction(function, "func");
    _ = lua.pcall(0, 0, 0).check() catch {
        try expectStringContains("argument #1", lua.tostring(-1) orelse @panic("bad"));
        lua.pop(-1);
    };

    lua.Zpushfunction(function, "func");
    lua.pushnil();
    _ = lua.pcall(1, 0, 0).check() catch {
        try expectStringContains("number expected", lua.tostring(-1) orelse @panic("bad"));
        lua.pop(-1);
    };

    lua.Zpushfunction(function, "func");
    lua.pushnil();
    lua.pushinteger(3);
    _ = lua.pcall(2, 0, 0).check() catch {
        try expectStringContains("string expected", lua.tostring(-1) orelse @panic("bad"));
        lua.pop(-1);
    };

    lua.Zpushfunction(function, "func");
    lua.pushnil();
    lua.pushinteger(3);
    lua.pushnumber(4);
    _ = lua.pcall(3, 0, 0).check() catch {
        try expectStringContains("string expected", lua.tostring(-1) orelse @panic("bad"));
        lua.pop(-1);
    };

    lua.Zpushfunction(function, "func");
    lua.pushnil();
    lua.pushinteger(3);
    lua.pushnumber(4);
    _ = lua.pushstring("hello world");
    _ = lua.pcall(4, 0, 0).check() catch {
        try expectStringContains("boolean expected", lua.tostring(-1) orelse @panic("bad"));
        lua.pop(-1);
    };

    lua.Zpushfunction(function, "func");
    // test pushFail here (currently acts the same as pushnil)
    lua.pushnil();
    lua.pushinteger(3);
    lua.pushnumber(4);
    _ = lua.pushstring("hello world");
    lua.pushboolean(true);
    _ = lua.pcall(5, 0, 0);
}

test "aux opt functions" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const function = struct {
        fn inner(l: *State) i32 {
            expectEqual(10, l.Loptinteger(1, 10)) catch unreachable;
            expectEqualStrings("zig", l.Loptstring(2, "zig")) catch unreachable;
            expectEqual(1.23, l.Loptnumber(3, 1.23)) catch unreachable;
            expectEqualStrings("lang", l.Loptstring(4, "lang")) catch unreachable;
            return 0;
        }
    }.inner;

    lua.Zpushfunction(function, "func");
    _ = lua.pcall(0, 0, 0);

    lua.Zpushfunction(function, "func");
    lua.pushinteger(10);
    _ = lua.pushstring("zig");
    lua.pushnumber(1.23);
    _ = lua.pushstring("lang");
    _ = lua.pcall(4, 0, 0);
}

// test "checkOption" {
//     if (!EXCEPTIONS_ENABLED)
//         return error.SkipZigTest;

//     var lua = try luau.init(&testing.allocator);
//     defer lua.deinit();

//     const Variant = enum {
//         one,
//         two,
//         three,
//     };

//     const function = struct {
//         fn inner(l: *lua) i32 {
//             const option = l.checkOption(Variant, 1, .one);
//             l.pushinteger(switch (option) {
//                 .one => 1,
//                 .two => 2,
//                 .three => 3,
//             });
//             return 1;
//         }
//     }.inner;

//     lua.Zpushfunction(function, "func");
//     _ = lua.pushstring("one");
//     _ = lua.pcall(1, 1, 0);
//     try expectEqual(1, try lua.toInteger(-1));
//     lua.pop(1);

//     lua.Zpushfunction(function, "func");
//     _ = lua.pushstring("two");
//     _ = lua.pcall(1, 1, 0);
//     try expectEqual(2, try lua.toInteger(-1));
//     lua.pop(1);

//     lua.Zpushfunction(function, "func");
//     _ = lua.pushstring("three");
//     _ = lua.pcall(1, 1, 0);
//     try expectEqual(3, try lua.toInteger(-1));
//     lua.pop(1);

//     // try the default now
//     lua.Zpushfunction(function, "func");
//     _ = lua.pcall(0, 1, 0);
//     try expectEqual(1, try lua.toInteger(-1));
//     lua.pop(1);

//     // check the raised error
//     lua.Zpushfunction(function, "func");
//     _ = lua.pushstring("unknown");
//     try expectError(error.Runtime, lua.pcall(1, 1, 0));
//     try expectStringContains("(invalid option 'unknown')", try lua.toString(-1));
// }

test "ref luau" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.pushnil();
    try expectEqual(null, lua.ref(1));
    try expectEqual(1, lua.gettop());

    // In luau lua.ref does not pop the item from the stack
    // and the data is stored in the REGISTRYINDEX by default
    _ = lua.pushstring("Hello there");
    const ref = lua.ref(2) orelse @panic("bad");

    _ = lua.rawgeti(luau.VM.lua.REGISTRYINDEX, ref);
    try expectEqualStrings("Hello there", lua.tostring(-1) orelse @panic("bad"));

    lua.unref(ref);
}

test "args and errors" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const argCheck = struct {
        fn inner(l: *State) i32 {
            l.Largcheck(false, 1, "error!");
            return 0;
        }
    }.inner;

    lua.Zpushfunction(argCheck, "ArgCheck");
    try expectError(error.Runtime, lua.pcall(0, 0, 0).check());

    const raisesError = struct {
        fn inner(l: *State) i32 {
            l.LerrorL("some error {s}!", .{"zig"});
            unreachable;
        }
    }.inner;

    lua.Zpushfunction(raisesError, "Error");
    try expectError(error.Runtime, lua.pcall(0, 0, 0).check());
    try expectEqualStrings("some error zig!", lua.tostring(-1) orelse @panic("bad"));

    const raisesFmtError = struct {
        fn inner(l: *State) !i32 {
            l.LerrorL("some fmt error {s}!", .{"zig"});
            unreachable;
        }
    }.inner;

    lua.Zpushfunction(raisesFmtError, "ErrorFmt");
    try expectError(error.Runtime, lua.pcall(0, 0, 0).check());
    try expectEqualStrings("some fmt error zig!", lua.tostring(-1) orelse @panic("bad"));

    const FmtError = struct {
        fn inner(l: *State) !i32 {
            return l.Zerrorf("some err fmt error {s}!", .{"zig"});
        }
    }.inner;

    lua.Zpushfunction(FmtError, "ErrorFmt");
    try expectError(error.Runtime, lua.pcall(0, 0, 0).check());
    try expectEqualStrings("some err fmt error zig!", lua.tostring(-1) orelse @panic("bad"));

    const Error = struct {
        fn inner(l: *State) !i32 {
            return l.Zerror("some error");
        }
    }.inner;

    lua.Zpushfunction(Error, "Error");
    try expectError(error.Runtime, lua.pcall(0, 0, 0).check());
    try expectEqualStrings("some error", lua.tostring(-1) orelse @panic("bad"));
}

test "objectLen" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    _ = lua.pushstring("lua");
    try testing.expectEqual(3, lua.objlen(-1));
}

test "compile and run bytecode" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();
    lua.Lopenlibs();

    // Load bytecode
    const src = "return 133";
    const bc = try luau.compile(testing.allocator, src, luau.CompileOptions{});
    defer testing.allocator.free(bc);

    try lua.load("...", bc, 0);
    _ = lua.pcall(0, 1, 0);
    const v = lua.tointeger(-1) orelse @panic("bad");
    try expectEqual(133, v);

    // Try mutable globals.  Calls to mutable globals should produce longer bytecode.
    const src2 = "Foo.print()\nBar.print()";
    const bc1 = try luau.compile(testing.allocator, src2, luau.CompileOptions{});
    defer testing.allocator.free(bc1);

    const options = luau.CompileOptions{
        .mutable_globals = &[_:null]?[*:0]const u8{ "Foo", "Bar" },
    };
    const bc2 = try luau.compile(testing.allocator, src2, options);
    defer testing.allocator.free(bc2);
    // A really crude check for changed bytecode.  Better would be to match
    // produced bytecode in text format, but the API doesn't support it.
    try expect(bc1.len < bc2.len);
}

const DataDtor = struct {
    gc_hits_ptr: *i32,

    pub fn dtor(self: *DataDtor) void {
        self.gc_hits_ptr.* = self.gc_hits_ptr.* + 1;
    }
};

test "userdata dtor" {
    var gc_hits: i32 = 0;

    // create a Luau-owned pointer to a Data, configure Data with a destructor.
    {
        var lua = try luau.init(&testing.allocator);
        defer lua.deinit();

        var data = lua.newuserdatadtor(DataDtor, DataDtor.dtor);
        data.gc_hits_ptr = &gc_hits;
        try expectEqual(@as(*anyopaque, @ptrCast(data)), lua.topointer(1) orelse @panic("bad"));
        try expectEqual(0, gc_hits);
        lua.pop(1); // don't let the stack hold a ref to the user data
        _ = lua.gc(.Collect, 0);
        try expectEqual(1, gc_hits);
        _ = lua.gc(.Collect, 0);
        try expectEqual(1, gc_hits);
    }
}

fn vectorCtor(l: *State) i32 {
    const x = l.tonumber(1) orelse 0;
    const y = l.tonumber(2) orelse 0;
    const z = l.tonumber(3) orelse 0;
    if (luau.luau_vector_size == 4) {
        const w = l.optNumber(4, 0);
        l.pushVector(@floatCast(x), @floatCast(y), @floatCast(z), @floatCast(w));
    } else {
        l.pushVector(@floatCast(x), @floatCast(y), @floatCast(z));
    }
    return 1;
}

fn foo(a: i32, b: i32) i32 {
    return a + b;
}

fn bar(a: i32, b: i32) !i32 {
    if (a > b) return error.wrong;
    return a + b;
}

test "debug stacktrace" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const stackTrace = struct {
        fn inner(l: *State) i32 {
            l.pushstring(l.debugtrace());
            return 1;
        }
    }.inner;
    lua.Zpushfunction(stackTrace, "test");
    _ = lua.pcall(0, 1, 0);
    try expectEqualStrings("[C] function test\n", lua.tostring(-1) orelse @panic("bad"));
}

test "debug stacktrace luau" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const src =
        \\function MyFunction()
        \\  return stack()
        \\end
        \\
        \\return MyFunction()
        \\
    ;

    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
    });
    defer testing.allocator.free(bc);

    const stackTrace = struct {
        fn inner(l: *State) i32 {
            l.pushstring(l.debugtrace());
            return 1;
        }
    }.inner;
    lua.Zpushfunction(stackTrace, "stack");
    lua.setglobal("stack");

    try lua.load("module", bc, 0);
    _ = lua.pcall(0, 1, 0); // CALL main()

    try expectEqualStrings(
        \\[C] function stack
        \\[string "module"]:2 function MyFunction
        \\[string "module"]:5
        \\
    , lua.tostring(-1) orelse @panic("bad"));
}

test "buffers" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openbase();
    lua.openbuffer();

    const buf = lua.newbuffer(12);
    lua.Zpushbuffer("Hello, world 2");

    try expectEqual(12, buf.len);

    @memcpy(buf, "Hello, world");

    try expect(lua.isbuffer(-1));
    try expectEqualStrings("Hello, world", buf);
    try expectEqualStrings("Hello, world", lua.tobuffer(-2) orelse @panic("bad"));
    try expectEqualStrings("Hello, world 2", lua.tobuffer(-1) orelse @panic("bad"));

    const src =
        \\function MyFunction(buf, buf2)
        \\  assert(buffer.tostring(buf) == "Hello, world")
        \\  assert(buffer.tostring(buf2) == "Hello, world 2")
        \\  local newBuf = buffer.create(4);
        \\  buffer.writeu8(newBuf, 0, 82)
        \\  buffer.writeu8(newBuf, 1, 101)
        \\  buffer.writeu8(newBuf, 2, 115)
        \\  buffer.writeu8(newBuf, 3, 116)
        \\  return newBuf
        \\end
        \\
        \\return MyFunction
        \\
    ;

    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
    });
    defer testing.allocator.free(bc);

    try lua.load("module", bc, 0);
    _ = lua.pcall(0, 1, 0); // CALL main()

    lua.pushvalue(-3);
    lua.pushvalue(-3);
    _ = lua.pcall(2, 1, 0); // CALL MyFunction(buf)

    const newBuf = lua.Lcheckbuffer(-1);
    try expectEqual(4, newBuf.len);
    try expectEqualStrings("Rest", newBuf);
}

test "Set Api" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openbase();
    lua.openstring();

    const vectorFn = struct {
        fn inner(l: *State) i32 {
            const x: f32 = @floatCast(l.Loptnumber(1, 0.0));
            const y: f32 = @floatCast(l.Loptnumber(2, 0.0));
            const z: f32 = @floatCast(l.Loptnumber(3, 0.0));

            if (luau.VECTOR_SIZE == 3) {
                l.pushvector(x, y, z, null);
            } else {
                const w: f32 = @floatCast(l.Loptnumber(4, 0.0));
                l.pushvector(x, y, z, w);
            }

            return 1;
        }
    }.inner;
    lua.Zsetglobalc("vector", vectorFn);

    const src =
        \\function MyFunction(api)
        \\  assert(type(api.a) == "function"); api.a()
        \\  assert(type(api.b) == "boolean" and api.b == true);
        \\  assert(type(api.c) == "number" and api.c == 1.1);
        \\  assert(type(api.d) == "number" and api.d == 2);
        \\  assert(type(api.e) == "string" and api.e == "Api");
        \\  assert(type(api.f) == "string" and api.f == string.char(65, 0, 66) and api.f ~= "AB" and #api.f == 3);
        \\  assert(type(api.pos) == "vector" and api.pos.X == 1 and api.pos.Y == 2 and api.pos.Z == 3);
        \\
        \\  assert(type(_a) == "function"); _a()
        \\  assert(type(_b) == "boolean" and _b == true);
        \\  assert(type(_c) == "number" and _c == 1.1);
        \\  assert(type(_d) == "number" and _d == 2);
        \\  assert(type(_e) == "string" and _e == "Api");
        \\  assert(type(_f) == "string" and _f == string.char(65, 0, 66) and _f ~= "AB" and #_f == 3);
        \\  assert(type(_pos) == "vector" and _pos.X == 1 and _pos.Y == 2 and _pos.Z == 3);
        \\  
        \\  assert(type(gl_a) == "function"); gl_a()
        \\  assert(type(gl_b) == "boolean" and gl_b == true);
        \\  assert(type(gl_c) == "number" and gl_c == 1.1);
        \\  assert(type(gl_d) == "number" and gl_d == 2);
        \\  assert(type(gl_e) == "string" and gl_e == "Api");
        \\  assert(type(gl_f) == "string" and gl_f == string.char(65, 0, 66) and gl_f ~= "AB" and #gl_f == 3);
        \\  assert(type(gl_pos) == "vector" and gl_pos.X == 1 and gl_pos.Y == 2 and gl_pos.Z == 3);
        \\end
        \\
        \\return MyFunction
        \\
    ;

    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
        .optimization_level = 0,
        .vector_ctor = "vector",
        .vector_type = "vector",
    });
    defer testing.allocator.free(bc);

    const tempFn = struct {
        fn inner(l: *State) i32 {
            _ = l.getglobal("count");
            l.pushinteger((l.tointeger(-1) orelse 0) + 1);
            l.setglobal("count");
            return 0;
        }
    }.inner;
    lua.newtable();
    lua.Zsetfieldc(-1, "a", tempFn);
    lua.Zsetfield(-1, "b", true);
    lua.Zsetfield(-1, "c", 1.1);
    lua.Zsetfield(-1, "d", 2);
    lua.Zsetfield(-1, "e", "Api");
    lua.Zsetfield(-1, "f", &[_]u8{ 'A', 0, 'B' });
    if (luau.VECTOR_SIZE == 3) {
        lua.Zsetfield(-1, "pos", @Vector(3, f32){ 1.0, 2.0, 3.0 });
    } else {
        lua.Zsetfield(-1, "pos", @Vector(4, f32){ 1.0, 2.0, 3.0, 4.0 });
    }

    lua.Zsetfieldc(luau.VM.lua.GLOBALSINDEX, "_a", tempFn);
    lua.Zsetfield(luau.VM.lua.GLOBALSINDEX, "_b", true);
    lua.Zsetfield(luau.VM.lua.GLOBALSINDEX, "_c", @as(f64, 1.1));
    lua.Zsetfield(luau.VM.lua.GLOBALSINDEX, "_d", @as(i32, 2));
    lua.Zsetfield(luau.VM.lua.GLOBALSINDEX, "_e", "Api");
    lua.Zsetfield(luau.VM.lua.GLOBALSINDEX, "_f", &[_]u8{ 'A', 0, 'B' });
    if (luau.VECTOR_SIZE == 3) {
        lua.Zsetfield(luau.VM.lua.GLOBALSINDEX, "_pos", @Vector(3, f32){ 1.0, 2.0, 3.0 });
    } else {
        lua.Zsetfield(luau.VM.lua.GLOBALSINDEX, "_pos", @Vector(4, f32){ 1.0, 2.0, 3.0, 4.0 });
    }

    lua.Zsetglobalc("gl_a", tempFn);
    lua.Zsetglobal("gl_b", true);
    lua.Zsetglobal("gl_c", 1.1);
    lua.Zsetglobal("gl_d", 2);
    lua.Zsetglobal("gl_e", "Api");
    lua.Zsetglobal("gl_f", &[_]u8{ 'A', 0, 'B' });
    if (luau.VECTOR_SIZE == 3) {
        lua.Zsetglobal("gl_pos", @Vector(3, f32){ 1.0, 2.0, 3.0 });
    } else {
        lua.Zsetglobal("gl_pos", @Vector(4, f32){ 1.0, 2.0, 3.0, 4.0 });
    }

    try lua.load("module", bc, 0);
    _ = lua.pcall(0, 1, 0); // CALL main()

    lua.pushvalue(-2);
    switch (try lua.pcall(1, 1, 0).check()) {
        .Ok => {},
        .Yield => std.debug.panic("unexpected yield\n", .{}),
        .Break => std.debug.panic("unexpected break\n", .{}),
        else => unreachable,
    }

    _ = lua.getglobal("count");
    try expectEqual(3, lua.tointeger(-1) orelse @panic("bad"));
}

test "Vectors" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openbase();
    lua.openstring();
    lua.openmath();

    const vectorFn = struct {
        fn inner(l: *State) i32 {
            const x: f32 = @floatCast(l.Loptnumber(1, 0.0));
            const y: f32 = @floatCast(l.Loptnumber(2, 0.0));
            const z: f32 = @floatCast(l.Loptnumber(3, 0.0));

            if (luau.VECTOR_SIZE == 3) {
                l.pushvector(x, y, z, null);
            } else {
                const w: f32 = @floatCast(l.Loptnumber(4, 0.0));
                l.pushvector(x, y, z, w);
            }

            return 1;
        }
    }.inner;

    const src =
        \\function MyFunction()
        \\  local vec = vector(0, 1.1, 2.2);
        \\  assert(type(vec) == "vector")
        \\  assert(vec.X == 0);
        \\  assert(math.round(vec.Y*100)/100 == 1.1); -- 1.100000023841858
        \\  assert(math.round(vec.Z*100)/100 == 2.2); -- 2.200000047683716
        \\  return vec
        \\end
        \\
        \\return MyFunction()
        \\
    ;

    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
        .optimization_level = 0,
        .vector_ctor = "vector",
        .vector_type = "vector",
    });
    defer testing.allocator.free(bc);

    lua.Zsetglobalc("vector", vectorFn);

    try lua.load("module", bc, 0);
    _ = lua.pcall(0, 1, 0); // CALL main()

    try expect(lua.isvector(-1));
    const vec = lua.tovector(-1) orelse @panic("bad");
    try expectEqual(luau.VECTOR_SIZE, vec.len);
    try expectEqual(0.0, vec[0]);
    try expectEqual(1.1, vec[1]);
    try expectEqual(2.2, vec[2]);
    if (luau.VECTOR_SIZE == 4) {
        try expectEqual(0.0, vec[3]);
    }

    if (luau.VECTOR_SIZE == 3) {
        lua.pushvector(0.0, 1.0, 0.0, null);
    } else {
        lua.pushvector(0.0, 1.0, 0.0, 0.0);
    }
    const vec2 = lua.Lcheckvector(-1);
    try expectEqual(luau.VECTOR_SIZE, vec2.len);
    try expectEqual(0.0, vec2[0]);
    try expectEqual(1.0, vec2[1]);
    try expectEqual(0.0, vec2[2]);
    if (luau.VECTOR_SIZE == 4) {
        try expectEqual(0.0, vec2[3]);
    }
}

test "Luau JIT/CodeGen" {
    // Skip this test if the Luau NCG is not supported on machine
    if (!luau.CodeGen.Supported())
        return error.SkipZigTest;

    var lua = try luau.init(&std.testing.allocator);
    defer lua.deinit();
    luau.CodeGen.Create(lua);

    lua.openbase();

    lua.Zsetglobalc("test", struct {
        fn inner(L: *State) !i32 {
            L.pushboolean(L.Gisnative(@intCast(L.Loptinteger(1, 0))));
            return 1;
        }
    }.inner);

    const src =
        \\
        \\local function func(): ()
        \\  assert(native == test())
        \\  return
        \\end
        \\
        \\pcall(func)
        \\
    ;
    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
        .optimization_level = 2,
    });
    defer testing.allocator.free(bc);

    try lua.load("module", bc, 0);

    luau.CodeGen.Compile(lua, -1);

    _ = lua.pcall(0, 0, 0); // CALL main()
}

test "Readonly table" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.newtable();
    lua.setreadonly(-1, true);
    lua.setglobal("List");

    const src =
        \\List[1] = "test"
    ;
    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
        .optimization_level = 2,
    });
    defer testing.allocator.free(bc);

    try lua.load("module", bc, 0);

    try expectError(error.Runtime, lua.pcall(0, 0, 0).check()); // CALL main()
}

test "Metamethods" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.Lopenlibs();

    _ = lua.Lnewmetatable("MyMetatable");

    lua.Zsetfieldc(-1, luau.Metamethods.index, struct {
        fn inner(l: *State) i32 {
            l.Lchecktype(1, .Table);
            const key = l.tostring(2) orelse unreachable;
            expectEqualStrings("test", key) catch unreachable;
            l.pushstring("Hello, world");
            return 1;
        }
    }.inner);

    lua.Zsetfieldc(-1, luau.Metamethods.tostring, struct {
        fn inner(l: *State) i32 {
            l.Lchecktype(1, .Table);
            l.pushstring("MyMetatable");
            return 1;
        }
    }.inner);

    lua.newtable();
    lua.pushvalue(-2);
    _ = lua.setmetatable(-2);

    try expectEqual(.String, lua.getfield(-1, "test"));
    try expectEqualStrings("Hello, world", lua.tostring(-1) orelse @panic("bad"));
    lua.pop(1);

    try expectEqual(.Function, lua.getglobal("tostring"));
    lua.pushvalue(-2);
    _ = lua.pcall(1, 1, 0);
    try expectEqualStrings("MyMetatable", lua.tostring(-1) orelse @panic("bad"));
    lua.pop(1);
}

test "Zig Error Fn Lua Handled" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const zigEFn = struct {
        fn inner(_: *State) !i32 {
            return error.Fail;
        }
    }.inner;

    lua.Zpushfunction(zigEFn, "zigEFn");
    try expectEqual(error.Runtime, lua.pcall(0, 0, 0).check());
    try expectEqualStrings("Fail", lua.tostring(-1).?);
}

test "getfieldObject" {
    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    lua.Lopenlibs();

    lua.newtable();
    lua.Zsetfield(-1, "test", true);
    lua.Zsetglobal("some", "Value");

    // switch (try lua.getfieldObj(-1, "test")) {
    //     .boolean => |b| try expectEqual(true, b),
    //     else => @panic("Failed"),
    // }

    // switch (try lua.getglobalObj("some")) {
    //     .string => |s| try expectEqualStrings("Value", s),
    //     else => @panic("Failed"),
    // }

    // _ = lua.newbuffer(2);
    // lua.pushnil();
    // switch (try lua.typeOfObj(-2)) {
    //     .buffer => |buf| try expectEqualStrings(&[_]u8{ 0, 0 }, buf),
    //     else => @panic("Failed"),
    // }
    // lua.pop(1);

    // switch (try lua.typeOfObj(-1)) {
    //     .nil => {},
    //     else => @panic("Failed"),
    // }
    // try expectEqual(.nil, lua.typeOf(-1)); // should not be consumed
    // try expectEqual(.nil, lua.typeOf(-2)); // should not be consumed
    // try expectEqual(.buffer, lua.typeOf(-3));
    // lua.pop(2);

    // lua.pushnumber(1.2);
    // switch (try lua.typeOfObj(-1)) {
    //     .number => |n| {
    //         // can leak if not handled, stack grows
    //         try expectEqual(1.2, n);
    //     },
    //     else => @panic("Failed"),
    // }
    // try expectEqual(.number, lua.typeOf(-1)); // should not be consumed
    // try expectEqual(.number, lua.typeOf(-2)); // should not be consumed
    // try expectEqual(.buffer, lua.typeOf(-3));

    // switch (try lua.typeOfObjConsumed(-1)) {
    //     .number => |n| {
    //         // pops automatically with value
    //         try expectEqual(1.2, n);
    //     },
    //     else => @panic("Failed"),
    // }
    // // should be consumed
    // try expectEqual(.number, lua.typeOf(-1)); // should not be consumed
    // try expectEqual(.number, lua.typeOf(-2)); // should not be consumed
    // try expectEqual(.buffer, lua.typeOf(-3));
    // lua.pop(2);

    // const res = try lua.typeOfObj(-1);
    // if (res == .buffer) {
    //     try expectEqualStrings(&[_]u8{ 0, 0 }, res.buffer);
    // } else @panic("Failed");
}

test "SetFlags" {
    const allocator = testing.allocator;
    try expectError(error.UnknownFlag, luau.Flags.setBoolean("someunknownflag", true));
    try expectError(error.UnknownFlag, luau.Flags.setInteger("someunknownflag", 1));

    try expectError(error.UnknownFlag, luau.Flags.getBoolean("someunknownflag"));
    try expectError(error.UnknownFlag, luau.Flags.getInteger("someunknownflag"));

    const flags = try luau.Flags.getFlags(allocator);
    defer flags.deinit();
    for (flags.flags) |flag| {
        try expect(flag.name.len > 0);

        switch (flag.type) {
            .boolean => {
                const current = try luau.Flags.getBoolean(flag.name);
                try luau.Flags.setBoolean(flag.name, !current);
                try expectEqual(!current, try luau.Flags.getBoolean(flag.name));
                try luau.Flags.setBoolean(flag.name, current);
            },
            .integer => {
                const current = try luau.Flags.getInteger(flag.name);
                try luau.Flags.setInteger(flag.name, current - 1);
                try expectEqual(current - 1, try luau.Flags.getInteger(flag.name));
                try luau.Flags.setInteger(flag.name, current);
            },
        }
    }
}

test "State getInfo" {
    var lua = try luau.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openbase();

    const src =
        \\function MyFunction()
        \\  func()
        \\end
        \\
        \\MyFunction()
    ;
    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
        .optimization_level = 2,
    });
    defer testing.allocator.free(bc);

    lua.Zsetglobalc("func", struct {
        fn inner(L: *State) !i32 {
            var ar: luau.VM.lua.Debug = .{ .ssbuf = undefined };
            try expect(L.getinfo(1, "snl", &ar));
            try expect(ar.what == .lua);
            try std.testing.expectEqualSentinel(u8, 0, "MyFunction", ar.name orelse @panic("Failed"));
            try std.testing.expectEqualStrings("[string \"module\"]", ar.short_src orelse @panic("Failed"));
            try expect(ar.linedefined.? == 1);
            return 1;
        }
    }.inner);

    try lua.load("module", bc, 0);

    _ = lua.pcall(0, 1, 0); // CALL main()
}

test "yielding error" {
    {
        var lua = try luau.init(&testing.allocator);
        defer lua.deinit();

        lua.openbase();
        lua.opencoroutine();

        const src =
            \\local ok, res = pcall(foo)
            \\assert(not ok)
            \\assert(res == "error")
        ;
        const bc = try luau.compile(testing.allocator, src, .{
            .debug_level = 2,
            .optimization_level = 2,
        });
        defer testing.allocator.free(bc);

        lua.Zsetglobalc("foo", struct {
            fn inner(L: *State) !i32 {
                return L.yield(0);
            }
        }.inner);

        try lua.load("module", bc, 0);

        try expectEqual(.Yield, lua.resumethread(lua, 0));

        lua.pushstring("error");
        try expectEqual(.Ok, lua.resumeerror(lua));
    }

    {
        var lua = try luau.init(&testing.allocator);
        defer lua.deinit();

        lua.openbase();
        lua.opencoroutine();

        const src =
            \\local ok, res = pcall(foo)
            \\assert(not ok)
            \\assert(res == "fmt error 10")
        ;
        const bc = try luau.compile(testing.allocator, src, .{
            .debug_level = 2,
            .optimization_level = 2,
        });
        defer testing.allocator.free(bc);

        lua.Zsetglobalc("foo", struct {
            fn inner(L: *State) !i32 {
                return L.yield(0);
            }
        }.inner);

        try lua.load("module", bc, 0);

        try expectEqual(.Yield, lua.resumethread(lua, 0));
        try expectEqual(.Ok, lua.Zresumeferror(lua, "fmt error {d}", .{10}));
    }
}

test "Ast/Parser - HotComments" {
    const allocator = testing.allocator;

    const src =
        \\--!HotComments
        \\--!optimize 2
    ;

    const luau_allocator = luau.Ast.Allocator.Allocator.init();
    defer luau_allocator.deinit();

    const names = luau.Ast.Lexer.AstNameTable.init(luau_allocator);
    defer names.deinit();

    const result = luau.Ast.Parser.parse(src, names, luau_allocator);
    defer result.deinit();

    const hotcomments = try result.getHotcomments(allocator);
    defer hotcomments.deinit();

    try expectEqual(2, hotcomments.values.len);

    try expectEqualStrings("HotComments", hotcomments.values[0].content);
    try expectEqualStrings("optimize 2", hotcomments.values[1].content);
}

test "Thread Data" {
    const Sample = struct {
        a: i32,
        b: i32,
    };

    var lua = try luau.init(&testing.allocator);
    defer lua.deinit();

    const zigFn = struct {
        fn inner(L: *State) !i32 {
            const data = L.getthreaddata(*Sample); // should exists
            try expectEqual(10, data.a);
            try expectEqual(20, data.b);
            return 0;
        }
    }.inner;

    var data = Sample{ .a = 10, .b = 20 };
    lua.setthreaddata(*Sample, &data);

    lua.Zpushfunction(zigFn, "zigFn");
    try expectEqual(.Ok, lua.pcall(0, 0, 0));
}
