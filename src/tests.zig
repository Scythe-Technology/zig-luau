const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const luau = @import("luau");

const AllocFn = luau.AllocFn;
const StringBuffer = luau.StringBuffer;
const DebugInfo = luau.DebugInfo;
const Luau = luau.Luau;

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
    var lua = try Luau.init(&testing.allocator);
    try expectEqual(luau.Status.ok, lua.status());
    lua.deinit();

    // attempt to initialize the Zig wrapper with no memory
    try expectError(error.Memory, Luau.init(&testing.failing_allocator));

    // use the library directly
    lua = try Luau.newState(alloc, null);
    lua.close();

    // use the library with a bad AllocFn
    try expectError(error.Memory, Luau.newState(failing_alloc, null));

    // use the auxiliary library (uses libc realloc and cannot be checked for leaks!)
    lua = try Luau.newStateLibc();
    lua.close();
}

test "alloc functions" {
    var lua = try Luau.newState(alloc, null);
    defer lua.deinit();

    // get default allocator
    var data: *anyopaque = undefined;
    try expectEqual(alloc, lua.getAllocFn(&data));
}

test "Zig allocator access" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const inner = struct {
        fn inner(l: *Luau) i32 {
            const allocator = l.allocator();

            const num = l.toInteger(1) catch unreachable;

            // Use the allocator
            const nums = allocator.alloc(i32, @intCast(num)) catch unreachable;
            defer allocator.free(nums);

            // Do something pointless to use the slice
            var sum: i32 = 0;
            for (nums, 0..) |*n, i| n.* = @intCast(i);
            for (nums) |n| sum += n;

            l.pushInteger(sum);
            return 1;
        }
    }.inner;

    lua.pushFunction(inner, "test");
    lua.pushInteger(10);
    try lua.pcall(1, 1, 0);

    try expectEqual(45, try lua.toInteger(-1));
}

test "standard library loading" {
    // open all standard libraries
    {
        var lua = try Luau.init(&testing.allocator);
        defer lua.deinit();
        lua.openLibs();
    }

    // open all standard libraries with individual functions
    // these functions are only useful if you want to load the standard
    // packages into a non-standard table
    {
        var lua = try Luau.init(&testing.allocator);
        defer lua.deinit();

        lua.openBase();
        lua.openString();
        lua.openTable();
        lua.openMath();
        lua.openOS();
        lua.openDebug();
        lua.openCoroutine();

        // lua.openUtf8();
    }
}

test "number conversion success and failure" {
    const lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    _ = lua.pushString("1234.5678");
    try expectEqual(1234.5678, try lua.toNumber(-1));

    _ = lua.pushString("1234");
    try expectEqual(1234, try lua.toInteger(-1));

    lua.pushNil();
    try expectError(error.Fail, lua.toNumber(-1));
    try expectError(error.Fail, lua.toInteger(-1));

    _ = lua.pushString("fail");
    try expectError(error.Fail, lua.toNumber(-1));
    try expectError(error.Fail, lua.toInteger(-1));
}

test "compare" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.pushNumber(1);
    lua.pushNumber(2);

    try testing.expect(!lua.equal(1, 2));
    try testing.expect(lua.lessThan(1, 2));

    lua.pushInteger(2);
    try testing.expect(lua.equal(2, 3));
}

const add = struct {
    fn addInner(l: *Luau) i32 {
        const a = l.toInteger(1) catch 0;
        const b = l.toInteger(2) catch 0;
        l.pushInteger(a + b);
        return 1;
    }
}.addInner;

test "type of and getting values" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.pushNil();
    try expect(lua.isNil(1));
    try expect(lua.isNoneOrNil(1));
    try expect(lua.isNoneOrNil(2));
    try expect(lua.isNone(2));
    try expectEqual(.nil, lua.typeOf(1));

    lua.pushBoolean(true);
    try expectEqual(.boolean, lua.typeOf(-1));
    try expect(lua.isBoolean(-1));

    lua.newTable();
    try expectEqual(.table, lua.typeOf(-1));
    try expect(lua.isTable(-1));

    lua.pushInteger(1);
    try expectEqual(.number, lua.typeOf(-1));
    try expect(lua.isNumber(-1));
    try expectEqual(1, try lua.toInteger(-1));
    try expectEqualStrings("number", lua.typeNameIndex(-1));

    lua.pushUnsigned(4);
    try expectEqual(.number, lua.typeOf(-1));
    try expect(lua.isNumber(-1));
    try expectEqual(4, try lua.toUnsigned(-1));
    try expectEqualStrings("number", lua.typeNameIndex(-1));

    var value: i32 = 0;
    lua.pushLightUserdata(&value);
    try expectEqual(.light_userdata, lua.typeOf(-1));
    try expect(lua.isLightUserdata(-1));
    try expect(lua.isUserdata(-1));

    lua.pushNumber(0.1);
    try expectEqual(.number, lua.typeOf(-1));
    try expect(lua.isNumber(-1));
    try expectEqual(0.1, try lua.toNumber(-1));

    _ = lua.pushThread();
    try expectEqual(.thread, lua.typeOf(-1));
    try expect(lua.isThread(-1));
    try expectEqual(lua, (try lua.toThread(-1)));

    lua.pushString("all your codebase are belong to us");
    try expectEqualStrings("all your codebase are belong to us", try lua.toString(-1));
    try expectEqual(.string, lua.typeOf(-1));
    try expect(lua.isString(-1));

    lua.pushFunction(add, "func");
    try expectEqual(.function, lua.typeOf(-1));
    try expect(lua.isCFunction(-1));
    try expect(lua.isFunction(-1));
    try expectEqual(luau.toCFn(add), try lua.toCFunction(-1));

    lua.pushString("hello world");
    try expectEqualStrings("hello world", try lua.toString(-1));
    try expectEqual(.string, lua.typeOf(-1));
    try expect(lua.isString(-1));

    _ = lua.pushFString("%s %s %d", .{ "hello", "world", @as(i32, 10) });
    try expectEqual(.string, lua.typeOf(-1));
    try expect(lua.isString(-1));
    try expectEqualStrings("hello world 10", try lua.toString(-1));

    // Comptime known
    try lua.pushFmtString("{s} {s} {d}", .{ "hello", "world", @as(i32, 10) });
    try expectEqual(.string, lua.typeOf(-1));
    try expect(lua.isString(-1));
    try expectEqualStrings("hello world 10", try lua.toString(-1));

    // Runtime known
    const arg1 = try std.testing.allocator.dupe(u8, "Hello");
    defer std.testing.allocator.free(arg1);
    const arg2 = try std.testing.allocator.dupe(u8, "World");
    defer std.testing.allocator.free(arg2);

    try lua.pushFmtString("{s} {s} {d}", .{ arg1, arg2, @as(i32, 10) });
    try expectEqual(.string, lua.typeOf(-1));
    try expect(lua.isString(-1));
    try expectEqualStrings("Hello World 10", try lua.toString(-1));

    lua.pushValue(2);
    try expectEqual(.boolean, lua.typeOf(-1));
    try expect(lua.isBoolean(-1));
}

test "typenames" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    try expectEqualStrings("no value", lua.typeName(.none));
    try expectEqualStrings("nil", lua.typeName(.nil));
    try expectEqualStrings("boolean", lua.typeName(.boolean));
    try expectEqualStrings("userdata", lua.typeName(.light_userdata));
    try expectEqualStrings("number", lua.typeName(.number));
    try expectEqualStrings("string", lua.typeName(.string));
    try expectEqualStrings("table", lua.typeName(.table));
    try expectEqualStrings("function", lua.typeName(.function));
    try expectEqualStrings("userdata", lua.typeName(.userdata));
    try expectEqualStrings("thread", lua.typeName(.thread));
    try expectEqualStrings("vector", lua.typeName(.vector));
    try expectEqualStrings("buffer", lua.typeName(.buffer));
}

// test "executing string contents" {
//     var lua = try Luau.init(&testing.allocator);
//     defer lua.deinit();
//     lua.openLibs();

//     try lua.loadString("f = function(x) return x + 10 end");
//     try lua.pcall(0, 0, 0);
//     try lua.loadString("a = f(2)");
//     try lua.pcall(0, 0, 0);

//     try expectEqual(.number, try lua.getGlobal("a"));
//     try expectEqual(12, try lua.toInteger(1));

//     try expectError(error.Fail, lua.loadString("bad syntax"));
//     try lua.loadString("a = g()");
//     try expectError(error.Runtime, lua.pcall(0, 0, 0));
// }

test "filling and checking the stack" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    try expectEqual(0, lua.getTop());

    // We want to push 30 values onto the stack
    // this should work without fail
    try lua.checkStack(30);

    var count: i32 = 0;
    while (count < 30) : (count += 1) {
        lua.pushNil();
    }

    try expectEqual(30, lua.getTop());

    // this should fail (beyond max stack size)
    try expectError(error.Fail, lua.checkStack(1_000_000));

    // this is small enough it won't fail (would raise an error if it did)
    lua.checkStackErr(40, null);
    while (count < 40) : (count += 1) {
        lua.pushNil();
    }

    try expectEqual(40, lua.getTop());
}

test "stack manipulation" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    var num: i32 = 1;
    while (num <= 10) : (num += 1) {
        lua.pushInteger(num);
    }
    try expectEqual(10, lua.getTop());

    lua.setTop(12);
    try expectEqual(12, lua.getTop());
    try expect(lua.isNil(-1));

    lua.remove(1);
    try expect(lua.isNil(-1));

    lua.insert(1);
    try expect(lua.isNil(1));

    lua.setTop(0);
    try expectEqual(0, lua.getTop());
}

test "calling a function" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.register("zigadd", add);

    _ = lua.getGlobal("zigadd");
    lua.pushInteger(10);
    lua.pushInteger(32);

    // pcall is preferred, but we might as well test call when we know it is safe
    lua.call(2, 1);
    try expectEqual(42, try lua.toInteger(1));
}

test "string buffers" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    var buffer: StringBuffer = undefined;
    buffer.init(lua);

    buffer.addChar('z');
    buffer.addString("igl");

    var str = buffer.prep();
    str[0] = 'u';
    str[1] = 'a';
    str[2] = 'u';
    buffer.addSize(3);

    buffer.addString(" api ");
    lua.pushNumber(5.1);
    buffer.addValue();
    buffer.pushResult();
    try expectEqualStrings("zigluau api 5.1", try lua.toString(-1));

    // now test a small buffer
    buffer.init(lua);
    var b = buffer.prep();
    b[0] = 'a';
    b[1] = 'b';
    b[2] = 'c';
    buffer.addSize(3);

    b = buffer.prep();
    @memcpy(b[0..23], "defghijklmnopqrstuvwxyz");
    buffer.addSize(23);
    buffer.pushResult();
    try expectEqualStrings("abcdefghijklmnopqrstuvwxyz", try lua.toString(-1));
    lua.pop(1);

    buffer.init(lua);
    b = buffer.prep();
    @memcpy(b[0..3], "abc");
    buffer.pushResultSize(3);
    try expectEqualStrings("abc", try lua.toString(-1));
    lua.pop(1);
}

const sub = struct {
    fn subInner(l: *Luau) i32 {
        const a = l.toInteger(1) catch 0;
        const b = l.toInteger(2) catch 0;
        l.pushInteger(a - b);
        return 1;
    }
}.subInner;

test "function registration" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const funcs = [_]luau.FnReg{
        .{ .name = "add", .func = luau.toCFn(add) },
    };
    lua.newTable();
    lua.registerFns(null, &funcs);

    _ = lua.getField(-1, "add");
    lua.pushInteger(1);
    lua.pushInteger(2);
    try lua.pcall(2, 1, 0);
    try expectEqual(3, lua.toInteger(-1));
    lua.setTop(0);

    // register functions as globals in a library table
    lua.registerFns("testlib", &funcs);

    // testlib.add(1, 2)
    _ = lua.getGlobal("testlib");
    _ = lua.getField(-1, "add");
    lua.pushInteger(1);
    lua.pushInteger(2);
    try lua.pcall(2, 1, 0);
    try expectEqual(3, lua.toInteger(-1));
}

test "warn fn" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const warnFn = struct {
        fn inner(L: *Luau) void {
            const msg = L.toString(1) catch unreachable;
            if (!std.mem.eql(u8, msg, "this will be caught by the warnFn"))
                std.debug.panic("test failed", .{});
        }
    }.inner;

    lua.pushFunction(warnFn, "newWarn");
    lua.pushValue(-1);
    lua.setField(luau.GLOBALSINDEX, "warn");
    lua.pushString("this will be caught by the warnFn");
    lua.call(1, 0);
}

test "string literal" {
    const allocator = testing.allocator;
    var lua = try Luau.init(&allocator);
    defer lua.deinit();

    const zbytes = [_:0]u8{ 'H', 'e', 'l', 'l', 'o', ' ', 0, 'W', 'o', 'r', 'l', 'd' };
    try testing.expectEqual(zbytes.len, 12);

    lua.pushString(&zbytes);
    const str1 = try lua.toString(-1);
    try testing.expectEqual(str1.len, 6);
    try testing.expectEqualStrings("Hello ", str1);

    lua.pushLString(&zbytes);
    const str2 = try lua.toString(-1);
    try testing.expectEqual(str2.len, 12);
    try testing.expectEqualStrings(&zbytes, str2);
}

test "concat" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    _ = lua.pushString("hello ");
    lua.pushNumber(10);
    _ = lua.pushString(" wow!");
    lua.concat(3);

    try expectEqualStrings("hello 10 wow!", try lua.toString(-1));
}

test "garbage collector" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    // because the garbage collector is an opaque, unmanaged
    // thing, it is hard to test, so just run each function
    lua.gcStop();
    lua.gcCollect();
    lua.gcRestart();
    _ = lua.gcCount();
    _ = lua.gcCountB();

    _ = lua.gcIsRunning();
    lua.gcStep();

    _ = lua.gcSetGoal(10);
    _ = lua.gcSetStepMul(2);
    _ = lua.gcSetStepSize(1);
}

test "threads" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    var new_thread = lua.newThread();

    try expectEqual(1, lua.getTop());
    try expectEqual(0, new_thread.getTop());

    lua.pushInteger(10);
    lua.pushNil();

    try expectEqual(3, lua.getTop());

    lua.xMove(new_thread, 2);

    try expectEqual(2, new_thread.getTop());
    try expectEqual(1, lua.getTop());

    var new_thread2 = lua.newThread();

    try expectEqual(2, lua.getTop());
    try expectEqual(0, new_thread2.getTop());

    lua.pushNil();

    lua.xPush(new_thread2, -1);

    try expectEqual(3, lua.getTop());
    try expectEqual(1, new_thread2.getTop());
    try expectEqual(.nil, new_thread2.typeOf(1));
}

test "userdata and uservalues" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const Data = struct {
        val: i32,
        code: [4]u8,
    };

    // create a Luau-owned pointer to a Data with 2 associated user values
    var data = lua.newUserdata(Data);
    data.val = 1;
    @memcpy(&data.code, "abcd");

    try expectEqual(data, try lua.toUserdata(Data, 1));
    try expectEqual(@as(*const anyopaque, @ptrCast(data)), try lua.toPointer(1));
}

test "upvalues" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    // counter from PIL
    const counter = struct {
        fn inner(l: *Luau) i32 {
            var counter = l.toInteger(Luau.upvalueIndex(1)) catch 0;
            counter += 1;
            l.pushInteger(counter);
            l.pushInteger(counter);
            l.replace(Luau.upvalueIndex(1));
            return 1;
        }
    }.inner;

    // Initialize the counter at 0
    lua.pushInteger(0);
    lua.pushClosure(luau.toCFn(counter), "counter", 1);
    lua.setGlobal("counter");

    // call the function repeatedly, each time ensuring the result increases by one
    var expected: i32 = 1;
    while (expected <= 10) : (expected += 1) {
        _ = lua.getGlobal("counter");
        lua.call(0, 1);
        try expectEqual(expected, try lua.toInteger(-1));
        lua.pop(1);
    }
}

test "raise error" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const makeError = struct {
        fn inner(l: *Luau) i32 {
            _ = l.pushString("makeError made an error");
            l.raiseError();
            return 0;
        }
    }.inner;

    lua.pushFunction(makeError, "func");
    try expectError(error.Runtime, lua.pcall(0, 0, 0));
    try expectEqualStrings("makeError made an error", try lua.toString(-1));
}

fn continuation(l: *Luau, status: luau.Status, ctx: isize) i32 {
    _ = status;

    if (ctx == 5) {
        _ = l.pushString("done");
        return 1;
    } else {
        // yield the current context value
        l.pushInteger(ctx);
        return l.yieldCont(1, ctx + 1, luau.wrap(continuation));
    }
}

fn continuation52(l: *Luau) i32 {
    const ctxOrNull = l.getContext() catch unreachable;
    const ctx = ctxOrNull orelse 0;
    if (ctx == 5) {
        _ = l.pushString("done");
        return 1;
    } else {
        // yield the current context value
        l.pushInteger(ctx);
        return l.yieldCont(1, ctx + 1, luau.wrap(continuation52));
    }
}

test "yielding no continuation" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    var thread = lua.newThread();
    const func = struct {
        fn inner(l: *Luau) i32 {
            l.pushInteger(1);
            return l.yield(1);
        }
    }.inner;
    thread.pushFunction(func, "func");

    try expectEqual(.suspended, lua.statusThread(thread));

    _ = try thread.resumeThread(null, 0);

    try expectEqual(.suspended, lua.statusThread(thread));
    try expectEqual(1, thread.toInteger(-1));
    thread.resetThread();
    try expect(thread.isThreadReset());
    try expectEqual(.finished, lua.statusThread(thread));
}

test "aux check functions" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const function = struct {
        fn inner(l: *Luau) i32 {
            l.checkAny(1);
            _ = l.checkInteger(2);
            _ = l.checkNumber(3);
            _ = l.checkString(4);
            l.checkType(5, .boolean);
            return 0;
        }
    }.inner;

    lua.pushFunction(function, "func");
    lua.pcall(0, 0, 0) catch {
        try expectStringContains("argument #1", try lua.toString(-1));
        lua.pop(-1);
    };

    lua.pushFunction(function, "func");
    lua.pushNil();
    lua.pcall(1, 0, 0) catch {
        try expectStringContains("number expected", try lua.toString(-1));
        lua.pop(-1);
    };

    lua.pushFunction(function, "func");
    lua.pushNil();
    lua.pushInteger(3);
    lua.pcall(2, 0, 0) catch {
        try expectStringContains("string expected", try lua.toString(-1));
        lua.pop(-1);
    };

    lua.pushFunction(function, "func");
    lua.pushNil();
    lua.pushInteger(3);
    lua.pushNumber(4);
    lua.pcall(3, 0, 0) catch {
        try expectStringContains("string expected", try lua.toString(-1));
        lua.pop(-1);
    };

    lua.pushFunction(function, "func");
    lua.pushNil();
    lua.pushInteger(3);
    lua.pushNumber(4);
    _ = lua.pushString("hello world");
    lua.pcall(4, 0, 0) catch {
        try expectStringContains("boolean expected", try lua.toString(-1));
        lua.pop(-1);
    };

    lua.pushFunction(function, "func");
    // test pushFail here (currently acts the same as pushNil)
    lua.pushNil();
    lua.pushInteger(3);
    lua.pushNumber(4);
    _ = lua.pushString("hello world");
    lua.pushBoolean(true);
    try lua.pcall(5, 0, 0);
}

test "aux opt functions" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const function = struct {
        fn inner(l: *Luau) i32 {
            expectEqual(10, l.optInteger(1) orelse 10) catch unreachable;
            expectEqualStrings("zig", l.optString(2) orelse "zig") catch unreachable;
            expectEqual(1.23, l.optNumber(3) orelse 1.23) catch unreachable;
            expectEqualStrings("lang", l.optString(4) orelse "lang") catch unreachable;
            return 0;
        }
    }.inner;

    lua.pushFunction(function, "func");
    try lua.pcall(0, 0, 0);

    lua.pushFunction(function, "func");
    lua.pushInteger(10);
    _ = lua.pushString("zig");
    lua.pushNumber(1.23);
    _ = lua.pushString("lang");
    try lua.pcall(4, 0, 0);
}

test "checkOption" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const Variant = enum {
        one,
        two,
        three,
    };

    const function = struct {
        fn inner(l: *Luau) i32 {
            const option = l.checkOption(Variant, 1, .one);
            l.pushInteger(switch (option) {
                .one => 1,
                .two => 2,
                .three => 3,
            });
            return 1;
        }
    }.inner;

    lua.pushFunction(function, "func");
    _ = lua.pushString("one");
    try lua.pcall(1, 1, 0);
    try expectEqual(1, try lua.toInteger(-1));
    lua.pop(1);

    lua.pushFunction(function, "func");
    _ = lua.pushString("two");
    try lua.pcall(1, 1, 0);
    try expectEqual(2, try lua.toInteger(-1));
    lua.pop(1);

    lua.pushFunction(function, "func");
    _ = lua.pushString("three");
    try lua.pcall(1, 1, 0);
    try expectEqual(3, try lua.toInteger(-1));
    lua.pop(1);

    // try the default now
    lua.pushFunction(function, "func");
    try lua.pcall(0, 1, 0);
    try expectEqual(1, try lua.toInteger(-1));
    lua.pop(1);

    // check the raised error
    lua.pushFunction(function, "func");
    _ = lua.pushString("unknown");
    try expectError(error.Runtime, lua.pcall(1, 1, 0));
    try expectStringContains("(invalid option 'unknown')", try lua.toString(-1));
}

test "ref luau" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.pushNil();
    try expectError(error.Fail, lua.ref(1));
    try expectEqual(1, lua.getTop());

    // In luau lua.ref does not pop the item from the stack
    // and the data is stored in the REGISTRYINDEX by default
    _ = lua.pushString("Hello there");
    const ref = try lua.ref(2);

    _ = lua.rawGetIndex(luau.REGISTRYINDEX, ref);
    try expectEqualStrings("Hello there", try lua.toString(-1));

    lua.unref(ref);
}

test "args and errors" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const argCheck = struct {
        fn inner(l: *Luau) i32 {
            l.argCheck(false, 1, "error!");
            return 0;
        }
    }.inner;

    lua.pushFunction(argCheck, "ArgCheck");
    try expectError(error.Runtime, lua.pcall(0, 0, 0));

    const raisesError = struct {
        fn inner(l: *Luau) i32 {
            l.raiseErrorStr("some error %s!", .{"zig"});
            unreachable;
        }
    }.inner;

    lua.pushFunction(raisesError, "Error");
    try expectError(error.Runtime, lua.pcall(0, 0, 0));
    try expectEqualStrings("some error zig!", try lua.toString(-1));

    const raisesFmtError = struct {
        fn inner(l: *Luau) !i32 {
            try l.raiseErrorFmt("some fmt error {s}!", .{"zig"});
            unreachable;
        }
    }.inner;

    lua.pushFunction(raisesFmtError, "ErrorFmt");
    try expectError(error.Runtime, lua.pcall(0, 0, 0));
    try expectEqualStrings("some fmt error zig!", try lua.toString(-1));

    const FmtError = struct {
        fn inner(l: *Luau) !i32 {
            return l.ErrorFmt("some err fmt error {s}!", .{"zig"});
        }
    }.inner;

    lua.pushFunction(FmtError, "ErrorFmt");
    try expectError(error.Runtime, lua.pcall(0, 0, 0));
    try expectEqualStrings("some err fmt error zig!", try lua.toString(-1));

    const Error = struct {
        fn inner(l: *Luau) !i32 {
            return l.Error("some error");
        }
    }.inner;

    lua.pushFunction(Error, "Error");
    try expectError(error.Runtime, lua.pcall(0, 0, 0));
    try expectEqualStrings("some error", try lua.toString(-1));
}

test "objectLen" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    _ = lua.pushString("lua");
    try testing.expectEqual(3, lua.objLen(-1));
}

test "compile and run bytecode" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    // Load bytecode
    const src = "return 133";
    const bc = try luau.compile(testing.allocator, src, luau.CompileOptions{});
    defer testing.allocator.free(bc);

    try lua.loadBytecode("...", bc);
    try lua.pcall(0, 1, 0);
    const v = try lua.toInteger(-1);
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
        var lua = try Luau.init(&testing.allocator);
        defer lua.deinit();

        var data = lua.newUserdataDtor(DataDtor, DataDtor.dtor);
        data.gc_hits_ptr = &gc_hits;
        try expectEqual(@as(*anyopaque, @ptrCast(data)), try lua.toPointer(1));
        try expectEqual(0, gc_hits);
        lua.pop(1); // don't let the stack hold a ref to the user data
        lua.gcCollect();
        try expectEqual(1, gc_hits);
        lua.gcCollect();
        try expectEqual(1, gc_hits);
    }
}

fn vectorCtor(l: *Luau) i32 {
    const x = l.toNumber(1) catch unreachable;
    const y = l.toNumber(2) catch unreachable;
    const z = l.toNumber(3) catch unreachable;
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
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const stackTrace = struct {
        fn inner(l: *Luau) i32 {
            l.pushString(l.debugTrace());
            return 1;
        }
    }.inner;
    lua.pushFunction(stackTrace, "test");
    try lua.pcall(0, 1, 0);
    try expectEqualStrings("[C] function test\n", try lua.toString(-1));
}

test "debug stacktrace luau" {
    var lua = try Luau.init(&testing.allocator);
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
        fn inner(l: *Luau) i32 {
            l.pushString(l.debugTrace());
            return 1;
        }
    }.inner;
    lua.pushFunction(stackTrace, "stack");
    lua.setGlobal("stack");

    try lua.loadBytecode("module", bc);
    try lua.pcall(0, 1, 0); // CALL main()

    try expectEqualStrings(
        \\[C] function stack
        \\[string "module"]:2 function MyFunction
        \\[string "module"]:5
        \\
    , try lua.toString(-1));
}

test "buffers" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openBase();
    lua.openBuffer();

    const buf = lua.newBuffer(12);
    lua.pushBuffer("Hello, world 2");

    try expectEqual(12, buf.len);

    @memcpy(buf, "Hello, world");

    try expect(lua.isBuffer(-1));
    try expectEqualStrings("Hello, world", buf);
    try expectEqualStrings("Hello, world", try lua.toBuffer(-2));
    try expectEqualStrings("Hello, world 2", try lua.toBuffer(-1));

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

    try lua.loadBytecode("module", bc);
    try lua.pcall(0, 1, 0); // CALL main()

    lua.pushValue(-3);
    lua.pushValue(-3);
    try lua.pcall(2, 1, 0); // CALL MyFunction(buf)

    const newBuf = lua.checkBuffer(-1);
    try expectEqual(4, newBuf.len);
    try expectEqualStrings("Rest", newBuf);
}

test "Set Api" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openBase();
    lua.openString();

    const vectorFn = struct {
        fn inner(l: *Luau) i32 {
            const x: f32 = @floatCast(l.optNumber(1) orelse 0.0);
            const y: f32 = @floatCast(l.optNumber(2) orelse 0.0);
            const z: f32 = @floatCast(l.optNumber(3) orelse 0.0);

            if (luau.VECTOR_SIZE == 3) {
                l.pushVector(x, y, z, null);
            } else {
                const w: f32 = @floatCast(l.optNumber(4) orelse 0.0);
                l.pushVector(x, y, z, w);
            }

            return 1;
        }
    }.inner;
    lua.setGlobalFn("vector", vectorFn);

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
        fn inner(l: *Luau) i32 {
            _ = l.getGlobal("count");
            l.pushInteger((l.toInteger(-1) catch 0) + 1);
            l.setGlobal("count");
            return 0;
        }
    }.inner;
    lua.newTable();
    lua.setFieldFn(-1, "a", tempFn);
    lua.setFieldBoolean(-1, "b", true);
    lua.setFieldNumber(-1, "c", 1.1);
    lua.setFieldInteger(-1, "d", 2);
    lua.setFieldString(-1, "e", "Api");
    lua.setFieldLString(-1, "f", &[_]u8{ 'A', 0, 'B' });
    if (luau.VECTOR_SIZE == 3) {
        lua.setFieldVector(-1, "pos", 1.0, 2.0, 3.0, null);
    } else {
        lua.setFieldVector(-1, "pos", 1.0, 2.0, 3.0, 4.0);
    }

    lua.setFieldFn(luau.GLOBALSINDEX, "_a", tempFn);
    lua.setFieldBoolean(luau.GLOBALSINDEX, "_b", true);
    lua.setFieldNumber(luau.GLOBALSINDEX, "_c", 1.1);
    lua.setFieldInteger(luau.GLOBALSINDEX, "_d", 2);
    lua.setFieldString(luau.GLOBALSINDEX, "_e", "Api");
    lua.setFieldLString(luau.GLOBALSINDEX, "_f", &[_]u8{ 'A', 0, 'B' });
    if (luau.VECTOR_SIZE == 3) {
        lua.setFieldVector(luau.GLOBALSINDEX, "_pos", 1.0, 2.0, 3.0, null);
    } else {
        lua.setFieldVector(luau.GLOBALSINDEX, "_pos", 1.0, 2.0, 3.0, 4.0);
    }

    lua.setGlobalFn("gl_a", tempFn);
    lua.setGlobalBoolean("gl_b", true);
    lua.setGlobalNumber("gl_c", 1.1);
    lua.setGlobalInteger("gl_d", 2);
    lua.setGlobalString("gl_e", "Api");
    lua.setGlobalLString("gl_f", &[_]u8{ 'A', 0, 'B' });
    if (luau.VECTOR_SIZE == 3) {
        lua.setGlobalVector("gl_pos", 1.0, 2.0, 3.0, null);
    } else {
        lua.setGlobalVector("gl_pos", 1.0, 2.0, 3.0, 4.0);
    }

    try lua.loadBytecode("module", bc);
    try lua.pcall(0, 1, 0); // CALL main()

    lua.pushValue(-2);
    lua.pcall(1, 1, 0) catch {
        std.debug.panic("error: {s}\n", .{try lua.toString(-1)});
    };

    _ = lua.getGlobal("count");
    try expectEqual(3, try lua.toInteger(-1));
}

test "Vectors" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openBase();
    lua.openString();
    lua.openMath();

    const vectorFn = struct {
        fn inner(l: *Luau) i32 {
            const x: f32 = @floatCast(l.optNumber(1) orelse 0.0);
            const y: f32 = @floatCast(l.optNumber(2) orelse 0.0);
            const z: f32 = @floatCast(l.optNumber(3) orelse 0.0);

            if (luau.VECTOR_SIZE == 3) {
                l.pushVector(x, y, z, null);
            } else {
                const w: f32 = @floatCast(l.optNumber(4) orelse 0.0);
                l.pushVector(x, y, z, w);
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

    lua.setGlobalFn("vector", vectorFn);

    try lua.loadBytecode("module", bc);
    try lua.pcall(0, 1, 0); // CALL main()

    try expect(lua.isVector(-1));
    const vec = try lua.toVector(-1);
    try expectEqual(luau.VECTOR_SIZE, vec.len);
    try expectEqual(0.0, vec[0]);
    try expectEqual(1.1, vec[1]);
    try expectEqual(2.2, vec[2]);
    if (luau.VECTOR_SIZE == 4) {
        try expectEqual(0.0, vec[3]);
    }

    if (luau.VECTOR_SIZE == 3) {
        lua.pushVector(0.0, 1.0, 0.0, null);
    } else {
        lua.pushVector(0.0, 1.0, 0.0, 0.0);
    }
    const vec2 = lua.checkVector(-1);
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

    var lua = try Luau.init(&std.testing.allocator);
    defer lua.deinit();
    luau.CodeGen.Create(lua);

    lua.openBase();

    lua.setGlobalFn("test", struct {
        fn inner(L: *Luau) !i32 {
            L.pushBoolean(L.isNative(L.optInteger(1) orelse 0));
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

    try lua.loadBytecode("module", bc);

    luau.CodeGen.Compile(lua, -1);

    try lua.pcall(0, 0, 0); // CALL main()
}

test "Readonly table" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.newTable();
    lua.setReadOnly(-1, true);
    lua.setGlobal("List");

    const src =
        \\List[1] = "test"
    ;
    const bc = try luau.compile(testing.allocator, src, .{
        .debug_level = 2,
        .optimization_level = 2,
    });
    defer testing.allocator.free(bc);

    try lua.loadBytecode("module", bc);

    try expectError(error.Runtime, lua.pcall(0, 0, 0)); // CALL main()
}

test "Metamethods" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    try lua.newMetatable("MyMetatable");

    lua.setFieldFn(-1, luau.Metamethods.index, struct {
        fn inner(l: *Luau) i32 {
            l.checkType(1, .table);
            const key = l.toString(2) catch unreachable;
            expectEqualStrings("test", key) catch unreachable;
            l.pushString("Hello, world");
            return 1;
        }
    }.inner);

    lua.setFieldFn(-1, luau.Metamethods.tostring, struct {
        fn inner(l: *Luau) i32 {
            l.checkType(1, .table);
            l.pushString("MyMetatable");
            return 1;
        }
    }.inner);

    lua.newTable();
    lua.pushValue(-2);
    lua.setMetatable(-2);

    try expectEqual(.string, lua.getField(-1, "test"));
    try expectEqualStrings("Hello, world", try lua.toString(-1));
    lua.pop(1);

    try expectEqual(.function, lua.getGlobal("tostring"));
    lua.pushValue(-2);
    try lua.pcall(1, 1, 0);
    try expectEqualStrings("MyMetatable", try lua.toString(-1));
    lua.pop(1);
}

test "Zig Error Fn Lua Handled" {
    if (!EXCEPTIONS_ENABLED)
        return error.SkipZigTest;

    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const zigEFn = struct {
        fn inner(_: *Luau) !i32 {
            return error.Fail;
        }
    }.inner;

    lua.pushFunction(zigEFn, "zigEFn");
    try expectError(error.Runtime, lua.pcall(0, 0, 0));
    try expectEqualStrings("Fail", try lua.toString(-1));
}

test "getFieldObject" {
    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    lua.openLibs();

    lua.newTable();
    lua.setFieldBoolean(-1, "test", true);
    lua.setGlobalLString("some", "Value");

    switch (try lua.getFieldObj(-1, "test")) {
        .boolean => |b| try expectEqual(true, b),
        else => @panic("Failed"),
    }

    switch (try lua.getGlobalObj("some")) {
        .string => |s| try expectEqualStrings("Value", s),
        else => @panic("Failed"),
    }

    _ = lua.newBuffer(2);
    lua.pushNil();
    switch (try lua.typeOfObj(-2)) {
        .buffer => |buf| try expectEqualStrings(&[_]u8{ 0, 0 }, buf),
        else => @panic("Failed"),
    }
    lua.pop(1);

    switch (try lua.typeOfObj(-1)) {
        .nil => {},
        else => @panic("Failed"),
    }
    try expectEqual(.nil, lua.typeOf(-1)); // should not be consumed
    try expectEqual(.nil, lua.typeOf(-2)); // should not be consumed
    try expectEqual(.buffer, lua.typeOf(-3));
    lua.pop(2);

    lua.pushNumber(1.2);
    switch (try lua.typeOfObj(-1)) {
        .number => |n| {
            // can leak if not handled, stack grows
            try expectEqual(1.2, n);
        },
        else => @panic("Failed"),
    }
    try expectEqual(.number, lua.typeOf(-1)); // should not be consumed
    try expectEqual(.number, lua.typeOf(-2)); // should not be consumed
    try expectEqual(.buffer, lua.typeOf(-3));

    switch (try lua.typeOfObjConsumed(-1)) {
        .number => |n| {
            // pops automatically with value
            try expectEqual(1.2, n);
        },
        else => @panic("Failed"),
    }
    // should be consumed
    try expectEqual(.number, lua.typeOf(-1)); // should not be consumed
    try expectEqual(.number, lua.typeOf(-2)); // should not be consumed
    try expectEqual(.buffer, lua.typeOf(-3));
    lua.pop(2);

    const res = try lua.typeOfObj(-1);
    if (res == .buffer) {
        try expectEqualStrings(&[_]u8{ 0, 0 }, res.buffer);
    } else @panic("Failed");
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
    var lua = try Luau.init(&std.testing.allocator);
    defer lua.deinit();

    lua.openBase();

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

    lua.setGlobalFn("func", struct {
        fn inner(L: *Luau) !i32 {
            var ar: luau.DebugInfo = undefined;
            try expect(L.getInfo(1, .{ .s = true, .n = true, .l = true }, &ar));
            try expect(ar.what == .luau);
            try std.testing.expectEqualSentinel(u8, 0, "MyFunction", ar.name orelse @panic("Failed"));
            try std.testing.expectEqualStrings("[string \"module\"]", ar.short_src[0..ar.short_src_len]);
            try expect(ar.line_defined == 1);
            return 1;
        }
    }.inner);

    try lua.loadBytecode("module", bc);

    try lua.pcall(0, 1, 0); // CALL main()
}

test "yielding error" {
    {
        var lua = try Luau.init(&testing.allocator);
        defer lua.deinit();

        lua.openBase();
        lua.openCoroutine();

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

        lua.setGlobalFn("foo", struct {
            fn inner(L: *Luau) !i32 {
                return L.yield(0);
            }
        }.inner);

        try lua.loadBytecode("module", bc);

        try expectEqual(.yield, try lua.resumeThread(lua, 0));

        lua.pushString("error");
        try expectEqual(.ok, try lua.resumeThreadError(lua));
    }

    {
        var lua = try Luau.init(&testing.allocator);
        defer lua.deinit();

        lua.openBase();
        lua.openCoroutine();

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

        lua.setGlobalFn("foo", struct {
            fn inner(L: *Luau) !i32 {
                return L.yield(0);
            }
        }.inner);

        try lua.loadBytecode("module", bc);

        try expectEqual(.yield, try lua.resumeThread(lua, 0));
        try expectEqual(.ok, try lua.resumeThreadErrorFmt(lua, "fmt error {d}", .{10}));
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

    var lua = try Luau.init(&testing.allocator);
    defer lua.deinit();

    const zigFn = struct {
        fn inner(L: *Luau) !i32 {
            const data = L.getThreadData(Sample) catch unreachable; // should exists
            try expectEqual(10, data.a);
            try expectEqual(20, data.b);
            return 0;
        }
    }.inner;

    var data = Sample{ .a = 10, .b = 20 };
    lua.setThreadData(Sample, &data);

    lua.pushFunction(zigFn, "zigFn");
    try lua.pcall(0, 0, 0);
}
