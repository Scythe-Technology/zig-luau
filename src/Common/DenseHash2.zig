const std = @import("std");

const cpp_std = @import("../cpp_std.zig");

const HashUtil = @import("HashUtil.zig");

fn countTrailingZeroes(word: u64) usize {
    std.debug.assert(word != 0);
    return @ctz(word);
}

const c_allocator = std.heap.c_allocator;

pub const detail = struct {
    pub const BitSet = extern struct {
        pub const BitsetT = u64;
        pub const num_elements: usize = @bitSizeOf(BitsetT);
        pub const num_elements_log2: usize = 6;

        capacity: usize = 0,
        count: usize = 0,
        data: ?[*]BitsetT = null,

        const This = @This();

        pub fn init(capacity: usize) !This {
            std.debug.assert((capacity & (capacity -% 1)) == 0);

            var data: ?[*]BitsetT = null;
            var count: usize = 0;
            if (capacity != 0) {
                count = if (capacity < num_elements) 1 else capacity >> num_elements_log2;
                data = (try c_allocator.alloc(BitsetT, count)).ptr;
                @memset(data.?[0..count], 0);
            }
            return .{
                .capacity = capacity,
                .count = count,
                .data = data,
            };
        }

        pub fn contains(self: This, bucket: usize) bool {
            const which_bitvec = bucket >> num_elements_log2;
            const bv_offset = bucket & (num_elements - 1);
            return ((self.data.?[which_bitvec] >> @intCast(bv_offset)) & 1) == 1;
        }

        pub fn clear(self: *This) void {
            if (self.count != 0)
                @memset(self.data.?[0..self.count], 0);
        }

        pub fn set(self: *This, bucket: usize, v: bool) void {
            const which_bitvec = bucket >> num_elements_log2;
            const offset = bucket & (num_elements - 1);
            if (v) {
                self.data.?[which_bitvec] |= @as(BitsetT, 1) << @intCast(offset);
            } else {
                self.data.?[which_bitvec] &= ~(@as(BitsetT, 1) << @intCast(offset));
            }
        }

        pub fn wordAt(self: This, idx: usize) BitsetT {
            std.debug.assert(idx < self.count);
            return self.data.?[idx];
        }

        pub fn numWords(self: This) usize {
            return self.count;
        }

        pub fn deinit(self: *This) void {
            if (self.data) |data| {
                c_allocator.destroy(@as(*BitsetT, @ptrCast(@alignCast(data))));
                self.data = null;
            }
        }

        pub const Iterator = struct {
            data: ?[*]const BitsetT = null,
            word_count: usize = 0,
            word_idx: usize = 0,
            word: BitsetT = 0,
            current_bucket: usize = 0,

            pub fn init(data: ?[*]const BitsetT, word_count: usize, word_idx: usize) Iterator {
                var it: Iterator = .{
                    .data = data,
                    .word_count = word_count,
                    .word_idx = word_idx,
                };

                if (data == null)
                    return it;

                while (it.word_idx < it.word_count) {
                    it.word = data.?[it.word_idx];
                    if (it.word != 0)
                        break;
                    it.word_idx += 1;
                }

                if (it.word_idx < it.word_count)
                    it.current_bucket = it.word_idx * num_elements + countTrailingZeroes(it.word);

                return it;
            }

            pub fn get(self: Iterator) usize {
                return self.current_bucket;
            }

            pub fn next(self: *Iterator) void {
                self.word &= self.word -% 1;
                while (self.word == 0) {
                    self.word_idx += 1;
                    if (self.word_idx >= self.word_count)
                        return;
                    self.word = self.data.?[self.word_idx];
                }
                self.current_bucket = self.word_idx * num_elements + countTrailingZeroes(self.word);
            }

            pub fn eql(self: Iterator, other: Iterator) bool {
                return self.word_idx == other.word_idx and self.word == other.word;
            }
        };

        pub fn begin(self: This) Iterator {
            return .init(self.data, self.count, 0);
        }

        pub fn end(self: This) Iterator {
            return .init(self.data, self.count, self.count);
        }
    };

    pub fn DenseHashTable2(
        comptime Key: type,
        comptime Item: type,
        comptime MutableItem: type,
        comptime ItemInterface: type,
        comptime Hasher: type,
    ) type {
        const hash = if (@hasDecl(Hasher, "hash")) Hasher.hash else struct {
            pub fn hash(e: Key) usize {
                if (comptime @typeInfo(Key) == .pointer) {
                    return cpp_std.hash(@intFromPtr(e));
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
            used_table: BitSet = .{},
            capacity: usize = 0,
            count: usize = 0,
            hash_shift: u8 = 64,
            hasher: u8 = 0,
            eq: u8 = 0,

            const This = @This();

            pub const empty: This = .{};

            pub fn init(buckets: usize) !This {
                var data: ?[*]Item = null;
                var used_table: BitSet = .{};
                var capacity: usize = 0;
                var hash_shift: u8 = 64;

                std.debug.assert((buckets & (buckets -% 1)) == 0);

                if (buckets != 0) {
                    data = (try c_allocator.alloc(Item, buckets)).ptr;
                    used_table = try BitSet.init(buckets);
                    capacity = buckets;
                    hash_shift = 64 - @as(u8, @intCast(countTrailingZeroes(buckets)));
                }
                return .{
                    .data = data,
                    .used_table = used_table,
                    .capacity = capacity,
                    .count = 0,
                    .hash_shift = hash_shift,
                };
            }

            pub fn doHash(self: This, key: Key) usize {
                const mixed = @as(u64, @intCast(hash(key))) *% 11400714819323198485;
                return @intCast(mixed >> @intCast(self.hash_shift));
            }

            fn getBucket(self: *const This, key: Key) struct { usize, bool } {
                std.debug.assert(self.count < self.capacity);
                const hashmod = self.capacity - 1;
                var bucket = self.doHash(key);

                while (true) {
                    if (!self.used_table.contains(bucket))
                        return .{ bucket, false };

                    if (eq(ItemInterface.getKey(&self.data.?[bucket]), key))
                        return .{ bucket, true };

                    bucket = (bucket + 1) & hashmod;
                }
            }

            pub fn insert_unsafe(self: *This, key: Key) *Item {
                const bucket, const found = self.getBucket(key);

                if (!found) {
                    self.used_table.set(bucket, true);
                    ItemInterface.setKey(&self.data.?[bucket], key);
                    self.count += 1;
                }

                return &self.data.?[bucket];
            }

            pub fn find(self: *This, key: Key) ?*const Item {
                if (self.count == 0)
                    return null;

                const bucket, const found = self.getBucket(key);
                return if (found) &self.data.?[bucket] else null;
            }

            pub fn contains(self: *This, key: Key) bool {
                return self.find(key) != null;
            }

            pub fn insert(self: *This, key: Key) !*Item {
                try self.rehash_if_full(key);
                return self.insert_unsafe(key);
            }

            pub fn grow(self: *This) !void {
                const newsize: usize = if (self.capacity == 0) 16 else self.capacity * 2;

                var newtable: This = try .init(newsize);

                var it = self.used_table.begin();
                const end_it = self.used_table.end();
                // We can leverage the structure of the bitvector here to skip contiguous chunks of empty elements
                while (!it.eql(end_it)) : (it.next()) {
                    const bucket = it.get();
                    const key = ItemInterface.getKey(&self.data.?[bucket]);
                    // ItemInterface::setKey default constructs the value type. If we use insert_unsafe here, we then pay for one unnecessary construction
                    // which is immediately overwritten. Instead, we manually insert these items into the destination table
                    const dest, const found = newtable.getBucket(key);
                    std.debug.assert(!found);
                    newtable.used_table.set(dest, true);
                    newtable.count += 1;
                    newtable.data.?[dest] = self.data.?[bucket];
                }

                std.debug.assert(self.count == newtable.count);

                std.mem.swap(?[*]Item, &self.data, &newtable.data);
                std.mem.swap(BitSet, &self.used_table, &newtable.used_table);
                std.mem.swap(usize, &self.capacity, &newtable.capacity);
                std.mem.swap(u8, &self.hash_shift, &newtable.hash_shift);

                newtable.deinit();
            }

            pub fn rehash_if_full(self: *This, key: Key) !void {
                if (self.capacity == 0 or (self.count >= self.capacity * 3 / 4 and self.find(key) == null))
                    try self.grow();
            }

            pub fn size(self: This) usize {
                return self.count;
            }

            pub fn deinit(self: *This) void {
                if (self.data) |data| {
                    var it = self.used_table.begin();
                    const end_it = self.used_table.end();
                    while (!it.eql(end_it)) : (it.next())
                        ItemInterface.destroyOne(&data[it.get()]);

                    c_allocator.destroy(@as(*Item, @ptrCast(@alignCast(data))));
                    self.data = null;
                    self.used_table.deinit();

                    self.capacity = 0;
                    self.hash_shift = 64;
                }
            }
        };
    }
};

pub fn ItemInterfaceSet2(comptime Key: type) type {
    return struct {
        pub fn getKey(item: *const Key) Key {
            return item.*;
        }

        pub fn setKey(item: *Key, key: Key) void {
            item.* = key;
        }

        pub fn destroyOne(item: *Key) void {
            if (@hasDecl(Key, "deinit"))
                Key.deinit(item);
        }

        pub fn eq(a: Key, b: Key) bool {
            return std.meta.eql(a, b);
        }
    };
}

pub fn ItemInterfaceMap2(comptime Key: type, comptime Value: type) type {
    return struct {
        pub fn getKey(item: *const cpp_std.Pair(Key, Value)) Key {
            return item.first;
        }

        pub fn setKey(item: *cpp_std.Pair(Key, Value), key: Key) void {
            item.first = key;
            item.second = .{};
        }

        pub fn destroyOne(item: *cpp_std.Pair(Key, Value)) void {
            if (@hasDecl(Key, "deinit"))
                Key.deinit(&item.first);
            if (@hasDecl(Value, "deinit"))
                Value.deinit(&item.second);
        }
    };
}

pub fn DenseHashSet2(
    comptime Key: type,
    comptime Hasher: type,
) type {
    return detail.DenseHashTable2(Key, Key, Key, ItemInterfaceSet2(Key), Hasher);
}

pub fn DenseHashMap2(
    comptime Key: type,
    comptime Value: type,
    comptime Hasher: type,
) type {
    return detail.DenseHashTable2(Key, cpp_std.Pair(Key, Value), cpp_std.Pair(Key, Value), ItemInterfaceMap2(Key, Value), Hasher);
}

// sources:
// https://github.com/luau-lang/luau/blob/3fc82b1071ab387531175869afc4fb528464afa4/Common/include/Luau/DenseHash2.h
