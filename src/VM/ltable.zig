const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");
const lobject = @import("lobject.zig");

const lstate = @import("lstate.zig");
const ldebug = @import("ldebug.zig");
const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");
const lnumutils = @import("lnumutils.zig");
const ltm = @import("ltm.zig");

const Errorset = @import("errorset.zig");

const Error = Errorset.Table;

// Set this to 1 to change the hash function to something different (and possibly trivial). Useful
// for checking if a Lua program's behavior depends on the hash function.
const ALT_HASH_FUNCTION = false;

// max size of both array and hash part is 2^MAXBIT
const MAXBITS = 26;
const MAXSIZE = 1 << MAXBITS;

const TValue = lobject.TValue;
const LuaNode = lobject.LuaNode;
const LuaTable = lobject.LuaTable;

const LUA_VECTOR_SIZE = lua.config.VECTOR_SIZE;

// const Hdummynode: LuaNode = .{
//     .val = .{ .extra = undefined, .tt = @intFromEnum(lua.Type.Nil), .value = undefined },
//     .key = .{ .extra = undefined, .pi = .{ .tt = @intFromEnum(lua.Type.Nil), .next = 0 }, .value = undefined },
// };
extern "c" const luaH_dummynode: LuaNode;
pub const dummynode = &luaH_dummynode;

pub inline fn invalidateTMcache(t: *LuaTable) void {
    t.tmcache = 0;
}

pub inline fn hashpow2(t: *const LuaTable, n: u32) [*]LuaNode {
    return t.gnode(lobject.lmod(usize, n, lobject.sizenode(t)));
}
pub inline fn hashstr(t: *const LuaTable, str: *const lobject.TString) [*]LuaNode {
    return hashpow2(t, (if (ALT_HASH_FUNCTION) 0x87654321 else 0) ^ str.hash);
}
pub inline fn hashboolean(t: *const LuaTable, b: bool) [*]LuaNode {
    return hashpow2(t, @as(u32, if (ALT_HASH_FUNCTION) 0x87654321 else 0) ^ @as(u32, if (b) 1 else 0));
}

pub fn hashpointer(t: *const LuaTable, p: ?*const anyopaque) [*]LuaNode {
    // we discard the high 32-bit portion of the pointer on 64-bit platforms as it doesn't carry much entropy anyway
    var h: u32 = if (p) |ptr| @truncate(@intFromPtr(ptr)) else 0;

    // MurmurHash3 32-bit finalizer
    if (comptime !ALT_HASH_FUNCTION) {
        h ^= h >> 16;
        h *%= 0x85ebca6b;
        h ^= h >> 13;
        h *%= 0xc2b2ae35;
        h ^= h >> 16;
    }

    return hashpow2(t, h);
}

fn hashnum(t: *const LuaTable, n: f64) [*]LuaNode {
    comptime std.debug.assert(@sizeOf(f64) == @sizeOf(u32) * 2); // expected a 8-byte double;
    var i: [2]u32 = undefined;
    @memcpy(i[0..], &@as([2]u32, @bitCast(n)));

    // mask out sign bit to make sure -0 and 0 hash to the same value
    var h1: u32 = i[0];
    var h2: u32 = i[1] & 0x7fffffff;

    // finalizer from MurmurHash64B
    const m: u32 = 0x5bd1e995;

    if (comptime !ALT_HASH_FUNCTION) {
        h1 ^= h2 >> 18;
        h1 *%= m;
        h2 ^= h1 >> 22;
        h2 *%= m;
        h1 ^= h2 >> 17;
        h1 *%= m;
        h2 ^= h1 >> 19;
        h2 *%= m;
    }
    // ... truncated to 32-bit output (normally hash is equal to (uint64_t(h1) << 32) | h2, but we only really need the lower 32-bit half)
    return hashpow2(t, h2);
}

fn hashint(t: *const LuaTable, n: i64) [*]LuaNode {
    comptime std.debug.assert(@sizeOf(i64) == @sizeOf(u32) * 2); // expected a 8-byte integer;
    var i: [2]u32 = undefined;
    @memcpy(i[0..], &@as([2]u32, @bitCast(n)));

    var h1: u32 = i[0];
    var h2: u32 = i[1];

    // finalizer from MurmurHash64B
    const m: u32 = 0x5bd1e995;

    if (comptime !ALT_HASH_FUNCTION) {
        h1 ^= h2 >> 18;
        h1 *%= m;
        h2 ^= h1 >> 22;
        h2 *%= m;
        h1 ^= h2 >> 17;
        h1 *%= m;
        h2 ^= h1 >> 19;
        h2 *%= m;
    }

    // ... truncated to 32-bit output (normally hash is equal to (uint64_t(h1) << 32) | h2, but we only really need the lower 32-bit half)
    return hashpow2(t, h2);
}

fn hashvec(t: *const LuaTable, v: []const lua.config.VECTOR_TYPE) [*]LuaNode {
    if (comptime !lua.config.VECTOR_DOUBLE) {
        var i: [LUA_VECTOR_SIZE]u32 = undefined;
        @memcpy(i[0..], (@as([*]const u32, @ptrCast(@alignCast(v.ptr))))[0..LUA_VECTOR_SIZE]);

        // convert -0 to 0 to make sure they hash to the same value
        i[0] = if (i[0] == 0x80000000) 0 else i[0];
        i[1] = if (i[1] == 0x80000000) 0 else i[1];
        i[2] = if (i[2] == 0x80000000) 0 else i[2];

        // scramble bits to make sure that integer coordinates have entropy in lower bits
        if (comptime !ALT_HASH_FUNCTION) {
            i[0] ^= i[0] >> 17;
            i[1] ^= i[1] >> 17;
            i[2] ^= i[2] >> 17;
        }

        // Optimized Spatial Hashing for Collision Detection of Deformable Objects
        var h: u32 = (i[0] * 73856093) ^ (i[1] * 19349663) ^ (i[2] * 83492791);

        if (comptime LUA_VECTOR_SIZE == 4) {
            i[3] = if (i[3] == 0x80000000) 0 else i[3];
            i[3] ^= i[3] >> 17;
            h ^= i[3] * 39916801;
        }

        return hashpow2(t, h);
    } else {
        var i: [LUA_VECTOR_SIZE]u64 = undefined;
        @memcpy(i[0..], (@as([*]const u64, @ptrCast(@alignCast(v.ptr))))[0..LUA_VECTOR_SIZE]);

        // convert -0 to 0 to make sure they hash to the same value
        i[0] = if (i[0] == 0x8000000000000000) 0 else i[0];
        i[1] = if (i[1] == 0x8000000000000000) 0 else i[1];
        i[2] = if (i[2] == 0x8000000000000000) 0 else i[2];

        // scramble bits to make sure that integer coordinates have entropy in lower bits
        if (comptime !ALT_HASH_FUNCTION) {
            i[0] ^= i[0] >> 32;
            i[1] ^= i[1] >> 32;
            i[2] ^= i[2] >> 32;
        }

        // Optimized Spatial Hashing for Collision Detection of Deformable Objects
        var h: u32 = (@as(u32, @truncate(i[0] * 73856093))) ^ (@as(u32, @truncate(i[1] * 19349663))) ^ (@as(u32, @truncate(i[2] * 83492791)));

        if (comptime LUA_VECTOR_SIZE == 4) {
            i[3] = if (i[3] == 0x8000000000000000) 0 else i[3];
            i[3] ^= i[3] >> 32;
            h ^= @as(u32, @truncate(i[3] * 39916801));
        }

        return hashpow2(t, h);
    }
}

fn mainposition(t: *const LuaTable, key: *const TValue) [*]LuaNode {
    comptime std.debug.assert(@sizeOf(LuaNode) == @sizeOf(TValue) * 2);
    comptime std.debug.assert(@alignOf(LuaNode) == @alignOf(TValue));
    return switch (key.typeOf()) {
        .Number => hashnum(t, key.nvalue()),
        .Integer => hashint(t, key.lvalue()),
        .Vector => hashvec(t, key.vvalue()),
        .String => hashstr(t, key.tsvalue()),
        .Boolean => hashboolean(t, key.bvalue()),
        .LightUserdata => hashpointer(t, key.pvalue()),
        else => hashpointer(t, @ptrCast(@alignCast(key.gcvalue()))),
    };
}

/// Marker for template dispatch into a generic GCObject* version of a function (not for LUA_TSTRING!)
const LUA_TGCO = -1;

fn HashKey(comptime Tag: lua.Type) type {
    return switch (Tag) {
        .Boolean => bool,
        .LightUserdata => ?*const anyopaque,
        .Number => f64,
        .Integer => i64,
        .Vector => []const lua.config.VECTOR_TYPE,
        .String => *lobject.TString,
        @fromBackingInt(LUA_TGCO) => *lstate.GCObject,
        else => @compileError("bad table key tag"),
    };
}

// For static mainposition dispatch on a known tag (or GCO)
fn mainpositiontagged(comptime Tag: lua.Type, t: *const LuaTable, key: HashKey(Tag)) *LuaNode {
    return switch (comptime Tag) {
        .Boolean => @ptrCast(hashboolean(t, key)),
        .LightUserdata => @ptrCast(hashpointer(t, key)),
        .Number => @ptrCast(hashnum(t, key)),
        .Integer => @ptrCast(hashint(t, key)),
        .Vector => @ptrCast(hashvec(t, key)),
        .String => @ptrCast(hashstr(t, key)),
        @fromBackingInt(LUA_TGCO) => @ptrCast(hashpointer(t, @ptrCast(key))),
        else => @compileError("bad table key tag"),
    };
}

// TODO: remove with FFlagLuauTableFindImprovement
// For static luaO_rawequalKey dispatch on a known tag (or GCO). Only used specializations are implemented
fn rawequalkeyvalue(comptime Tag: lua.Type, t1: *const lobject.TKey, key: HashKey(Tag)) bool {
    return switch (comptime Tag) {
        .Boolean => t1.bvalue() == key,
        .Number => t1.nvalue() == key,
        .Integer => t1.lvalue() == key,
        .Vector => lnumutils.iveceq(t1.vvalue(), key),
        @fromBackingInt(LUA_TGCO) => t1.gcvalue() == key,
        else => @compileError("bad table key tag"),
    };
}

// Lookup a node in the main position of the key or look through the node chain
fn chainsearchtagged(comptime Tag: lua.Type, t: *const LuaTable, key: HashKey(Tag)) *const TValue {
    var n = mainpositiontagged(Tag, t, key);

    // check whether `key' is somewhere in the chain
    while (true) {
        if (n.gkey().typeOf() == Tag and rawequalkeyvalue(Tag, n.gkey(), key))
            return n.gval();

        if (n.gnext() == 0)
            break;
        n = n.add_num(n.gnext());
    }

    return lobject.Onilobject;
}

///
/// returns the index for `key` if `key` is an appropriate key to live in
/// the array part of the table, -1 otherwise.
///
fn arrayindex(key: f64) i32 {
    const i: i32 = lnumutils.inum2int(key);

    return if (@as(f64, @floatFromInt(i)) == key) i else -1;
}

// {=============================================================
// Rehash
// ==============================================================

pub inline fn maybesetaboundary(t: *LuaTable, boundary: i32) void {
    if (t.bound.aboundary <= 0)
        t.bound.aboundary = -boundary;
}

pub inline fn getaboundary(t: *LuaTable) c_int {
    return if (t.bound.aboundary < 0) -t.bound.aboundary else t.sizearray;
}

fn computesizes(nums: []const u32, narray: *usize) usize {
    var i: usize = 0;
    var twotoi: usize = 1; // 2^i
    var a: usize = 0; // number of elements smaller than 2^i
    var na: usize = 0; // number of elements to go to array part
    var n: usize = 0; // optimal size for array part
    while (@divTrunc(twotoi, 2) < narray.*) : (i += 1) {
        defer twotoi *= 2;
        if (nums[i] > 0) {
            a += nums[i];
            if (a > @divTrunc(twotoi, 2)) { // more than half elements present?
                n = twotoi; // optimal size (till now)
                na = a; // all elements smaller than n will go to array part
            }
        }
        if (a == narray.*)
            break; // all elements already counted
    }
    narray.* = n;
    std.debug.assert(@divTrunc(narray.*, 2) <= na and na <= narray.*);
    return na;
}

fn countint(key: f64, nums: []u32) u1 {
    const k = arrayindex(key);
    if (0 < k and k <= MAXSIZE) {
        // is `key' an appropriate array index?
        nums[@intCast(lobject.ceillog2(@intCast(k)))] += 1; // count as such
        return 1;
    }
    return 0;
}

fn numusearray(t: *const LuaTable, nums: []u32) usize {
    var lg: u8 = 0;
    var ttlg: i32 = 1; // 2^lg
    var ause: usize = 0; // summation of `nums'
    var i: u32 = 1; // count to traverse all array keys
    while (lg <= MAXBITS) : (lg += 1) { // for each slice
        defer ttlg *= 2;
        var lc: u32 = 0; // counter
        var lim: i32 = ttlg;
        if (lim > t.sizearray) {
            lim = t.sizearray; // adjust upper limit
            if (i > lim)
                break; // no more elements to count
        }
        while (i <= lim) : (i += 1) {
            if (!t.array.?[i - 1].ttisnil())
                lc += 1;
        }
        nums[lg] = lc;
        ause += lc;
    }
    return ause;
}

fn numusehash(t: *const LuaTable, nums: []u32, pnasize: *usize) u32 {
    var totaluse: u32 = 0; // total number of elements
    var ause: usize = 0; // summation of `nums'
    var i: usize = lobject.sizenode(t);
    while (i > 0) : (i -= 1) {
        const n: *LuaNode = @ptrCast(t.gnode(i - 1));
        if (!n.gval().ttisnil()) {
            if (n.gkey().ttisnumber())
                ause += countint(n.gkey().nvalue(), nums);
            totaluse += 1;
        }
    }
    pnasize.* += ause;
    return totaluse;
}

fn hashslotsused(t: *const LuaTable) u32 {
    var totaluse: u32 = 0;
    var i: usize = lobject.sizenode(t);

    while (i > 0) : (i -= 1) {
        const n: *LuaNode = @ptrCast(t.gnode(i - 1));
        if (!n.gval().ttisnil())
            totaluse += 1;
    }
    return totaluse;
}

fn setarrayvector(L: *lua.State, t: *LuaTable, size: usize) Error!void {
    if (size > MAXSIZE)
        return error.@"table overflow";
    t.array = try lmem.Mreallocarray(L, TValue, t.array, @intCast(t.sizearray), size, t.header.memcat);
    var i: usize = @intCast(t.sizearray);
    while (i < size) : (i += 1)
        t.array.?[i].setnilvalue();
    t.sizearray = @intCast(size);
}

fn setnodevector(L: *lua.State, t: *LuaTable, newsize: usize) Error!void {
    var size: usize = newsize;
    var lsize: u8 = 0;
    if (size == 0) { // no elements to hash part?
        t.node = @ptrCast(@alignCast(@constCast(dummynode))); // use common `dummynode'
    } else {
        lsize = @intCast(lobject.ceillog2(@truncate(newsize)));
        if (lsize > MAXBITS)
            return error.@"table overflow";
        size = lobject.twoto(@intCast(lsize));
        t.node = try lmem.Mnewarray(L, LuaNode, size, t.header.memcat);
        for (0..size) |i| {
            const n: *LuaNode = @ptrCast(t.gnode(i));
            n.key.pi.next = 0;
            n.gkey().setnilvalue();
            n.gval().setnilvalue();
        }
    }
    t.lsizenode = lsize;
    t.nodemask8 = @truncate((@as(usize, 1) << @truncate(lsize)) - 1);
    t.bound.lastfree = @intCast(size); // all positions are free
}

fn resize(L: *lua.State, t: *LuaTable, nasize_u: usize, nhsize_u: usize) Error!void {
    std.debug.assert(!lobject.hasmetacache(t));

    if (nasize_u > MAXSIZE or nhsize_u > MAXSIZE)
        return error.@"table overflow";

    const nasize: i32 = @intCast(nasize_u);
    var nhsize: u32 = @intCast(nhsize_u);

    // check for node size bit mask overflow and round up requested hash size
    var lsizenode: u8 = 0;

    if (nhsize != 0) {
        const lg = lobject.ceillog2(nhsize);
        if (lg > MAXBITS)
            return error.@"table overflow";

        lsizenode = @intCast(lg);
        nhsize = @intCast(lobject.twoto(@intCast(lsizenode)));
    }

    const oldsizearray = t.sizearray;
    const oldsizenode = lobject.sizenode(t);
    const oldarray = t.array;
    const oldnode = t.node;

    var newarray = t.array;

    if (nasize != oldsizearray) {
        if (nasize == 0)
            newarray = null
        else
            newarray = try lmem.Mnewarray(L, TValue, @intCast(nasize), t.header.memcat);

        if (nasize < oldsizearray) {
            // copy elements from remaining slice
            if (nasize != 0)
                @memcpy(newarray.?[0..@intCast(nasize)], oldarray.?[0..@intCast(nasize)]);
        } else {
            // copy old elements
            if (oldsizearray != 0)
                @memcpy(newarray.?[0..@intCast(oldsizearray)], oldarray.?[0..@intCast(oldsizearray)]);

            // clear new elements
            var i: i32 = oldsizearray;
            while (i < nasize) : (i += 1)
                newarray.?[@intCast(i)].setnilvalue();
        }
    }

    var newnode: [*]LuaNode = @ptrCast(@alignCast(@constCast(dummynode)));

    if (nhsize != 0) {
        // if we allocated a new array part, we have to be careful to with hash part allocation failure
        if (oldarray != newarray) {
            errdefer if (nasize != 0) lmem.Mfreearray(L, TValue, newarray, @intCast(nasize), t.header.memcat);
            newnode = try lmem.Mnewarray(L, LuaNode, nhsize, t.header.memcat);
        } else {
            newnode = try lmem.Mnewarray(L, LuaNode, nhsize, t.header.memcat);
        }

        for (0..nhsize) |i| {
            const n: *LuaNode = @ptrCast(newnode + i);
            n.key.pi.next = 0;
            n.gkey().setnilvalue();
            n.gval().setnilvalue();
        }
    }

    // update table structure now that both allocations succeeded
    t.array = newarray;
    t.sizearray = nasize;

    t.node = newnode;
    t.lsizenode = lsizenode;
    t.nodemask8 = @truncate((@as(usize, 1) << @as(if (@sizeOf(usize) == 8) u6 else u5, @intCast(lsizenode))) - 1);
    t.bound.lastfree = @intCast(nhsize); // all positions are free

    // re-insert elements from vanishing array slice
    var i: i32 = nasize;
    while (i < oldsizearray) : (i += 1) {
        if (!oldarray.?[@intCast(i)].ttisnil()) {
            var ok: TValue = undefined;
            ok.setnvalue(@floatFromInt(i + 1));
            // integer number keys from a shrinking slice cannot get into the new array part
            reinsertkey(L, t, &ok, false).setobj(L, &oldarray.?[@intCast(i)]);
        }
    }

    // re-insert elements from hash part
    var n: usize = oldsizenode;
    while (n > 0) : (n -= 1) {
        const old: *LuaNode = @ptrCast(oldnode + (n - 1));
        if (!old.gval().ttisnil()) {
            var ok: TValue = undefined;
            lobject.getnodekey(L, &ok, old);
            reinsertkey(L, t, &ok, true).setobj(L, old.gval());
        }
    }

    // make sure we haven't recursively rehashed during element migration
    std.debug.assert(newnode == t.node);
    std.debug.assert(newarray == t.array);

    // free old array
    if (nasize != oldsizearray and oldsizearray != 0)
        lmem.Mfreearray(L, TValue, oldarray, @intCast(oldsizearray), t.header.memcat);

    // free old node
    if (@as(*LuaNode, @ptrCast(oldnode)) != dummynode)
        lmem.Mfreearray(L, LuaNode, oldnode, oldsizenode, t.header.memcat);
}

// When we already know that new key is an integer number
fn adjustasize(t: *LuaTable, size: usize, extraintkey: i32) usize {
    const tbound: bool = @as(*LuaNode, @ptrCast(t.node)) != dummynode or size < t.sizearray;
    // move the array size up until the boundary is guaranteed to be inside the array part
    var adjusted_size = size;
    while (adjusted_size + 1 == extraintkey or (tbound and !Hgetnum(t, @intCast(adjusted_size + 1)).ttisnil()))
        adjusted_size += 1;
    return adjusted_size;
}

pub fn Hresizearray(L: *lua.State, t: *LuaTable, nasize: usize) Error!void {
    if (nasize > MAXSIZE)
        return error.@"table overflow";

    const nsize = if (@as(*LuaNode, @ptrCast(t.node)) == dummynode) 0 else lobject.sizenode(t);
    const asize = adjustasize(t, nasize, -1);
    try resize(L, t, asize, nsize);
}

pub fn Hresizehash(L: *lua.State, t: *LuaTable, nhsize: usize) Error!void {
    try resize(L, t, @intCast(t.sizearray), nhsize);
}

fn rehash(comptime IsIntKey: bool, L: *lua.State, t: *LuaTable, newintkey: i32) Error!void {
    // insertions of keys that are not integer numbers do not have to rehash the array part
    // this can mean that such key insert will not cause the sparse array/node rebalance, but this is actually less surprising
    if (comptime !IsIntKey) {
        const nh: usize = @as(usize, hashslotsused(t)) + 1;
        try resize(L, t, @intCast(t.sizearray), nh);
        return;
    }

    // nums[i] = number of keys between 2^(i-1) and 2^i
    var nums: [MAXBITS + 1]u32 = @splat(0);
    var nasize: usize = 0;
    var totaluse: usize = 0;

    if (t.sizearray != 0) {
        nasize = numusearray(t, nums[0..]); // count keys in array part
        totaluse = nasize; // all those keys are integer keys
    }

    if (@as(*LuaNode, @ptrCast(t.node)) != dummynode)
        totaluse += numusehash(t, nums[0..], &nasize); // count keys in hash part

    // count extra key
    if (0 < newintkey and newintkey <= MAXSIZE) {
        nums[@intCast(lobject.ceillog2(@intCast(newintkey)))] += 1;
        nasize += 1;
    }

    totaluse += 1;

    // compute new size for array part
    const na = computesizes(nums[0..], &nasize);
    var nh = totaluse - na;

    // enforce the boundary invariant; for performance, only do hash lookups if we must
    const nadjusted = adjustasize(t, nasize, newintkey);

    // count how many extra elements belong to array part instead of hash part
    const aextra = nadjusted - nasize;

    if (aextra != 0) {
        // we no longer need to store those extra array elements in hash part
        nh -= aextra;

        // because hash nodes are twice as large as array nodes, the memory we saved for hash parts can be used by array part
        // this follows the general sparse array part optimization where array is allocated when 50% occupation is reached
        nasize = nadjusted + aextra;

        // since the size was changed, it's again important to enforce the boundary invariant at the new size
        nasize = adjustasize(t, nasize, newintkey);
    }

    // resize the table to new computed sizes
    try resize(L, t, nasize, nh);
}

pub fn Hnew(L: *lua.State, narray: u32, nhash: u32) Error!*LuaTable {
    const t = try lmem.Mnewgco(L, LuaTable, @sizeOf(LuaTable), L.header.memcat, @backingInt(lua.Type.Table));
    lgc.Cinit(L, @ptrCast(@alignCast(t)), @backingInt(lua.Type.Table));
    t.metatable = null;
    t.tmcache = ~(@as(u8, 0));
    t.array = null;
    t.sizearray = 0;
    t.bound.lastfree = 0;
    t.lsizenode = 0;
    t.readonly = 0;
    t.safeenv = 0;
    t.nodemask8 = 0;
    t.node = @ptrCast(@alignCast(@constCast(dummynode)));
    if (narray > 0)
        try setarrayvector(L, t, narray);
    if (nhash > 0)
        try setnodevector(L, t, nhash);
    return t;
}

pub fn Hfree(L: *lua.State, t: *LuaTable, page: *lmem.lua_Page) void {
    if (@as(*LuaNode, @ptrCast(t.node)) != dummynode)
        lmem.Mfreearray(L, LuaNode, t.node, lobject.sizenode(t), t.header.memcat);
    if (t.array) |arr| {
        if (lobject.hasmetacache(t)) {
            lmem.Mfreearray(L, TValue, arr - ltm.N, @as(usize, @intCast(t.sizearray)) + ltm.N, t.header.memcat);
        } else {
            lmem.Mfreearray(L, TValue, arr, @intCast(t.sizearray), t.header.memcat);
        }
    }
    lmem.Mfreegco(L, t.obj2gco(), @sizeOf(LuaTable), t.header.memcat, page);
}

fn getfreepos(t: *LuaTable) ?*LuaNode {
    while (t.bound.lastfree > 0) {
        t.bound.lastfree -= 1;

        const n: *LuaNode = @ptrCast(t.gnode(@intCast(t.bound.lastfree)));
        if (n.gkey().ttisnil())
            return n;
    }
    return null; // could not find a free place
}

fn newcollidingkey(L: *lua.State, t: *LuaTable, mp: *LuaNode, n: *LuaNode) *LuaNode {
    std.debug.assert(n != dummynode);

    var mk: TValue = undefined;
    lobject.getnodekey(L, &mk, mp);
    var othern: *LuaNode = @ptrCast(mainposition(t, &mk));

    // is colliding node out of its main position?
    if (othern != mp) {
        // yes, move colliding node into free position
        while (othern.add_num(othern.gnext()) != mp)
            othern = othern.add_num(othern.gnext()); // find previous

        othern.key.pi.next = @truncate(n.sub(othern)); // redo the chain with `n' in place of `mp'
        n.* = mp.*; // copy colliding node into free pos. (mp->next also goes)

        if (mp.gnext() != 0) {
            n.key.pi.next += @truncate(mp.sub(n)); // correct 'next'
            mp.key.pi.next = 0; // now 'mp' is free
        }

        mp.gval().setnilvalue();
        return mp;
    } else {
        // colliding node is in its own main position
        // new node will go into free position
        if (mp.gnext() != 0)
            n.key.pi.next = @truncate(mp.add_num(mp.gnext()).sub(n)) // chain new position
        else
            std.debug.assert(n.gnext() == 0);
        mp.key.pi.next = @truncate(n.sub(mp));
        return n;
    }
}

// inserts a new key into a hash table; first, check whether key's main
// position is free. If not, check whether colliding node is in its main
// position or not: if it is not, move colliding node to an empty place and
// put new key in its main position; otherwise (colliding node is in its main
// position), new key goes to an empty position.
fn newkeytagged(
    comptime Tag: lua.Type,
    comptime IsIntKey: bool,
    L: *lua.State,
    t: *LuaTable,
    key: *const TValue,
    hashkey: HashKey(Tag),
    newintkey: i32,
) Error!*TValue {
    // enforce boundary invariant
    if (comptime IsIntKey) {
        if (newintkey == t.sizearray + 1) {
            try rehash(IsIntKey, L, t, newintkey); // grow table

            if (@as(u32, @bitCast(newintkey)) -% 1 < @as(u32, @bitCast(t.sizearray)))
                return &t.array.?[@intCast(newintkey - 1)];

            // after rehash, numeric keys might be located in the new array part, but won't be found in the node part
            return newkeytagged(Tag, IsIntKey, L, t, key, hashkey, newintkey);
        }
    }

    var mp = mainpositiontagged(Tag, t, hashkey);

    if (!mp.gval().ttisnil() or mp == dummynode) {
        // get a free place
        if (getfreepos(t)) |n| {
            mp = newcollidingkey(L, t, mp, n);
        } else {
            // cannot find a free place?
            try rehash(IsIntKey, L, t, newintkey); // grow table

            if (comptime IsIntKey) {
                if (@as(u32, @bitCast(newintkey)) -% 1 < @as(u32, @bitCast(t.sizearray)))
                    return &t.array.?[@intCast(newintkey - 1)];
            }

            // after rehash, numeric keys might be located in the new array part, but won't be found in the node part
            return newkeytagged(Tag, IsIntKey, L, t, key, hashkey, newintkey);
        }
    }

    lobject.setnodekey(L, mp, key);

    if (comptime @backingInt(Tag) >= @backingInt(lua.Type.String) or @backingInt(Tag) == LUA_TGCO)
        lgc.Cbarriert(L, t, key);

    std.debug.assert(mp.gval().ttisnil());
    return mp.gval();
}

// for the table rehash path, we cannot trigger nested reshashing
fn reinsertkey(L: *lua.State, t: *LuaTable, key: *const TValue, checkarraypart: bool) *TValue {
    if (checkarraypart and key.ttisnumber()) {
        const n = key.nvalue();
        const k = lnumutils.inum2int(n);
        if (@as(f64, @floatFromInt(k)) == n and @as(u32, @bitCast(k)) -% 1 < @as(u32, @bitCast(t.sizearray)))
            return &t.array.?[@intCast(k - 1)];
    }

    var mp: *LuaNode = @ptrCast(mainposition(t, key));

    if (!mp.gval().ttisnil() or mp == dummynode)
        mp = newcollidingkey(L, t, mp, getfreepos(t).?);

    lobject.setnodekey(L, mp, key);
    lgc.Cbarriert(L, t, key);
    std.debug.assert(mp.gval().ttisnil());
    return mp.gval();
}

//
// search function for integers
//
pub fn Hgetnum(t: *LuaTable, key: i32) *const TValue {
    // (1 <= key && key <= t->sizearray)
    if (@as(u32, @bitCast(key)) -% 1 < @as(u32, @bitCast(t.sizearray)))
        return &t.array.?[@intCast(key - 1)]
    else if (@as(*LuaNode, @ptrCast(t.node)) != dummynode) {
        // hash fallback
        const nk: f64 = @floatFromInt(key);
        var n = hashnum(t, nk);
        while (true) { // check whether `key' is somewhere in the chain
            if (n[0].gkey().ttisnumber() and n[0].gkey().nvalue() == nk)
                return n[0].gval(); // that's it
            if (n[0].gnext() == 0)
                break;
            n = @ptrCast(n[0].add_num(n[0].gnext()));
        }
    }
    return lobject.Onilobject;
}

pub fn Hgetstr(t: *LuaTable, key: *lobject.TString) *const TValue {
    var n: *LuaNode = @ptrCast(hashstr(t, key));
    while (true) { // check whether `key' is somewhere in the chain
        if (n.gkey().ttisstring() and n.gkey().tsvalue() == key)
            return n.gval(); // that's it
        if (n.gnext() == 0)
            break;
        n = n.add_num(n.gnext());
    }
    return lobject.Onilobject;
}

// search function for lightuserdata
pub fn Hgetp(t: *LuaTable, key: ?*anyopaque, tag: c_int) *const TValue {
    var n: *LuaNode = @ptrCast(hashpointer(t, key));
    while (true) { // check whether `key' is somewhere in the chain
        const nk = n.gkey();
        if (nk.ttislightuserdata() and nk.pvalue() == key and nk.lightuserdatatag() == tag)
            return n.gval(); // that's it
        if (n.gnext() == 0)
            break;
        n = n.add_num(n.gnext());
    }
    return lobject.Onilobject;
}

pub fn Hget(t: *LuaTable, key: *const TValue) *const TValue {
    switch (key.typeOf()) {
        .Nil => return lobject.Onilobject,
        .Boolean => return chainsearchtagged(.Boolean, t, key.bvalue()),
        .LightUserdata => return Hgetp(t, key.pvalue(), key.lightuserdatatag()), // special search function with tag comparison
        .Number => {
            const n = key.nvalue();
            const k = lnumutils.inum2int(n);
            if (@as(f64, @floatFromInt(k)) == n) // index is int?
                return Hgetnum(t, k); // use specialized version

            return chainsearchtagged(.Number, t, n);
        },
        .Integer => return chainsearchtagged(.Integer, t, key.lvalue()),
        .Vector => return chainsearchtagged(.Vector, t, key.vvalue()),
        .String => return Hgetstr(t, key.tsvalue()),
        else => return chainsearchtagged(@fromBackingInt(LUA_TGCO), t, key.gcvalue()),
    }
}

pub fn Hset(L: *lua.State, t: *LuaTable, key: *const TValue) Error!*TValue {
    const p = Hget(t, key);
    invalidateTMcache(t);
    if (p != lobject.Onilobject)
        return @constCast(p)
    else
        return try Hnewkey(L, t, key);
}

pub fn Hnewkey(L: *lua.State, t: *LuaTable, key: *const TValue) Error!*TValue {
    switch (key.typeOf()) {
        .Nil => return error.@"table index is nil",
        .Boolean => return newkeytagged(.Boolean, false, L, t, key, key.bvalue(), -1),
        .LightUserdata => return newkeytagged(.LightUserdata, false, L, t, key, key.pvalue(), -1),
        .Number => {
            const n = key.nvalue();
            if (lnumutils.inumisnan(n))
                return error.@"table index is nan";

            const k = lnumutils.inum2int(n);
            if (@as(f64, @floatFromInt(k)) == n)
                return newkeytagged(.Number, true, L, t, key, n, k);

            return newkeytagged(.Number, false, L, t, key, n, -1);
        },
        .Integer => return newkeytagged(.Integer, false, L, t, key, key.lvalue(), -1),
        .Vector => {
            if (lnumutils.ivecisnan(key.vvalue()))
                return error.@"table index contains nan";

            return newkeytagged(.Vector, false, L, t, key, key.vvalue(), -1);
        },
        .String => return newkeytagged(.String, false, L, t, key, key.tsvalue(), -1),
        else => return newkeytagged(@fromBackingInt(LUA_TGCO), false, L, t, key, key.gcvalue(), -1),
    }
}

pub fn Hsetnum(L: *lua.State, t: *LuaTable, key: i32) Error!*TValue {
    // (1 <= key && key <= t->sizearray)
    if (@as(u32, @bitCast(key)) -% 1 < @as(u32, @bitCast(t.sizearray)))
        return &t.array.?[@intCast(key - 1)];
    // hash fallback
    const p = Hgetnum(t, key);
    if (p != lobject.Onilobject)
        return @constCast(p)
    else {
        const n: f64 = @floatFromInt(key);
        var k: TValue = undefined;
        k.setnvalue(n);
        return newkeytagged(.Number, true, L, t, &k, n, key);
    }
}

pub fn Hsetstr(L: *lua.State, t: *LuaTable, key: *lobject.TString) Error!*TValue {
    const p = Hgetstr(t, key);
    invalidateTMcache(t);
    if (p != lobject.Onilobject)
        return @constCast(p)
    else {
        var k: TValue = undefined;
        k.setsvalue(L, key);
        return newkeytagged(.String, false, L, t, &k, key, -1);
    }
}

pub fn Hsetp(L: *lua.State, t: *LuaTable, key: ?*anyopaque, tag: c_int) Error!*TValue {
    const p = Hgetp(t, key, tag);
    if (p != lobject.Onilobject)
        return @constCast(p)
    else {
        var k: TValue = undefined;
        k.setpvalue(key, @intCast(tag));
        return newkeytagged(.LightUserdata, false, L, t, &k, key, -1);
    }
}

fn updateaboundary(t: *LuaTable, boundary: u32) u32 {
    if (boundary < t.sizearray and t.array.?[boundary - 1].ttisnil()) {
        if (boundary >= 2 and !t.array.?[boundary - 2].ttisnil()) {
            maybesetaboundary(t, @intCast(boundary - 1));
            return boundary - 1;
        }
    } else if (boundary + 1 < t.sizearray and !t.array.?[boundary].ttisnil() and t.array.?[boundary + 1].ttisnil()) {
        maybesetaboundary(t, @intCast(boundary + 1));
        return boundary + 1;
    }
    return 0;
}

/// Try to find a boundary in table `t'. A `boundary' is an integer index
/// such that t[i] is non-nil and t[i+1] is nil (and 0 if t[1] is nil).
pub fn Hgetn(t: *LuaTable) usize {
    const boundary = getaboundary(t);
    const array_size: usize = @intCast(t.sizearray);
    if (boundary > 0) {
        if (!t.array.?[array_size - 1].ttisnil() and @as(*lobject.LuaNode, @ptrCast(t.node)) == dummynode)
            return @intCast(array_size); // fast-path: the end of the array in `t' already refers to a boundary
        if (boundary < array_size and !t.array.?[@as(u32, @intCast(boundary)) - 1].ttisnil() and t.array.?[@intCast(boundary)].ttisnil())
            return @intCast(boundary); // fast-path: boundary already refers to a boundary in `t'

        const foundboundary = updateaboundary(t, @intCast(boundary));
        if (foundboundary > 0)
            return @intCast(foundboundary);
    }
    if (array_size > 0 and t.array.?[array_size - 1].ttisnil()) {
        // "branchless" binary search from Array Layouts for Comparison-Based Searching, Paul Khuong, Pat Morin, 2017.
        // note that clang is cmov-shy on cmovs around memory operands, so it will compile this to a branchy loop.
        var base = t.array.?;
        var rest = array_size;
        var half = rest >> 1;
        while (half > 0) : (half = rest >> 1) {
            base = if (base[half].ttisnil()) base else base[half..];
            rest -= half;
        }
        const _boundary = @as(usize, if (!base[0].ttisnil()) 1 else 0) + (base - t.array.?);
        maybesetaboundary(t, @intCast(_boundary));
        return _boundary;
    } else {
        // validate boundary invariant
        std.debug.assert(@as(*lobject.LuaNode, @ptrCast(t.node)) == dummynode or Hgetnum(t, @intCast(array_size + 1)).ttisnil());
        return array_size;
    }
}

pub fn Hclone(L: *lua.State, tt: *LuaTable) Error!*LuaTable {
    const t = try lmem.Mnewgco(L, LuaTable, @sizeOf(LuaTable), L.activememcat, @backingInt(lua.Type.Table));
    lgc.Cinit(L, @ptrCast(@alignCast(t)), @backingInt(lua.Type.Table));
    t.metatable = tt.metatable;
    t.tmcache = tt.tmcache;
    t.array = null;
    t.sizearray = 0;
    t.lsizenode = 0;
    t.nodemask8 = 0;
    t.readonly = 0;
    t.safeenv = 0;
    t.node = @ptrCast(@constCast(dummynode));
    t.bound.lastfree = 0;

    if (tt.sizearray > 0) {
        t.array = try lmem.Mnewarray(L, TValue, @intCast(tt.sizearray), tt.header.memcat);
        maybesetaboundary(t, getaboundary(tt));
        t.sizearray = tt.sizearray;

        @memcpy(t.array.?[0..@intCast(tt.sizearray)], tt.array.?[0..@intCast(tt.sizearray)]);
    }

    if (@as(*LuaNode, @ptrCast(tt.node)) != dummynode) {
        const size = @as(usize, 1) << @as(if (@sizeOf(usize) == 8) u6 else u5, @truncate(tt.lsizenode));
        t.node = try lmem.Mnewarray(L, LuaNode, size, tt.header.memcat);
        t.lsizenode = tt.lsizenode;
        t.nodemask8 = tt.nodemask8;
        @memcpy(t.node[0..@intCast(size)], tt.node[0..@intCast(size)]);
        t.bound.lastfree = tt.bound.lastfree;
    }

    return t;
}

pub fn Hclear(tt: *LuaTable) void {
    // clear array part
    for (0..@intCast(tt.sizearray)) |i|
        tt.array.?[i].setnilvalue();

    maybesetaboundary(tt, 0);

    // clear hash part
    if (@as(*LuaNode, @ptrCast(tt.node)) != dummynode) {
        const size = lobject.sizenode(tt);
        tt.bound.lastfree = @intCast(size);
        for (0..@intCast(size)) |i| {
            const n = tt.gnode(i);
            n[0].gkey().setttype(.Nil);
            n[0].gval().setnilvalue();
            n[0].key.pi.next = 0;
        }
    }

    // back to empty -> no tag methods present
    tt.tmcache = ~@as(u8, 0);
}

pub fn Hsetreadonly(L: *lua.State, t: *LuaTable, readonly: bool) Error!void {
    if (Hgetreadonly(t) == readonly)
        return;

    if (readonly) {
        t.readonly = 1;

        // check if this table is likely to be used as a metatable
        if (@as(*const LuaNode, @ptrCast(t.node)) == dummynode)
            return;

        // collect all metamethods
        var metamethods: [ltm.N]TValue = undefined;
        var found = false;
        var tmcache: u8 = 0;

        for (0..ltm.N) |i| {
            const val = Hgetstr(t, L.global.tmname[i]);
            metamethods[ltm.N - (i + 1)].setobj(L, val); // metamethods will be stored in reverse
            const has_value = !val.ttisnil();
            found = found or has_value;
            if (i <= @backingInt(ltm.TMS.TM_EQ) and !has_value)
                tmcache |= @as(u8, 1) << @intCast(i);
        }

        // update the metamethod presence cache
        t.tmcache = tmcache;

        // if there are metamethods, place the metamethod cache before the array elements
        if (found) jmp: {
            const size: usize = @intCast(t.sizearray);
            // if allocation fails, the optimization is skipped instead of erroring as an error might be unexpected from a table freeze
            const newarray = lmem.Mnewarray(L, TValue, size + ltm.N, t.header.memcat) catch |err| switch (err) {
                error.OutOfMemory => break :jmp,
                else => return err,
            };
            const oldarray = t.array;

            if (size != 0)
                @memcpy((newarray + ltm.N)[0..size], oldarray.?[0..size]);

            @memcpy(newarray[0..ltm.N], &metamethods);
            t.array = newarray + ltm.N;
            t.readonly |= 2;

            if (size != 0)
                lmem.Mfreearray(L, TValue, oldarray, size, t.header.memcat);
        }
    } else {
        // if we have a metamethod cache, transform the array part back to the original layout (or delete when sizearray is 0)
        if (lobject.hasmetacache(t)) {
            const old_array = t.array.?;
            const size: usize = @intCast(t.sizearray);
            var new_array: ?[*]TValue = null;

            if (size != 0) {
                new_array = try lmem.Mnewarray(L, TValue, size, t.header.memcat);
                @memcpy(new_array.?[0..size], old_array[0..size]);
            }

            t.array = new_array;
            lmem.Mfreearray(L, TValue, old_array - ltm.N, size + ltm.N, t.header.memcat);
        }
        t.readonly = 0;
    }
}

pub fn Hgetreadonly(t: *const LuaTable) bool {
    return t.readonly != 0;
}
