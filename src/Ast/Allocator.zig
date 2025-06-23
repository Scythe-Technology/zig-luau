const std = @import("std");

// extern fn zig_delete_any(*Page) callconv(.c) void;

extern "c" fn zig_Luau_Ast_Allocator_init() *This;
extern "c" fn zig_Luau_Ast_Allocator_dtor(*This) void;

const This = @This();

root: [*c]Page,
offset: usize = 0,

pub const Page = extern struct {
    next: [*c]Page = null,
    data: [8192]u8 align(8),
};

// /// cleans up the luau allocator
// /// frees all pages created by C++
// pub fn destroy(self: This) void {
//     var page = self.root;
//     while (page != null) {
//         const next = page.*.next;
//         // pages are C++ allocated, so we need to use the C++ deallocator
//         zig_delete_any(page);
//         std.debug.print("clean page\n", .{});
//         page = next;
//     }
// }

pub fn init() *This {
    return zig_Luau_Ast_Allocator_init();
}

pub fn deinit(self: *This) void {
    zig_Luau_Ast_Allocator_dtor(self);
}

test This {
    const allocator = This.init();
    defer allocator.deinit();
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Allocator.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Allocator.cpp
