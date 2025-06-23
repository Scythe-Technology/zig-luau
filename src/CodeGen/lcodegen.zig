const c = @import("c");

const lua = @import("../VM/lua.zig");

pub inline fn supported() bool {
    return c.luau_codegen_supported() != 0;
}

pub inline fn create(L: *lua.State) void {
    c.luau_codegen_create(@ptrCast(L));
}

pub inline fn compile(L: *lua.State, idx: i32) void {
    c.luau_codegen_compile(@ptrCast(L), idx);
}
