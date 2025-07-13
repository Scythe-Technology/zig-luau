const c = @import("c");
const std = @import("std");

const lua = @import("lua.zig");
const lobject = @import("lobject.zig");

const lstate = @import("lstate.zig");
const ldebug = @import("ldebug.zig");
const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");
const lnumutils = @import("lnumutils.zig");

const MAXBITS = 26;
const MAXSIZE = 1 << MAXBITS;

const TValue = lobject.TValue;
const LuaNode = lobject.LuaNode;
const LuaTable = lobject.LuaTable;

const LUA_VECTOR_SIZE = lua.config.VECTOR_SIZE;

const Hdummynode: LuaNode = .{
    .val = .{ .extra = undefined, .tt = @intFromEnum(lua.Type.Nil), .value = undefined },
    .key = .{ .extra = undefined, .pi = .{ .tt = @intFromEnum(lua.Type.Nil), .next = 0 }, .value = undefined },
};

const dummynode: *const LuaNode = &Hdummynode;

pub inline fn gnode(t: *const LuaTable, i: usize) *LuaNode {
    return &t.node[i];
}

pub inline fn invalidateTMcache(t: *LuaTable) void {
    t.tmcache = 0;
}

pub inline fn hashpow2(t: *const LuaTable, n: u32) *LuaNode {
    return gnode(t, lobject.lmod(usize, n, lobject.sizenode(t)));
}
pub inline fn hashstr(t: *const LuaTable, str: *const lobject.TString) *LuaNode {
    return hashpow2(t, str.hash);
}
pub inline fn hashboolean(t: *const LuaTable, b: bool) *LuaNode {
    return hashpow2(t, if (b) 1 else 0);
}

pub fn hashpointer(t: *const LuaTable, p: ?*const anyopaque) *LuaNode {
    // we discard the high 32-bit portion of the pointer on 64-bit platforms as it doesn't carry much entropy anyway
    var h: u32 = if (p) |ptr| @truncate(@intFromPtr(ptr)) else 0;

    // MurmurHash3 32-bit finalizer
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;

    return hashpow2(t, h);
}

fn hashnum(t: *const LuaTable, n: f64) *LuaNode {
    comptime std.debug.assert(@sizeOf(f64) == @sizeOf(u32) * 2); // expected a 8-byte double;
    var i: [2]u32 = undefined;
    @memcpy(i[0..], &@as([2]u32, @bitCast(n)));

    // mask out sign bit to make sure -0 and 0 hash to the same value
    var h1: u32 = i[0];
    var h2: u32 = i[1] & 0x7fffffff;

    // finalizer from MurmurHash64B
    const m: u32 = 0x5bd1e995;

    h1 ^= h2 >> 18;
    h1 *%= m;
    h2 ^= h1 >> 22;
    h2 *%= m;
    h1 ^= h2 >> 17;
    h1 *%= m;
    h2 ^= h1 >> 19;
    h2 *%= m;

    // ... truncated to 32-bit output (normally hash is equal to (uint64_t(h1) << 32) | h2, but we only really need the lower 32-bit half)
    return hashpow2(t, h2);
}

fn hashvec(t: *const LuaTable, v: []const f32) *LuaNode {
    var i: [LUA_VECTOR_SIZE]u32 = undefined;
    @memcpy(i[0..], (@as([*]const u32, @ptrCast(@alignCast(v.ptr))))[0..LUA_VECTOR_SIZE]);

    // convert -0 to 0 to make sure they hash to the same value
    i[0] = if (i[0] == 0x80000000) 0 else i[0];
    i[1] = if (i[1] == 0x80000000) 0 else i[1];
    i[2] = if (i[2] == 0x80000000) 0 else i[2];

    // scramble bits to make sure that integer coordinates have entropy in lower bits
    i[0] ^= i[0] >> 17;
    i[1] ^= i[1] >> 17;
    i[2] ^= i[2] >> 17;

    // Optimized Spatial Hashing for Collision Detection of Deformable Objects
    var h: u32 = (i[0] * 73856093) ^ (i[1] * 19349663) ^ (i[2] * 83492791);

    if (comptime LUA_VECTOR_SIZE == 4) {
        i[3] = if (i[3] == 0x80000000) 0 else i[3];
        i[3] ^= i[3] >> 17;
        h ^= i[3] * 39916801;
    }

    return hashpow2(t, h);
}

fn mainposition(t: *const LuaTable, key: *const TValue) *LuaNode {
    comptime std.debug.assert(@sizeOf(LuaNode) == @sizeOf(TValue) * 2);
    comptime std.debug.assert(@alignOf(LuaNode) == @alignOf(TValue));
    comptime std.debug.assert(@alignOf(LuaNode) == 8);

    return switch (key.typeOf()) {
        .Number => hashnum(t, key.nvalue()),
        .Vector => hashvec(t, key.vvalue()),
        .String => hashstr(t, key.tsvalue()),
        .Boolean => hashboolean(t, key.bvalue()),
        .LightUserdata => hashpointer(t, key.pvalue()),
        else => hashpointer(t, @ptrCast(@alignCast(key.gcvalue()))),
    };
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

fn computesizes(nums: []const i32, narray: *i32) i32 {
    var i: u32 = 0;
    var twotoi: i32 = 1; // 2^i
    var a: i32 = 0; // number of elements smaller than 2^i
    var na: i32 = 0; // number of elements to go to array part
    var n: i32 = 0; // optimal size for array part
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

fn countint(key: f64, nums: []i32) i32 {
    const k = arrayindex(key);
    if (0 < k and k <= MAXSIZE) {
        // is `key' an appropriate array index?
        nums[@intCast(lobject.ceillog2(@intCast(k)))] += 1; // count as such
        return 1;
    }
    return 0;
}

fn numusearray(t: *const LuaTable, nums: []i32) i32 {
    var lg: u8 = 0;
    var ttlg: i32 = 1; // 2^lg
    var ause: i32 = 0; // summation of `nums'
    var i: u32 = 1; // count to traverse all array keys
    while (lg <= MAXBITS) : (lg += 1) { // for each slice
        defer ttlg *= 2;
        var lc: i32 = 0; // counter
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

fn numusehash(t: *const LuaTable, nums: []i32, pnasize: *i32) i32 {
    var totaluse: i32 = 0; // total number of elements
    var ause: i32 = 0; // summation of `nums'
    var i: usize = lobject.sizenode(t);
    while (i > 0) : (i -= 1) {
        const n = &t.node[i];
        if (!n.gval().ttisnil()) {
            if (n.gkey().ttisnumber())
                ause += countint(n.gkey().nvalue(), nums);
            totaluse += 1;
        }
    }
    pnasize.* += ause;
    return totaluse;
}

fn setarrayvector(L: *lua.State, t: *LuaTable, size: i32) !void {
    if (size > MAXSIZE)
        return error.@"table overflow";
    t.array = try lmem.Mreallocarray(L, TValue, t.array, @intCast(t.sizearray), @intCast(size), t.header.memcat);
    var i: usize = @intCast(t.sizearray);
    while (i < size) : (i += 1)
        t.array.?[i].setnilvalue();
    t.sizearray = size;
}

fn setnodevector(L: *lua.State, t: *LuaTable, _size: i32) !void {
    var size: usize = @intCast(_size);
    var lsize: u32 = 0;
    if (size == 0) { // no elements to hash part?
        t.node = @ptrCast(@alignCast(@constCast(dummynode))); // use common `dummynode'
    } else {
        lsize = @intCast(lobject.ceillog2(@truncate(size)));
        if (lsize > MAXBITS)
            return error.@"table overflow";
        size = @intCast(lobject.twoto(@truncate(lsize)));
        t.node = try lmem.Mnewarray(L, LuaNode, size, t.header.memcat);
        for (0..size) |i| {
            const n = t.gnode(i);
            n.key.setnext(0);
            n.gkey().pi.tt = @intFromEnum(lua.Type.Nil);
            n.gval().setnilvalue();
        }
    }
    t.lsizenode = @truncate(lsize);
    t.nodemask8 = @truncate((@as(usize, 1) << @truncate(lsize)) - 1);
    t.bound.lastfree = @intCast(size); // all positions are free
}

fn arrayornewkey(L: *lua.State, t: *LuaTable, key: *const TValue) !*TValue {
    if (key.ttisnumber()) {
        const n = key.nvalue();
        const k = lnumutils.inum2int(n);
        if (@as(f64, @floatFromInt(k)) == n and k - 1 < t.sizearray)
            return &t.array.?[@intCast(k - 1)];
    }

    return newkey(L, t, key);
}

fn resize(L: *lua.State, t: *LuaTable, nasize: i32, nhsize: i32) anyerror!void {
    if (nasize > MAXSIZE or nhsize > MAXSIZE)
        return error.@"table overflow";

    const oldasize: i32 = t.sizearray;
    const oldhsize: u8 = t.lsizenode;
    const nold = t.node; // save old hash ...
    if (nasize > oldasize) // array part must grow?
        try setarrayvector(L, t, nasize);

    // create new hash part with appropriate size
    try setnodevector(L, t, nhsize);
    // used for the migration check at the end
    const nnew = t.node;

    if (nasize < oldasize) { // array part must shrink?
        t.sizearray = nasize;
        // re-insert elements from vanishing slice
        var i: usize = @intCast(nasize);
        while (i < oldasize) : (i += 1) {
            if (!t.array.?[i].ttisnil()) {
                var ok: TValue = undefined;
                ok.setnvalue(@floatFromInt(i + 1));
                (try newkey(L, t, &ok)).setobj(L, &t.array.?[i]);
            }
        }
        // shrink array
        t.array = try lmem.Mreallocarray(L, TValue, t.array, @intCast(oldasize), @intCast(nasize), t.header.memcat);
    }

    // used for the migration check at the end
    const anew = t.array;

    // re-insert elements from hash part
    var i: i32 = @as(i32, @intCast(lobject.twoto(@truncate(oldhsize)))) - 1;
    while (i >= 0) : (i -= 1) {
        const old: *LuaNode = &nold[@intCast(i)];
        if (!old.gval().ttisnil()) {
            var ok: TValue = undefined;
            lobject.getnodekey(L, &ok, old);
            (try arrayornewkey(L, t, &ok)).setobj(L, old.gval());
        }
    }

    // make sure we haven't recursively rehashed during element migration
    std.debug.assert(nnew == t.node);
    std.debug.assert(anew == t.array);

    if (@as(*LuaNode, @ptrCast(nold)) != dummynode)
        lmem.Mfreearray(L, LuaNode, nold, lobject.twoto(@truncate(oldhsize)), t.header.memcat); // free old array
}

fn adjustasize(t: *LuaTable, size: i32, ek: ?*const TValue) i32 {
    const tbound: bool = @as(*LuaNode, @ptrCast(t.node)) != dummynode or size < t.sizearray;
    const ekindex: i32 = if (ek != null and ek.?.ttisnumber()) arrayindex(ek.?.nvalue()) else -1;
    // move the array size up until the boundary is guaranteed to be inside the array part
    var adjusted_size = size;
    while (adjusted_size + 1 == ekindex or (tbound and !Hgetnum(t, adjusted_size + 1).ttisnil()))
        adjusted_size += 1;
    return adjusted_size;
}

pub fn Hresizehash(L: *lua.State, t: *LuaTable, nhsize: i32) !void {
    try resize(L, t, t.sizearray, nhsize);
}

fn rehash(L: *lua.State, t: *LuaTable, ek: *const TValue) !void {
    var nums: [MAXBITS + 1]i32 = [_]i32{0} ** (MAXBITS + 1);
    var nasize = numusearray(t, nums[0..]); // count keys in array part
    var totaluse: i32 = nasize; // all those keys are integer keys
    totaluse += numusehash(t, nums[0..], &nasize); // count keys in hash part

    // count extra key
    if (ek.ttisnumber())
        nasize += countint(ek.nvalue(), nums[0..]);
    totaluse += 1;

    // compute new size for array part
    const na = computesizes(nums[0..], &nasize);
    var nh = totaluse - na;

    // enforce the boundary invariant; for performance, only do hash lookups if we must
    const nadjusted = adjustasize(t, nasize, ek);

    // count how many extra elements belong to array part instead of hash part
    const aextra = nadjusted - nasize;

    if (aextra != 0) {
        // we no longer need to store those extra array elements in hash part
        nh -= aextra;

        // because hash nodes are twice as large as array nodes, the memory we saved for hash parts can be used by array part
        // this follows the general sparse array part optimization where array is allocated when 50% occupation is reached
        nasize = nadjusted + aextra;

        // since the size was changed, it's again important to enforce the boundary invariant at the new size
        nasize = adjustasize(t, nasize, ek);
    }

    // resize the table to new computed sizes
    try resize(L, t, nasize, nh);
}

pub fn Hfree(L: *lua.State, t: *LuaTable, page: *lmem.lua_Page) void {
    if (@as(*LuaNode, @ptrCast(t.node)) != dummynode)
        lmem.Mfreearray(L, LuaNode, t.node, lobject.sizenode(t), t.header.memcat);
    if (t.array) |arr|
        lmem.Mfreearray(L, TValue, arr, @intCast(t.sizearray), t.header.memcat);
    lmem.Mfreegco(L, @ptrCast(@alignCast(t)), @sizeOf(LuaTable), t.header.memcat, page);
}

fn getfreepos(t: *LuaTable) ?*LuaNode {
    while (t.bound.lastfree > 0) {
        t.bound.lastfree -= 1;

        const n = gnode(t, @intCast(t.bound.lastfree));
        if (n.gval().ttisnil())
            return n;
    }
    return null; // could not find a free place
}

//
// inserts a new key into a hash table; first, check whether key's main
// position is free. If not, check whether colliding node is in its main
// position or not: if it is not, move colliding node to an empty place and
// put new key in its main position; otherwise (colliding node is in its main
// position), new key goes to an empty position.
//
fn newkey(L: *lua.State, t: *LuaTable, key: *const TValue) !*TValue {
    // enforce boundary invariant
    if (key.ttisnumber() and key.nvalue() == @as(f64, @floatFromInt(t.sizearray + 1))) {
        try rehash(L, t, key); // grow table

        // after rehash, numeric keys might be located in the new array part, but won't be found in the node part
        return arrayornewkey(L, t, key);
    }

    var mp = mainposition(t, key);
    if (!mp.gval().ttisnil() or mp == dummynode) {
        const n = getfreepos(t) orelse {
            // cannot find a free place?
            try rehash(L, t, key); // grow table

            // after rehash, numeric keys might be located in the new array part, but won't be found in the node part
            return arrayornewkey(L, t, key);
        }; // get a free place
        std.debug.assert(n != dummynode);
        var mk: TValue = undefined;
        lobject.getnodekey(L, &mk, mp);
        var othern = mainposition(t, &mk);
        if (othern != mp) { // is colliding node out of its main position?
            // yes; move colliding node into free position
            while (othern.add_num(othern.gnext()) != mp)
                othern = othern.add_num(othern.gnext()); // find previous
            othern.key.setnext(@intCast(n.sub(othern))); // redo the chain with `n' in place of `mp'
            n.* = mp.*; // copy colliding node into free pos. (mp->next also goes)
            if (mp.gnext() != 0) {
                n.key.setnext(n.gnext() + @as(i28, @truncate(@as(isize, @intCast(mp.sub(n)))))); // correct 'next'
                mp.key.setnext(0); // now 'mp' is free
            }
            mp.gval().setnilvalue();
        } else { // colliding node is in its own main position
            // new node will go into free position
            if (mp.gnext() != 0)
                n.key.setnext(@intCast((mp.add_num(mp.gnext())).sub(n))) // chain new position
            else
                std.debug.assert(n.gnext() == 0);
            mp.key.setnext(@truncate(@as(isize, @intCast(n.sub(mp)))));
            mp = n;
        }
    }
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
    if (@as(u32, @intCast(key - 1)) < @as(u32, @intCast(t.sizearray)))
        return &t.array.?[@as(u32, @intCast(key - 1))]
    else if (@as(*LuaNode, @ptrCast(t.node)) != dummynode) {
        // hash fallback
        const nk: f64 = @floatFromInt(key);
        var n = hashnum(t, nk);
        while (true) { // check whether `key' is somewhere in the chain
            if (n.gkey().ttisnumber() and n.gkey().nvalue() == nk)
                return n.gval(); // that's it
            if (n.gnext() == 0)
                break;
            n = n.add_num(n.gnext());
        }
    }
    return lobject.Onilobject;
}

pub fn Hgetstr(t: *LuaTable, key: *lobject.TString) *const TValue {
    var n = hashstr(t, key);
    while (true) { // check whether `key' is somewhere in the chain
        if (n.gkey().ttisstring() and n.gkey().tsvalue() == key)
            return n.gval(); // that's it
        if (n.gnext() == 0)
            break;
        n = n.add_num(n.gnext());
    }
    return lobject.Onilobject;
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
        const _boundary = @as(usize, if (!base[0].ttisnil()) 1 else 0) + base[0].sub(&t.array.?[0]);
        maybesetaboundary(t, @intCast(_boundary));
        return _boundary;
    } else {
        // validate boundary invariant
        std.debug.assert(@as(*lobject.LuaNode, @ptrCast(t.node)) == dummynode or Hgetnum(t, @intCast(array_size + 1)).ttisnil());
        return array_size;
    }
}

pub fn Hget(t: *LuaTable, key: *const TValue) *const TValue {
    switch (key.typeOf()) {
        .Nil => return lobject.Onilobject,
        .String => return Hgetstr(t, key.tsvalue()),
        .Number => {
            const k = lnumutils.inum2int(key.nvalue());
            if (@as(f64, @floatFromInt(k)) == key.nvalue()) // index is int?
                return Hgetnum(t, k); // use specialized version
            // else go through
        },
        else => {},
    }
    var n = mainposition(t, key);
    while (true) { // check whether `key' is somewhere in the chain
        if (lobject.OrawequalKey(n.gkey(), key)) {
            return n.gval(); // that's it
        }
        if (n.gnext() == 0)
            break;
        n = n.add_num(n.gnext());
    }
    return lobject.Onilobject; // not found
}

pub fn Hnewkey(L: *lua.State, t: *LuaTable, key: *const TValue) !*TValue {
    if (key.ttisnil())
        try ldebug.GrunerrorL(L, "table index is nil", .{});
    if (key.ttisnumber() and lnumutils.inumisnan(key.nvalue()))
        try ldebug.GrunerrorL(L, "table index is NaN", .{});
    if (key.ttisvector() and lnumutils.ivecisnan(key.vvalue()))
        try ldebug.GrunerrorL(L, "table index contains NaN", .{});
    return newkey(L, t, key);
}

pub fn Hsetnum(L: *lua.State, t: *LuaTable, key: i32) !*TValue {
    // (1 <= key && key <= t->sizearray)
    if (key - 1 < t.sizearray)
        return &t.array.?[@intCast(key - 1)];
    // hash fallback
    const p = Hgetnum(t, key);
    if (p != lobject.Onilobject)
        return @constCast(p)
    else {
        var k: TValue = undefined;
        k.setnvalue(@floatFromInt(key));
        return newkey(L, t, &k);
    }
}

pub fn Hsetstr(L: *lua.State, t: *LuaTable, key: *lobject.TString) !*TValue {
    const p = Hgetstr(t, key);
    invalidateTMcache(t);
    if (p != lobject.Onilobject)
        return @constCast(p)
    else {
        var k: TValue = undefined;
        k.setsvalue(L, key);
        return try newkey(L, t, &k);
    }
}

pub fn Hclone(L: *lua.State, tt: *LuaTable) !*LuaTable {
    const t = try lmem.Mnewgco(L, LuaTable, @sizeOf(LuaTable), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(t)), @intFromEnum(lua.Type.Table));
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
            n.gkey().setttype(.Nil);
            n.gval().setnilvalue();
            n.key.setnext(0);
        }
    }

    // back to empty -> no tag methods present
    tt.tmcache = ~@as(u8, 0);
}
