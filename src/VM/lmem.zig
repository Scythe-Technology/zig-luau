// This file is part of the Luau programming language and is licensed under MIT License; see LICENSE.txt for details
// This code is based on Lua 5.x implementation licensed under MIT License; see lua_LICENSE.txt for details

const std = @import("std");
const builtin = @import("builtin");

const lua = @import("lua.zig");
const lobject = @import("lobject.zig");

const lstate = @import("lstate.zig");
const ldo = @import("ldo.zig");
const ldebug = @import("ldebug.zig");

const Errorset = @import("errorset.zig");

const Error = Errorset.Memory;

//
// Luau heap uses a size-segregated page structure, with individual pages and large allocations
// allocated using system heap (via frealloc callback).
//
// frealloc callback serves as a general, if slow, allocation callback that can allocate, free or
// resize allocations:
//
//    void* frealloc(void* ud, void* ptr, size_t oldsize, size_t newsize);
//
// frealloc(ud, NULL, 0, x) creates a new block of size x
// frealloc(ud, p, x, 0) frees the block p (must return NULL)
// frealloc(ud, NULL, 0, 0) does nothing, equivalent to free(NULL)
//
// frealloc returns NULL if it cannot create or reallocate the area
// (any reallocation to an equal or smaller size cannot fail!)
//
// On top of this, Luau implements heap storage which is split into two types of allocations:
//
// - GCO, short for "garbage collected objects"
// - other objects (for example, arrays stored inside table objects)
//
// The heap layout for these two allocation types is a bit different.
//
// All GCO are allocated in pages, which is a block of memory of ~16K in size that has a page header
// (lua_Page). Each page contains 1..N blocks of the same size, where N is selected to fill the page
// completely. This amortizes the allocation cost and increases locality. Each GCO block starts with
// the GC header (GCheader) which contains the object type, mark bits and other GC metadata. If the
// GCO block is free (not used), then it must have the type set to TNIL; in this case the block can
// be part of the per-page free list, the link for that list is stored after the header (freegcolink).
//
// Importantly, the GCO block doesn't have any back references to the page it's allocated in, so it's
// impossible to free it in isolation - GCO blocks are freed by sweeping the pages they belong to,
// using luaM_freegco which must specify the page; this is called by page sweeper that traverses the
// entire page's worth of objects. For this reason it's also important that freed GCO blocks keep the
// GC header intact and accessible (with type = NIL) so that the sweeper can access it.
//
// Some GCOs are too large to fit in a 16K page without excessive fragmentation (the size threshold is
// currently 512 bytes); in this case, we allocate a dedicated small page with just a single block's worth
// storage space, but that requires allocating an extra page header. In effect large GCOs are a little bit
// less memory efficient, but this allows us to uniformly sweep small and large GCOs using page lists.
//
// All GCO pages are linked in a large intrusive linked list (global_State::allgcopages). Additionally,
// for each block size there's a page free list that contains pages that have at least one free block
// (global_State::freegcopages). This free list is used to make sure object allocation is O(1).
//
// When LUAU_ASSERTENABLED is enabled, all non-GCO pages are also linked in a list (global_State::allpages).
// Because this list is not strictly required for runtime operations, it is only tracked for the purposes of
// debugging. While overhead of linking those pages together is very small, unnecessary operations are avoided.
//
// Compared to GCOs, regular allocations have two important differences: they can be freed in isolation,
// and they don't start with a GC header. Because of this, each allocation is prefixed with block metadata,
// which contains the pointer to the page for allocated blocks, and the pointer to the next free block
// inside the page for freed blocks.
// For regular allocations that are too large to fit in a page (using the same threshold of 512 bytes),
// we don't allocate a separate page, instead simply using frealloc to allocate a vanilla block of memory.
//
// Just like GCO pages, we store a page free list (global_State::freepages) that allows O(1) allocation;
// there is no global list for non-GCO pages since we never need to traverse them directly.
//
// In both cases, we pick the page by computing the size class from the block size which rounds the block
// size up to reduce the chance that we'll allocate pages that have very few allocated blocks. The size
// class strategy is determined by SizeClassConfig constructor.
//
// Note that when the last block in a page is freed, we immediately free the page with frealloc - the
// memory manager doesn't currently attempt to keep unused memory around. This can result in excessive
// allocation traffic and can be mitigated by adding a page cache in the future.
//
// For both GCO and non-GCO pages, the per-page block allocation combines bump pointer style allocation
// (lua_Page::freeNext) and per-page free list (lua_Page::freeList). We use the bump allocator to allocate
// the contents of the page, and the free list for further reuse; this allows shorter page setup times
// which results in less variance between allocation cost, as well as tighter sweep bounds for newly
// allocated pages.
//

//
// The sizes of most Luau objects aren't crucial for code correctness, but they are crucial for memory efficiency
// To prevent some of them accidentally growing and us losing memory without realizing it, we're going to lock
// the sizes of all critical structures down.
//
fn ABISWITCH(b64: comptime_int, b32: comptime_int) comptime_int {
    if (@sizeOf(*anyopaque) == 8)
        return b64
    else
        return b32;
}

comptime {
    if (lua.config.VECTOR_SIZE == 4) {
        std.debug.assert(@sizeOf(lobject.TValue) == ABISWITCH(24, 24)); // size mismatch for value
        std.debug.assert(@sizeOf(lobject.LuaNode) == ABISWITCH(48, 48)); // size mismatch for table entry
    } else {
        std.debug.assert(@sizeOf(lobject.TValue) == ABISWITCH(16, 16)); // size mismatch for value
        std.debug.assert(@sizeOf(lobject.LuaNode) == ABISWITCH(32, 32)); // size mismatch for table entry
    }

    std.debug.assert(@offsetOf(lobject.TString, "data") == ABISWITCH(24, 20)); // size mismatch for string header
    std.debug.assert(@sizeOf(lobject.LuaTable) == ABISWITCH(48, 32)); // size mismatch for table header
    std.debug.assert(@offsetOf(lobject.Buffer, "data") == ABISWITCH(8, 8)); // size mismatch for buffer header

    // The userdata is designed to provide 16 byte alignment for 16 byte and larger userdata sizes
    std.debug.assert(@offsetOf(lobject.Udata, "data") == 16); // data must be at precise offset provide proper alignment
}

const kSizeClasses = lua.config.SIZECLASSES;

// Controls the number of entries in SizeClassConfig and define the maximum possible paged allocation size
// Modifications require updates the SizeClassConfig initialization
const kMaxSmallSize = 1024;

// Effective limit on object size to use paged allocation
// Can be modified without additional changes to code, provided it is smaller or equal to kMaxSmallSize
const kMaxSmallSizeUsed = 1024;

const kLargePageThreshold = 512; // larger pages are used for objects larger than this size to fit more of them into a page

// constant factor to reduce our page sizes by, to increase the chances that pages we allocate will
// allow external allocators to allocate them without wasting space due to rounding introduced by their heap meta data
const kExternalAllocatorMetaDataReduction = 24;

const kSmallPageSize = 16 * 1024 - kExternalAllocatorMetaDataReduction;
const kLargePageSize = 32 * 1024 - kExternalAllocatorMetaDataReduction;

const kBlockHeader = if (@sizeOf(f64) > @sizeOf(*anyopaque)) @sizeOf(f64) else @sizeOf(*anyopaque); // suitable for aligning double & void* on all platforms
const kGCOLinkOffset = (@sizeOf(lobject.GCheader) + @sizeOf(*anyopaque) - 1) & ~@as(usize, @sizeOf(*anyopaque) - 1); // GCO pages contain freelist links after the GC header

const SizeClassConfig = extern struct {
    const values = generateSizeOfClass();

    sizeOfClass: [kSizeClasses]c_int = values[0],
    classForSize: [kMaxSmallSize + 1]i8 = values[1],
    classCount: c_int = values[2],

    fn generateSizeOfClass() struct { [kSizeClasses]c_int, [kMaxSmallSize + 1]i8, comptime_int } {
        var classCount: comptime_int = 0;
        var sizeOfClass: [kSizeClasses]c_int = [_]c_int{0} ** kSizeClasses;
        var classForSize: [kMaxSmallSize + 1]i8 = [_]i8{-1} ** (kMaxSmallSize + 1);

        // we use a progressive size class scheme:
        // - all size classes are aligned by 8b to satisfy pointer alignment requirements
        // - we first allocate sizes classes in multiples of 8
        // - after the first cutoff we allocate size classes in multiples of 16
        // - after the second cutoff we allocate size classes in multiples of 32
        // - after the third cutoff we allocate size classes in multiples of 64
        // this balances internal fragmentation vs external fragmentation

        for ((8 / 8)..(64 / 8)) |i| {
            sizeOfClass[classCount] = i * 8;
            classCount += 1;
        }
        for ((64 / 16)..(256 / 16)) |i| {
            sizeOfClass[classCount] = i * 16;
            classCount += 1;
        }
        for ((256 / 32)..(512 / 32)) |i| {
            sizeOfClass[classCount] = i * 32;
            classCount += 1;
        }
        for ((512 / 64)..(1024 / 64) + 1) |i| {
            sizeOfClass[classCount] = i * 64;
            classCount += 1;
        }

        std.debug.assert(classCount <= kSizeClasses);

        // fill the lookup table for all classes
        for (0..classCount) |klass|
            classForSize[sizeOfClass[klass]] = @as(i8, @intCast(klass));

        // fill the gaps in lookup table
        {
            var size = kMaxSmallSize - 1;
            @setEvalBranchQuota(kMaxSmallSize + 128);
            while (size >= 0) : (size -= 1) {
                if (classForSize[size] < 0)
                    classForSize[size] = classForSize[size + 1];
            }
        }

        return .{ sizeOfClass, classForSize, classCount };
    }
};

const kSizeClassConfig: SizeClassConfig = .{};

// size class for a block of size sz; returns -1 for size=0 because empty allocations take no space
inline fn sizeclass(sz: usize) i8 {
    return if (sz -% 1 < kMaxSmallSizeUsed) kSizeClassConfig.classForSize[sz] else -1;
}

inline fn debugpageset(set: *?*lua_Page) ?*?*lua_Page {
    switch (comptime builtin.mode) {
        .ReleaseFast, .ReleaseSmall => return null, // ReleaseFast and ReleaseSmall defines NDEBUG
        else => return set, // ReleaseSafe and Debug does not define NDEBUG
    }
}

// metadata for a block is stored in the first pointer of the block
inline fn metadata(block: *anyopaque) *?*anyopaque {
    return @as(*?*anyopaque, @ptrCast(@alignCast(block)));
}
inline fn freegcolink(block: *anyopaque) *?*anyopaque {
    return @as(*?*anyopaque, @ptrFromInt(@intFromPtr(block) + kGCOLinkOffset));
}

pub const lua_Page = extern struct {
    // list of pages with free blocks
    prev: ?*lua_Page = null,
    next: ?*lua_Page = null,

    // list of all pages
    listprev: ?*lua_Page = null,
    listnext: ?*lua_Page = null,

    pageSize: c_int = 0, // page size in bytes, including page header
    blockSize: c_int = 0, // block size in bytes, including block header

    freeList: ?*anyopaque = null, // next free block in this page; linked with metadata()/freegcolink()
    freeNext: c_int = 0, // next free block offset in this page
    busyBlocks: c_int = 0, // number of blocks allocated out of this page

    // provide additional padding based on current object size to provide 16 byte alignment of data
    // later static_assert checks that this requirement is held
    padding: [if (@sizeOf(*anyopaque) == 8) 8 else 12]u8 = undefined,

    data: [1]u8,
};

comptime {
    std.debug.assert(@offsetOf(lua_Page, "data") % 16 == 0); // data must be 16 byte aligned to provide properly aligned allocation of userdata objects
}

fn Mtoobig(L: *lua.State) noreturn {
    ldebug.GrunerrorL(L, "memory allocation error: block too big");
}

fn newpage(L: *lua.State, pageset: ?*?*lua_Page, pageSize: usize, blockSize: c_int, blockCount: c_int) Error!*lua_Page {
    const g = L.global;

    std.debug.assert(pageSize - @offsetOf(lua_Page, "data") >= blockSize * blockCount);

    const page = @as(*lua_Page, @ptrCast(@alignCast(
        (g.frealloc.?)(g.ud, null, 0, pageSize) orelse return Error.OutOfMemory,
    )));

    // ASAN_POISON_MEMORY_REGION(...); // TODO: ASAN support

    // setup page header
    page.* = .{
        .prev = null,
        .next = null,

        .listprev = null,
        .listnext = null,

        .pageSize = @intCast(pageSize),
        .blockSize = blockSize,

        // note: we start with the last block in the page and move downward
        // either order would work, but that way we don't need to store the block count in the page
        // additionally, GC stores objects in singly linked lists, and this way the GC lists end up in increasing pointer order
        .freeList = null,
        .freeNext = (blockCount - 1) * blockSize,
        .busyBlocks = 0,

        .data = undefined,
    };

    if (pageset) |set| {
        page.listnext = set.*;
        if (page.listnext) |next|
            next.listprev = page;
        set.* = page;
    }

    return page;
}

// this is part of a cold path in newblock and newgcoblock
// it is marked as noinline to prevent it from being inlined into those functions
// if it is inlined, then the compiler may determine those functions are "too big" to be profitably inlined, which results in reduced performance
noinline fn newclasspage(L: *lua.State, freepageset: [*]?*lua_Page, pageset: ?*?*lua_Page, sizeClass: u8, storeMetadata: bool) Error!*lua_Page {
    const sizeOfClass = kSizeClassConfig.sizeOfClass[sizeClass];
    const pageSize: usize = if (sizeOfClass > @as(c_int, kLargePageThreshold)) kLargePageSize else kSmallPageSize;
    const blockSize = sizeOfClass + @as(c_int, if (storeMetadata) kBlockHeader else 0);
    const blockCount = @divTrunc(pageSize - @offsetOf(lua_Page, "data"), @as(usize, @intCast(blockSize)));

    const page = try newpage(L, pageset, pageSize, blockSize, @intCast(blockCount));

    // prepend a page to page freelist (which is empty because we only ever allocate a new page when it is!)
    std.debug.assert(freepageset[sizeClass] == null);
    freepageset[sizeClass] = page;

    return page;
}

fn freepage(L: *lua.State, pageset: ?*?*lua_Page, page: *lua_Page) void {
    const g = L.global;

    if (pageset) |set| {
        // remove page from alllist
        if (page.listnext) |next|
            next.listprev = page.listprev;

        if (page.listprev) |prev|
            prev.listnext = page.listnext
        else if (set.* == page)
            set.* = page.listnext;
    }

    // so long
    _ = (g.frealloc.?)(g.ud, @ptrCast(page), @intCast(page.pageSize), 0);
}

fn freeclasspage(L: *lua.State, freepageset: [*]?*lua_Page, pageset: ?*?*lua_Page, page: *lua_Page, sizeClass: u8) void {
    // remove page from freelist
    if (page.next) |next|
        next.prev = page.prev;

    if (page.prev) |prev|
        prev.next = page.next
    else if (freepageset[sizeClass] == page)
        freepageset[sizeClass] = page.next;

    freepage(L, pageset, page);
}

fn newblock(L: *lua.State, sizeClass: u8) Error!*anyopaque {
    const g = L.global;
    const page = g.freepages[sizeClass] orelse blk: {
        // slow path: no page in the freelist, allocate a new one
        break :blk try newclasspage(L, &g.freepages, &g.allpages, sizeClass, true);
    };

    std.debug.assert(page.prev == null);
    std.debug.assert(page.freeList != null or page.freeNext >= 0);
    std.debug.assert(page.blockSize == kSizeClassConfig.sizeOfClass[sizeClass] + kBlockHeader);

    var block: *anyopaque = undefined;

    if (page.freeNext >= 0) {
        block = @ptrFromInt(@intFromPtr(&page.data) + @as(usize, @intCast(page.freeNext)));
        // ASAN_UNPOISON_MEMORY_REGION(...); // TODO: ASAN support

        page.freeNext -= page.blockSize;
        page.busyBlocks += 1;
    } else {
        block = page.freeList.?;
        // ASAN_UNPOISON_MEMORY_REGION(...); // TODO: ASAN support

        page.freeList = metadata(block).*;
        page.busyBlocks += 1;
    }

    // the first word in a block point back to the page
    metadata(block).* = @ptrCast(@alignCast(page));

    // if we allocate the last block out of a page, we need to remove it from free list
    if (page.freeList == null and page.freeNext < 0) {
        g.freepages[sizeClass] = page.next;
        if (page.next) |next|
            next.prev = null;
        page.next = null;
    }

    // the user data is right after the metadata
    return @ptrFromInt(@intFromPtr(block) + kBlockHeader);
}

fn newgcoblock(L: *lua.State, sizeClass: u8) Error!*anyopaque {
    const g = L.global;
    const page = g.freegcopages[sizeClass] orelse blk: {
        // slow path: no page in the freelist, allocate a new one
        break :blk try newclasspage(L, &g.freegcopages, &g.allgcopages, sizeClass, false);
    };

    std.debug.assert(page.prev == null);
    std.debug.assert(page.freeList != null or page.freeNext >= 0);
    std.debug.assert(page.blockSize == kSizeClassConfig.sizeOfClass[sizeClass]);

    var block: *anyopaque = undefined;

    if (page.freeNext >= 0) {
        block = @ptrFromInt(@intFromPtr(&page.data) + @as(usize, @intCast(page.freeNext)));
        // ASAN_UNPOISON_MEMORY_REGION(...); // TODO: ASAN support

        page.freeNext -= page.blockSize;
        page.busyBlocks += 1;
    } else {
        block = page.freeList.?;
        // ASAN_UNPOISON_MEMORY_REGION(...); // TODO: ASAN support

        page.freeList = freegcolink(block).*;
        page.busyBlocks += 1;
    }

    // if we allocate the last block out of a page, we need to remove it from free list
    if (page.freeList == null and page.freeNext < 0) {
        g.freegcopages[sizeClass] = page.next;
        if (page.next) |next|
            next.prev = null;
        page.next = null;
    }

    return block;
}

fn freeblock(L: *lua.State, sizeClass: u8, iblock: *anyopaque) void {
    const g = L.global;

    // the user data is right after the metadata
    const block: *anyopaque = @ptrFromInt(@intFromPtr(iblock) - kBlockHeader);

    const page = @as(*lua_Page, @ptrCast(@alignCast(metadata(block).*)));
    std.debug.assert(page.busyBlocks > 0);
    std.debug.assert(page.blockSize == kSizeClassConfig.sizeOfClass[sizeClass] + kBlockHeader);
    std.debug.assert(@intFromPtr(block) >= @intFromPtr(&page.data) and @intFromPtr(block) < @intFromPtr(page) + @as(usize, @intCast(page.pageSize)));

    // if the page wasn't in the page free list, it should be now since it got a block!
    if (page.freeList == null and page.freeNext < 0) {
        std.debug.assert(page.prev == null);
        std.debug.assert(page.next == null);

        page.next = g.freepages[sizeClass];
        if (page.next) |next|
            next.prev = page;
        g.freepages[sizeClass] = page;
    }

    // add the block to the free list inside the page
    metadata(block).* = page.freeList;
    page.freeList = block;

    // ASAN_POISON_MEMORY_REGION(...); // TODO: ASAN support

    page.busyBlocks -= 1;

    // if it's the last block in the page, we don't need the page
    if (page.busyBlocks == 0)
        freeclasspage(L, &g.freepages, debugpageset(&g.allpages), page, sizeClass);
}

fn freegcoblock(L: *lua.State, sizeClass: u8, block: *anyopaque, page: *lua_Page) void {
    std.debug.assert(page.busyBlocks > 0);
    std.debug.assert(page.blockSize == kSizeClassConfig.sizeOfClass[sizeClass]);
    std.debug.assert(@intFromPtr(block) >= @intFromPtr(&page.data) and @intFromPtr(block) < @intFromPtr(page) + @as(usize, @intCast(page.pageSize)));

    const g = L.global;

    // if the page wasn't in the page free list, it should be now since it got a block!
    if (page.freeList == null and page.freeNext < 0) {
        std.debug.assert(page.prev == null);
        std.debug.assert(page.next == null);

        page.next = g.freegcopages[sizeClass];
        if (page.next) |next|
            next.prev = page;
        g.freegcopages[sizeClass] = page;
    }

    // when separate block metadata is not used, free list link is stored inside the block data itself
    freegcolink(block).* = page.freeList;
    page.freeList = block;

    // ASAN_POISON_MEMORY_REGION(...); // TODO: ASAN support

    page.busyBlocks -= 1;

    // if it's the last block in the page, we don't need the page
    if (page.busyBlocks == 0)
        freeclasspage(L, &g.freegcopages, debugpageset(&g.allgcopages), page, sizeClass);
}

pub fn Mnew_(L: *lua.State, nsize: usize, memcat: u8) Error!*anyopaque {
    const g = L.global;

    const nclass = sizeclass(nsize);

    const block = if (nclass >= 0)
        newblock(L, @intCast(nclass))
    else
        (g.frealloc.?)(g.ud, null, 0, nsize) orelse return Error.OutOfMemory;

    g.totalbytes += nsize;
    g.memcatbytes[memcat] += nsize;

    if (g.cb.onallocate) |onallocate| {
        @branchHint(.unlikely);
        onallocate(L, 0, nsize);
    }

    return block;
}

pub fn Mnewgco_(L: *lua.State, nsize: usize, memcat: u8) Error!*lstate.GCObject {
    // we need to accommodate space for link for free blocks (freegcolink)
    std.debug.assert(nsize >= kGCOLinkOffset + @sizeOf(*anyopaque));

    const g = L.global;

    const nclass = sizeclass(nsize);

    var block: *anyopaque = undefined;

    if (nclass >= 0) {
        block = try newgcoblock(L, @intCast(nclass));
    } else {
        const page = try newpage(L, &g.allgcopages, @offsetOf(lua_Page, "data") + nsize, @intCast(nsize), 1);

        block = @ptrCast(@alignCast(&page.data));
        // ASAN_UNPOISON_MEMORY_REGION(...); // TODO: ASAN support

        page.freeNext -= page.blockSize;
        page.busyBlocks += 1;
    }

    g.totalbytes += nsize;
    g.memcatbytes[memcat] += nsize;

    if (g.cb.onallocate) |onallocate| {
        @branchHint(.unlikely);
        onallocate(L, 0, nsize);
    }

    return @ptrCast(@alignCast(block));
}
pub inline fn Mnewgco(L: *lua.State, comptime T: type, nsize: usize, memcat: u8) !*T {
    return @ptrCast(@alignCast(try Mnewgco_(L, nsize, memcat)));
}

pub fn Mfree_(L: *lua.State, block: ?*anyopaque, osize: usize, memcat: u8) void {
    const g = L.global;
    std.debug.assert((osize == 0) == (block == null));

    const oclass = sizeclass(osize);

    if (oclass >= 0)
        freeblock(L, @intCast(oclass), block.?)
    else
        _ = (g.frealloc.?)(g.ud, @ptrCast(block), osize, 0);

    g.totalbytes -= osize;
    g.memcatbytes[memcat] -= osize;
}

pub fn Mfreegco_(L: *lua.State, block: ?*lstate.GCObject, osize: usize, memcat: u8, page: *lua_Page) void {
    const g = L.global;
    std.debug.assert((osize == 0) == (block == null));

    const oclass = sizeclass(osize);

    if (oclass >= 0) {
        block.?.gch.header.tt = @intFromEnum(lua.Type.Nil);

        freegcoblock(L, @intCast(oclass), @ptrCast(@alignCast(block.?)), page);
    } else {
        std.debug.assert(page.busyBlocks == 1);
        std.debug.assert(page.blockSize == osize);
        std.debug.assert(@intFromPtr(block.?) == @intFromPtr(&page.data));

        freepage(L, &g.allgcopages, page);
    }

    g.totalbytes -= osize;
    g.memcatbytes[memcat] -= osize;
}
pub inline fn Mfreegco(L: *lua.State, p: *lstate.GCObject, size: usize, memcat: u8, page: *lua_Page) void {
    std.debug.assert(p.gch.header.tt >= @intFromEnum(lua.Type.String));
    Mfreegco_(L, @ptrCast(@alignCast(p)), size, memcat, page);
}

pub fn Mrealloc_(L: *lua.State, block: ?*anyopaque, osize: usize, nsize: usize, memcat: u8) Error!?*anyopaque {
    const g = L.global;
    std.debug.assert((osize == 0) == (block == null));

    const nclass = sizeclass(nsize);
    const oclass = sizeclass(osize);
    var result: ?*anyopaque = undefined;

    // if either block needs to be allocated using a block allocator, we can't use realloc directly
    if (nclass >= 0 or oclass >= 0) {
        result = if (nclass >= 0)
            try newblock(L, @intCast(nclass))
        else
            (g.frealloc.?)(g.ud, null, 0, nsize) orelse if (nsize > 0) return Error.OutOfMemory else undefined;

        if (osize > 0 and nsize > 0) {
            const tsize = @min(osize, nsize);
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(result)))[0..tsize],
                @as([*]u8, @ptrCast(@alignCast(block.?)))[0..tsize],
            );
        }

        if (oclass >= 0)
            freeblock(L, @intCast(oclass), block.?)
        else
            _ = (g.frealloc.?)(g.ud, block, osize, 0);
    } else {
        result = (g.frealloc.?)(g.ud, block, osize, nsize) orelse return Error.OutOfMemory;
    }

    std.debug.assert((nsize == 0) == (result == null));
    g.totalbytes = (g.totalbytes - osize) + nsize;
    if (nsize < osize)
        g.memcatbytes[memcat] -= osize - nsize
    else
        g.memcatbytes[memcat] += nsize - osize;

    if (g.cb.onallocate) |onallocate| {
        @branchHint(.unlikely);
        onallocate(L, osize, nsize);
    }

    return result;
}

pub inline fn Marraysize_(n: usize, e: usize) Error!usize {
    if (n <= @divTrunc(std.math.maxInt(usize), e)) return n * e else return Error.BlockTooBig;
}
pub inline fn Mnewarray(L: *lua.State, comptime T: type, n: usize, memcat: u8) Error![*]T {
    return @ptrCast(@alignCast(try Mnew_(L, try Marraysize_(n, @sizeOf(T)), memcat)));
}
pub inline fn Mfreearray(L: *lua.State, comptime T: type, b: ?[*]T, n: usize, memcat: u8) void {
    Mfree_(L, @ptrCast(@alignCast(b)), n * @sizeOf(T), memcat);
}
pub inline fn Mreallocarray(L: *lua.State, comptime T: type, v: ?[*]T, oldn: usize, n: usize, memcat: u8) Error![*]T {
    return @ptrCast(@alignCast((try Mrealloc_(L, @ptrCast(@alignCast(v)), oldn * @sizeOf(T), try Marraysize_(n, @sizeOf(T)), memcat)).?));
}

pub fn Mgetpagewalkinfo(page: *lua_Page, start: *[*]u8, end: *[*]u8, busyBlocks: *c_int, blockSize: *c_int) void {
    const blockCount = @divTrunc(page.pageSize - @offsetOf(lua_Page, "data"), page.blockSize);

    std.debug.assert(page.freeNext >= -page.blockSize and page.freeNext <= (blockCount - 1) * page.blockSize);

    const data = @as([*]u8, @ptrCast(@alignCast(&page.data))); // silences ubsan when indexing page->data

    start.* = data[@intCast(page.freeNext + page.blockSize)..];
    end.* = data[@intCast(blockCount * page.blockSize)..];
    busyBlocks.* = page.busyBlocks;
    blockSize.* = page.blockSize;
}

pub fn Mgetpageinfo(page: *lua_Page, pageBlocks: *c_int, busyBlocks: *c_int, blockSize: *c_int, pageSize: *c_int) void {
    pageBlocks.* = @divTrunc(page.pageSize - @offsetOf(lua_Page, "data"), page.blockSize);
    busyBlocks.* = page.busyBlocks;
    blockSize.* = page.blockSize;
    pageSize.* = page.pageSize;
}

pub fn Mgetnextpage(page: *lua_Page) ?*lua_Page {
    return page.listnext;
}

pub fn Mvisitpage(
    page: *lua_Page,
    comptime T: type,
    context: T,
    comptime visitor: fn (context: T, page: *lua_Page, gco: *lstate.GCObject) bool,
) void {
    var start: [*]u8 = undefined;
    var end: [*]u8 = undefined;
    var busyBlocks: c_int = 0;
    var blockSize: c_int = 0;

    Mgetpagewalkinfo(page, &start, &end, &busyBlocks, &blockSize);

    var pos: [*]u8 = start;
    while (pos != end) : (pos += @as(u32, @intCast(blockSize))) {
        const gco: *lstate.GCObject = @ptrCast(@alignCast(pos));

        // skip memory blocks that are already freed
        if (gco.gch.header.tt == @intFromEnum(lua.Type.Nil))
            continue;

        // when true is returned it means that the element was deleted
        if (visitor(context, page, gco)) {
            std.debug.assert(busyBlocks > 0);
            busyBlocks -= 1;

            // if the last block was removed, page would be removed as well
            if (busyBlocks == 0)
                break;
        }
    }
}

pub fn Mvisitgco(
    L: *lua.State,
    comptime T: type,
    context: T,
    comptime visitor: fn (context: T, page: *lua_Page, gco: *lstate.GCObject) bool,
) void {
    const g = L.global;

    var curr: ?*lua_Page = g.allgcopages;
    while (curr) |page| {
        const next = page.listnext; // block visit might destroy the page

        Mvisitpage(page, T, context, visitor);

        curr = next;
    }
}
