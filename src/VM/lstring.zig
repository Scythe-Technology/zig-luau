const std = @import("std");
const builtin = @import("builtin");

const lua = @import("lua.zig");
const lobject = @import("lobject.zig");

const lgc = @import("lgc.zig");
const lmem = @import("lmem.zig");

/// string size limit
pub const MAXSSIZE = (1 << 30);

/// string atoms are not defined by default; the storage is 16-bit integer
pub const ATOM_UNDEF = -32768;

inline fn sizestring(len: usize) usize {
    return @offsetOf(lobject.TString, "data") + len + 1;
}

pub fn Shash(str: []const u8) u32 {
    @setRuntimeSafety(false);
    // Note that this hashing algorithm is replicated in BytecodeBuilder.cpp, BytecodeBuilder::getStringHash
    var src = str;
    var len: usize = str.len;

    var a: u32 = 0;
    var b: u32 = 0;
    var h: u32 = @intCast(len);

    // hash prefix in 12b chunks (using aligned reads) with ARX based hash (LuaJIT v2.1, lookup3)
    // note that we stop at length<32 to maintain compatibility with Lua 5.1
    while (len >= 32) : (len -= 12) {
        var block: [12]u8 = undefined;
        @memcpy(&block, src[0..12]);

        a += std.mem.readInt(u32, block[0..4], builtin.cpu.arch.endian());
        b += std.mem.readInt(u32, block[4..8], builtin.cpu.arch.endian());
        h += std.mem.readInt(u32, block[8..12], builtin.cpu.arch.endian());

        // mix
        a ^= h;
        a -= ((h >> 14) | (h << (32 - 14)));
        b ^= a;
        b -= ((a >> 11) | (a << (32 - 11)));
        h ^= b;
        h -= ((b >> 25) | (b << (32 - 25)));

        src = src[12..];
    }

    // original Lua 5.1 hash for compatibility (exact match when len<32)
    var i: usize = len;
    while (i > 0) : (i -= 1) {
        h ^= (h << 5) + (h >> 2) + str[i - 1];
    }

    return h;
}

pub fn Sresize(L: *lua.State, newsize: usize) !void {
    const newhash = try lmem.Mnewarray(L, ?*lobject.TString, newsize, 0);
    const tb = &L.global.strt;
    for (0..newsize) |i|
        newhash[i] = null;
    // rehash
    for (0..@intCast(tb.size)) |i| {
        var p: ?*lobject.TString = tb.hash[i];
        while (p) |node| { // for each node in the list
            const next = node.next; // save next
            const h = node.hash;
            const h1 = lobject.lmod(usize, h, newsize); // new position
            std.debug.assert(h % newsize == h1);
            node.next = newhash[h1]; // chain it
            newhash[h1] = node;
            p = next;
        }
    }
    lmem.Mfreearray(L, ?*lobject.TString, tb.hash, @intCast(tb.size), 0);
    tb.size = @intCast(newsize);
    tb.hash = newhash;
}

fn newlstr(L: *lua.State, str: []const u8, hash: u32) !*lobject.TString {
    const l = str.len;
    if (l > MAXSSIZE)
        return error.BlockTooBig;

    const ts = try lmem.Mnewgco(L, lobject.TString, sizestring(l), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(ts)), @intFromEnum(lua.Type.String));
    ts.atom = ATOM_UNDEF;
    ts.hash = hash;
    ts.len = @intCast(l);

    @memcpy(ts.gdata()[0..l], str[0..l]);
    ts.gdata()[l] = 0; // ending 0

    const tb = &L.global.strt;
    const h: u32 = lobject.lmod(u32, hash, @intCast(tb.size));
    ts.next = tb.hash[h]; // chain new entry
    tb.hash[h] = ts;

    tb.nuse += 1;
    if (tb.nuse > tb.size and tb.size <= @divTrunc(std.math.maxInt(i32), 2))
        try Sresize(L, @intCast(tb.size * 2)); // too crowded

    return ts;
}

pub fn Sbufstart(L: *lua.State, size: usize) !*lobject.TString {
    if (size > MAXSSIZE)
        return error.BlockTooBig;

    const ts = try lmem.Mnewgco(L, lobject.TString, sizestring(size), L.activememcat);
    lgc.Cinit(L, @ptrCast(@alignCast(ts)), @intFromEnum(lua.Type.String));
    ts.atom = ATOM_UNDEF;
    ts.hash = 0; // computed in Sbuffinish
    ts.len = @intCast(size);

    ts.next = null;

    return ts;
}

pub fn Sbuffinish(L: *lua.State, ts: *lobject.TString) !*lobject.TString {
    const h = Shash(ts.gdata()[0..ts.len]);
    const tb = &L.global.strt;
    const bucket: u32 = lobject.lmod(u32, h, @intCast(tb.size));

    // search if we already have this string in the hash table
    var el: ?*lobject.TString = tb.hash[bucket];
    while (el) |node| : (el = node.next) {
        if (node.len == ts.len and std.mem.eql(u8, node.gdata()[0..ts.len], ts.gdata()[0..ts.len])) {
            // string may be dead
            if (lgc.isdead(L.global, @ptrCast(@alignCast(node))))
                lgc.changewhite(@ptrCast(@alignCast(node)));
            return node;
        }
    }

    std.debug.assert(ts.next == null);

    ts.hash = h;
    ts.gdata()[ts.len] = 0; // ending 0
    ts.next = tb.hash[bucket]; // chain new entry
    tb.hash[bucket] = ts;

    tb.nuse += 1;
    if (tb.nuse > tb.size and tb.size <= @divTrunc(std.math.maxInt(i32), 2))
        try Sresize(L, @intCast(tb.size * 2)); // too crowded

    return ts;
}

fn findstrnode(L: *lua.State, str: []const u8, h: u32) ?*lobject.TString {
    var el = L.global.strt.hash[lobject.lmod(u32, h, @intCast(L.global.strt.size))];
    while (el) |node| : (el = node.next) {
        if (node.len == str.len and std.mem.eql(u8, node.gdata()[0..node.len], str[0..str.len])) {
            // string may be dead
            if (lgc.isdead(L.global, @ptrCast(@alignCast(node))))
                lgc.changewhite(@ptrCast(@alignCast(node)));
            return node;
        }
    }
    return null; // not found
}

pub fn Snewlstr(L: *lua.State, str: []const u8) !*lobject.TString {
    const h = Shash(str);
    if (findstrnode(L, str, h)) |el|
        return el;
    return newlstr(L, str, h); // not found
}

pub fn Sassumelstr(L: *lua.State, str: []const u8) ?*lobject.TString {
    const h = Shash(str);
    return findstrnode(L, str, h);
}

fn unlinkstr(L: *lua.State, ts: *lobject.TString) bool {
    const g = L.global;

    var p = &g.strt.hash[lobject.lmod(u32, ts.hash, @intCast(g.strt.size))];

    while (p.*) |node| {
        if (node == ts) {
            p.* = node.next;
            return true;
        } else {
            p = &node.next;
        }
    }

    return false;
}

pub fn Sfree(L: *lua.State, ts: *lobject.TString, page: *lmem.lua_Page) void {
    if (unlinkstr(L, ts))
        L.global.strt.nuse -= 1
    else
        std.debug.assert(ts.next == null); // orphaned string buffer

    lmem.Mfreegco(L, @ptrCast(@alignCast(ts)), sizestring(ts.len), ts.header.memcat, page);
}
