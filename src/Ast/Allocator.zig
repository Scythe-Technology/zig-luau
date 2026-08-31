const std = @import("std");

const c_allocator = std.heap.c_allocator;

const This = @This();

root: ?*Page,
offset: usize = 0,

pub const Page = extern struct {
    next: ?*Page = null,
    data: [8192]u8 align(8),
};

pub fn destroy(self: This) void {
    var page = self.root;
    while (page) |p| {
        const next = p.next;

        c_allocator.destroy(p);

        page = next;
    }
}

pub fn init() !This {
    const page = try c_allocator.create(Page);
    page.next = null;
    return .{ .root = page };
}

pub fn deinit(self: This) void {
    destroy(self);
}

test This {
    var allocator = try This.init();
    defer allocator.deinit();
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Allocator.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Allocator.cpp
