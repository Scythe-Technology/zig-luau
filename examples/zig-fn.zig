//! Registering a Zig function to be called from Lua

const std = @import("std");
const luau = @import("luau");

// It can be convenient to store a short reference to the Lua struct when
// it is used multiple times throughout a file.
const lua_State = luau.VM.lua.State;

// A Zig function called by Lua must accept a single *Lua parameter and must return an i32.
// This is the Zig equivalent of the lua_CFunction typedef int (*lua_CFunction) (lua_State *L) in the C API
fn adder(L: *lua_State) i32 {
    const a = L.tointeger(1) orelse 0;
    const b = L.tointeger(2) orelse 0;
    L.pushinteger(a + b);
    return 1;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize The Lua vm and get a reference to the main thread
    //
    // Passing a Zig allocator to the Lua state requires a stable pointer
    var L = try luau.init(&allocator);
    defer L.deinit();

    // Push the adder function to the Lua stack.
    // Here we use ziglua.wrap() to convert from a Zig function to the lua_CFunction required by Lua.
    // This could be done automatically by pushFunction(), but that would require the parameter to be comptime-known.
    // The call to ziglua.wrap() is slightly more verbose, but has the benefit of being more flexible.
    L.pushfunction(adder, "add");

    // Push the arguments onto the stack
    L.pushinteger(10);
    L.pushinteger(32);

    // Call the function. It accepts 2 arguments and returns 1 value
    // We use catch unreachable because we can verify this function call will not fail
    _ = L.pcall(2, 1, 0).check() catch unreachable;

    // The result of the function call is on the stack.
    // Use toInteger to read the integer at index 1
    std.debug.print("the result: {}\n", .{L.tointeger(1).?});

    // We can also register the function to a global and run from a Lua "program"
    L.pushfunction(adder, "add");
    L.setglobal("add");

    // We need to open the base library so the global print() is available
    L.openbase();

    // Our "program" is an inline string
    const bytecode = try luau.compile(allocator,
        \\local sum = add(10, 32)
        \\print(sum)
    , .{});
    try L.load("zigfn", bytecode, 0);
    allocator.free(bytecode);
    _ = try L.pcall(0, 0, 0).check();
}
