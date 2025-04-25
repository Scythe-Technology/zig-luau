const std = @import("std");

extern "c" fn zig_string_size(self: *const String) usize;
extern "c" fn zig_string_c_str(self: *const String) [*c]const u8;

pub fn BasicString(comptime value_type: type) type {
    return extern struct {
        const __min_cap = if ((@sizeOf(__long) - 1) / @sizeOf(value_type) > 2)
            (@sizeOf(__long) - 1) / @sizeOf(value_type)
        else
            2;

        const __long = extern struct {
            capacity: usize,
            size: usize,
            ptr: [*c]const value_type,
        };

        const __short = extern struct {
            len: u8,
            buffer: [__min_cap - 1:0]value_type,
        };

        data: extern union {
            short: __short,
            long: __long,
        },

        pub inline fn isShort(self: *const String) bool {
            return self.data.short.len & 1 == 0;
        }

        pub fn size(self: *const String) usize {
            // if (self.isShort())
            //     return self.data.short.len >> 1;
            // return self.data.long.size;
            return zig_string_size(self);
        }

        pub fn c_str(self: *const String) [*c]const u8 {
            // if (self.isShort())
            //     return self.data.short.buffer;
            // return self.data.long.ptr;
            return zig_string_c_str(self);
        }

        pub fn slice(self: *const String) []const u8 {
            // if (self.isShort()) {
            //     const len = self.data.short.len >> 1;
            //     return self.data.short.buffer[0..len];
            // }
            // const len = self.data.long.size;
            // return self.data.long.ptr[0..len];
            const len = zig_string_size(self);
            return zig_string_c_str(self)[0..len];
        }
    };
}

// LLVM: 24
// GCC/MSVC: 32
// data: [24]u8 align(8),
pub const String = BasicString(u8);
comptime {
    std.testing.expectEqual(24, @sizeOf(String)) catch @panic("String must be 24 bytes");
    std.testing.expectEqual(8, @alignOf(String)) catch @panic("String must be 8-byte aligned");
}

pub fn Exception(comptime T: type) type {
    return extern struct {
        vtable: *const anyopaque,
        value: T,
    };
}

pub fn Optional(comptime T: type) type {
    return extern struct {
        value: T = undefined,
        has: bool,

        pub fn to(self: @This()) ?T {
            if (self.has) {
                return self.value;
            } else {
                return null;
            }
        }
    };
}

pub fn Vector(comptime T: type) type {
    return extern struct {
        begin: [*]T,
        end: [*]T,
        capacity_end: [*]T,

        const This = @This();

        pub fn iterator(self: This) Iterator {
            return .{
                .current = self.begin,
                .end = self.end,
            };
        }

        pub fn size(self: This) usize {
            // divExact would not work if the sizeOf(T) doesn't match the C++ std::vector<T>
            return @divExact(@intFromPtr(self.end) - @intFromPtr(self.begin), @sizeOf(T));
        }

        pub fn empty(self: This) bool {
            return self.size() == 0;
        }

        pub fn front(self: This) ?T {
            if (self.begin == self.end)
                return null
            else
                return self.begin[0];
        }

        pub fn back(self: This) ?T {
            const i = self.size();
            if (i == 0)
                return null;
            return self.begin[i - 1];
        }

        pub fn capacity(self: This) usize {
            // divExact would not work if the sizeOf(T) doesn't match the C++ std::vector<T>
            return @divExact(@intFromPtr(self.capacity_end) - @intFromPtr(self.begin), @sizeOf(T));
        }

        pub fn at(self: This, pos: usize) T {
            std.debug.assert(!self.empty());
            std.debug.assert(pos < self.size());
            return self.begin[pos];
        }

        pub const Iterator = struct {
            current: [*]T,
            end: [*]T,
            pub fn next(self: *Iterator) ?T {
                if (self.current == self.end)
                    return null
                else {
                    const value = self.current[0];
                    self.current = self.current[1..];
                    return value;
                }
            }
        };
    };
}

pub fn Pair(comptime First: type, comptime Second: type) type {
    return extern struct {
        first: First,
        second: Second,
    };
}
