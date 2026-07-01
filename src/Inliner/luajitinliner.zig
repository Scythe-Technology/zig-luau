const lua = @import("../VM/lua.zig");

extern "c" fn luau_enable_jit_inliner(lua_State: *lua.State) void;
extern "c" fn luau_disable_jit_inliner(lua_State: *lua.State) void;

pub fn enable(L: *lua.State) void {
    luau_enable_jit_inliner(L);
}

pub fn disable(L: *lua.State) void {
    luau_disable_jit_inliner(L);
}
