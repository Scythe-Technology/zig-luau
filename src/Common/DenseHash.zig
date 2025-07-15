const std = @import("std");

const cpp_std = @import("../cpp_std.zig");

extern fn zig_new_any(size: usize) callconv(.c) *anyopaque;
extern fn zig_delete_any(*anyopaque) callconv(.c) void;

pub fn DenseHashPointer(key: *const anyopaque) usize {
    return (@intFromPtr(key) >> 4) ^ (@intFromPtr(key) >> 9);
}

pub const detail = struct {
    pub fn DenseHashTable(
        comptime Key: type,
        comptime Item: type,
        comptime MutableItem: type,
        comptime ItemInterface: type,
        comptime Hasher: type,
    ) type {
        const hash = if (@hasDecl(Hasher, "hash")) Hasher.hash else struct {
            pub fn hash(e: Key) usize {
                if (comptime @typeInfo(Key) == .pointer) {
                    return DenseHashPointer(@ptrCast(@alignCast(e)));
                } else {
                    @compileError("Hasher must implement 'hash' function");
                }
            }
        }.hash;

        const eq = if (@hasDecl(ItemInterface, "eq")) ItemInterface.eq else struct {
            pub fn eq(a: Key, b: Key) bool {
                return a == b;
            }
        }.eq;

        _ = MutableItem;
        return extern struct {
            data: ?[*]Item = null,
            capacity: usize = 0,
            count: usize = 0,
            empty_key: Key,
            hasher: u8 = 0,
            eq: u8 = 0,

            const This = @This();

            pub fn init(empty_key: Key, buckets: usize) This {
                var data: ?[*]Item = null;
                var capacity: usize = 0;
                if (buckets > 0) {
                    data = @ptrCast(@alignCast(zig_new_any(@sizeOf(Item) * buckets)));
                    capacity = buckets;

                    ItemInterface.fill(data.?, buckets, empty_key);
                }
                return .{
                    .data = data,
                    .capacity = capacity,
                    .count = 0,
                    .empty_key = empty_key,
                };
            }

            pub fn find(self: *This, key: Key) ?*const Item {
                if (self.count == 0)
                    return null;
                if (eq(key, self.empty_key))
                    return null;

                const hashmod = self.capacity - 1;
                var bucket = hash(key) & hashmod;
                for (0..hashmod) |probe| {
                    const probe_item = &self.data.?[bucket];

                    // Element exists
                    if (eq(ItemInterface.getKey(probe_item), key))
                        return probe_item;

                    // Element does not exist
                    if (eq(ItemInterface.getKey(probe_item), self.empty_key))
                        return null;

                    // Hash collision, quadratic probing
                    bucket = (bucket + probe + 1) & hashmod;
                }

                // Hash table is full - this should not happen
                std.debug.assert(false);
                return null;
            }

            pub fn size(self: This) usize {
                return self.count;
            }

            pub fn deinit(self: *This) void {
                if (self.data) |data| {
                    ItemInterface.destroy(data, self.capacity);

                    zig_delete_any(@ptrCast(@alignCast(data)));
                    self.data = null;

                    self.capacity = 0;
                }
            }
        };
    }
};

pub fn ItemInterfaceSet(comptime Key: type) type {
    return struct {
        pub fn getKey(item: *const Key) Key {
            return item.*;
        }

        pub fn setKey(item: *Key, key: Key) void {
            item.* = key;
        }

        pub fn fill(data: [*]Key, count: usize, key: Key) void {
            for (0..count) |i|
                data[i] = key;
        }

        pub fn destroy(data: [*]Key, count: usize) void {
            if (@hasDecl(Key, "deinit"))
                for (0..count) |i| {
                    Key.deinit(data[i]);
                };
        }
    };
}

pub fn ItemInterfaceMap(comptime Key: type, comptime Value: type) type {
    return struct {
        pub fn getKey(item: *const cpp_std.Pair(Key, Value)) Key {
            return item.first;
        }

        pub fn setKey(item: *cpp_std.Pair(Key, Value), key: Key) void {
            item.first = key;
        }

        pub fn fill(data: [*]cpp_std.Pair(Key, Value), count: usize, key: Key) void {
            for (0..count) |i| {
                data[i].first = key;
                data[i].second = .{};
            }
        }

        pub fn destroy(data: [*]cpp_std.Pair(Key, Value), count: usize) void {
            for (0..count) |i| {
                const ptr = data[i];
                if (@hasDecl(Key, "deinit"))
                    Key.deinit(&ptr.first);
                if (@hasDecl(Value, "deinit"))
                    Value.deinit(&ptr.second);
            }
        }
    };
}

pub fn DenseHashSet(
    comptime Key: type,
    comptime Hasher: type,
) type {
    return detail.DenseHashTable(Key, Key, Key, ItemInterfaceSet(Key), Hasher);
}

pub fn DenseHashMap(
    comptime Key: type,
    comptime Value: type,
    comptime Hasher: type,
) type {
    return detail.DenseHashTable(Key, cpp_std.Pair(Key, Value), cpp_std.Pair(Key, Value), ItemInterfaceMap(Key, Value), Hasher);
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Common/include/Luau/DenseHash.h
