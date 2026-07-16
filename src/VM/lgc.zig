const std = @import("std");

const build_config = @import("config");

const ltm = @import("ltm.zig");
const lmem = @import("lmem.zig");
const lperf = @import("lperf.zig");
const lfunc = @import("lfunc.zig");
const ltable = @import("ltable.zig");
const ludata = @import("ludata.zig");
const lclass = @import("lclass.zig");
const lstring = @import("lstring.zig");
const lbuffer = @import("lbuffer.zig");
const lcommon = @import("lcommon.zig");
const lgcdebug = @import("lgcdebug.zig");

const lua = @import("lua.zig");
const ldo = @import("ldo.zig");
const lstate = @import("lstate.zig");
const lobject = @import("lobject.zig");

const Errorset = @import("errorset.zig");

//
// Luau uses an incremental non-generational non-moving mark&sweep garbage collector.
//
// The collector runs in three stages: mark, atomic and sweep. Mark and sweep are incremental and try to do a limited amount
// of work every GC step; atomic is ran once per the GC cycle and is indivisible. In either case, the work happens during GC
// steps that are "scheduled" by the GC pacing algorithm - the steps happen either from explicit calls to lua_gc, or after
// the mutator (aka application) allocates some amount of memory, which is known as "GC assist". In either case, GC steps
// can't happen concurrently with other access to VM state.
//
// Current GC stage is stored in global_State::gcstate, and has two additional stages for pause and second-phase mark, explained below.
//
// GC pacer is an algorithm that tries to ensure that GC can always catch up to the application allocating garbage, but do this
// with minimal amount of effort. To configure the pacer Luau provides control over three variables: GC goal, defined as the
// target heap size during atomic phase in relation to live heap size (e.g. 200% goal means the heap's worst case size is double
// the total size of alive objects), step size (how many kilobytes should the application allocate for GC step to trigger), and
// GC multiplier (how much should the GC try to mark relative to how much the application allocated). It's critical that step
// multiplier is significantly above 1, as this is what allows the GC to catch up to the application's allocation rate, and
// GC goal and GC multiplier are linked in subtle ways, described in lua.h comments for LUA_GCSETGOAL.
//
// During mark, GC tries to identify all reachable objects and mark them as reachable, while keeping unreachable objects unmarked.
// During sweep, GC tries to sweep all objects that were not reachable at the end of mark. The atomic phase is needed to ensure
// that all pending marking has completed and all objects that are still marked as unreachable are, in fact, unreachable.
//
// Notably, during mark GC doesn't free any objects, and so the heap size constantly grows; during sweep, GC doesn't do any marking
// work, so it can't immediately free objects that became unreachable after sweeping started.
//
// Every collectable object has one of three colors at any given point in time: white, gray or black. This coloring scheme
// is necessary to implement incremental marking: white objects have not been marked and may be unreachable, black objects
// have been marked and will not be marked again if they stay black, and gray objects have been marked but may contain unmarked
// references.
//
// Objects are allocated as white; however, during sweep, we need to differentiate between objects that remained white in the mark
// phase (these are not reachable and can be freed) and objects that were allocated after the mark phase ended. Because of this, the
// colors are encoded using three bits inside GCheader::marked: white0, white1 and black (so technically we use a four-color scheme:
// any object can be white0, white1, gray or black). All bits are exclusive, and gray objects have all three bits unset. This allows
// us to have the "current" white bit, which is flipped during atomic stage - during sweeping, objects that have the white color from
// the previous mark may be deleted, and all other objects may or may not be reachable, and will be changed to the current white color,
// so that the next mark can start coloring objects from scratch again.
//
// Crucially, the coloring scheme comes with what's known as a tri-color invariant: a black object may never point to a white object.
//
// At the end of atomic stage, the expectation is that there are no gray objects anymore, which means all objects are either black
// (reachable) or white (unreachable = dead). Tri-color invariant is maintained throughout mark and atomic phase. To uphold this
// invariant, every modification of an object needs to check if the object is black and the new referent is white; if so, we
// need to either mark the referent, making it non-white (known as a forward barrier), or mark the object as gray and queue it
// for additional marking (known as a backward barrier).
//
// Luau uses both types of barriers. Forward barriers advance GC progress, since they don't create new outstanding work for GC,
// but they may be expensive when an object is modified many times in succession. Backward barriers are cheaper, as they defer
// most of the work until "later", but they require queueing the object for a rescan which isn't always possible. Table writes usually
// use backward barriers (but switch to forward barriers during second-phase mark), whereas upvalue writes and setmetatable use forward
// barriers.
//
// Since marking is incremental, it needs a way to track progress, which is implemented as a gray set: at any point, objects that
// are gray need to mark their white references, objects that are black have no pending work, and objects that are white have not yet
// been reached. Once the gray set is empty, the work completes; as such, incremental marking is as simple as removing an object from
// the gray set, and turning it to black (which requires turning all its white references to gray). The gray set is implemented as
// an intrusive singly linked list, using `gclist` field in multiple objects (functions, tables, threads and protos). When an object
// doesn't have gclist field, the marking of that object needs to be "immediate", changing the colors of all references in one go.
//
// When a black object is modified, it needs to become gray again. Objects like this are placed on a separate `grayagain` list by a
// barrier - this is important because it allows us to have a mark stage that terminates when the gray set is empty even if the mutator
// is constantly changing existing objects to gray. After mark stage finishes traversing `gray` list, we copy `grayagain` list to `gray`
// once and incrementally mark it again. During this phase of marking, we may get more objects marked as `grayagain`, so after we finish
// emptying out the `gray` list the second time, we finish the mark stage and do final marking of `grayagain` during atomic phase.
// GC works correctly without this second-phase mark (called GCSpropagateagain), but it reduces the time spent during atomic phase.
//
// Sweeping is also incremental, but instead of working at a granularity of an object, it works at a granularity of a page: all GC
// objects are allocated in special pages (see lmem.cpp for details), and sweeper traverses all objects in one page in one incremental
// step, freeing objects that aren't reachable (old white), and recoloring all other objects with the new white to prepare them for next
// mark. During sweeping we don't need to maintain the GC invariant, because our goal is to paint all objects with current white -
// however, some barriers will still trigger (because some reachable objects are still black as sweeping didn't get to them yet), and
// some barriers will proactively mark black objects as white to avoid extra barriers from triggering excessively.
//
// Most references that GC deals with are strong, and as such they fit neatly into the incremental marking scheme. Some, however, are
// weak - notably, tables can be marked as having weak keys/values (using __mode metafield). During incremental marking, we don't know
// for certain if a given object is alive - if it's marked as black, it definitely was reachable during marking, but if it's marked as
// white, we don't know if it's actually unreachable. Because of this, we need to defer weak table handling to the atomic phase; after
// all objects are marked, we traverse all weak tables (that are linked into special weak table lists using `gclist` during marking),
// and remove all entries that have white keys or values. If keys or values are strong, they are marked normally.
//
// The simplified scheme described above isn't fully accurate because of threads, upvalues and strings.
//
// Strings are semantically black (they are initially white, and when the mark stage reaches a string, it changes its color and never
// touches the object again), but they are technically marked as gray - the black bit is never set on a string object. This behavior
// is inherited from Lua 5.1 GC, but doesn't have a clear rationale - effectively, strings are marked as gray but are never part of
// a gray list.
//
// Threads are hard to deal with because for them to fit into the white-gray-black scheme, writes to thread stacks need to have barriers
// that turn the thread from black (already scanned) to gray - but this is very expensive because stack writes are very common. To
// get around this problem, threads have an "active" state which means that a thread is actively executing code. When GC reaches an active
// thread, it keeps it as gray, and rescans it during atomic phase. When a thread is inactive, GC instead paints the thread black. All
// API calls that can write to thread stacks outside of execution (which implies active) uses a thread barrier that checks if the thread is
// black, and if it is it marks it as gray and puts it on a gray list to be rescanned during atomic phase.
//
// Upvalues are special objects that can be closed, in which case they contain the value (acting as a reference cell) and can be dealt
// with using the regular algorithm, or open, in which case they refer to a stack slot in some other thread. These are difficult to deal
// with because the stack writes are not monitored. Because of this open upvalues are treated in a somewhat special way: they are never marked
// as black (doing so would violate the GC invariant), and they are kept in a special global list (global_State::uvhead) which is traversed
// during atomic phase. This is needed because an open upvalue might point to a stack location in a dead thread that never marked the stack
// slot - upvalues like this are identified since they don't have `markedopen` bit set during thread traversal and closed in `clearupvals`.
//

//
// Default settings for GC tunables (settable via lua_gc)
//
pub const I_GCGOAL = 200; // 200% (allow heap to double compared to live heap size)
pub const I_GCSTEPMUL = 200; // GC runs 'twice the speed' of memory allocation
pub const I_GCSTEPSIZE = 1; // GC runs every KB of memory allocation

//
// Possible states of the Garbage Collector
//
pub const GCSpause = 0;
pub const GCSpropagate = 1;
pub const GCSpropagateagain = 2;
pub const GCSatomic = 3;
pub const GCSsweep = 4;

pub inline fn keepinvariant(g: *const lstate.global_State) bool {
    return g.gcstate == GCSpropagate or g.gcstate == GCSpropagateagain or g.gcstate == GCSatomic;
}

pub inline fn testbits(x: u8, m: u8) u8 {
    return x & m;
}
pub inline fn bitmask(b: u8) u8 {
    return 1 << b;
}
pub inline fn bit2mask(b1: u8, b2: u8) u8 {
    return (1 << b1) | (1 << b2);
}
pub inline fn testbit(x: u8, b: u8) u8 {
    return testbits(x, bitmask(b));
}
pub inline fn test2bits(x: u8, b1: u8, b2: u8) u8 {
    return testbits(x, bit2mask(b1, b2));
}

///
/// Layout for bit use in `marked' field:
/// bit 0 - object is white (type 0)
/// bit 1 - object is white (type 1)
/// bit 2 - object is black
/// bit 3 - object is fixed (should not be collected)
///
pub const WHITE0BIT = 0;
pub const WHITE1BIT = 1;
pub const BLACKBIT = 2;
pub const FIXEDBIT = 3;
pub const WHITEBITS = bit2mask(WHITE0BIT, WHITE1BIT);

pub inline fn iswhite(x: *lstate.GCObject) bool {
    return test2bits(x.gch.header.marked, WHITE0BIT, WHITE1BIT) != 0;
}
pub inline fn isblack(x: *lstate.GCObject) bool {
    return testbit(x.gch.header.marked, BLACKBIT) != 0;
}
pub inline fn isgray(x: *lstate.GCObject) bool {
    return testbits(x.gch.header.marked, WHITEBITS | bitmask(BLACKBIT)) == 0;
}
pub inline fn isfixed(x: *lstate.GCObject) bool {
    return testbit(x.gch.header.marked, FIXEDBIT) != 0;
}

pub inline fn otherwhite(g: *const lstate.global_State) u8 {
    return g.currentwhite ^ WHITEBITS;
}
pub inline fn isdead(g: *const lstate.global_State, v: *const lstate.GCObject) bool {
    return (v.gch.header.marked & (WHITEBITS | bitmask(FIXEDBIT))) == (otherwhite(g) & WHITEBITS);
}

pub inline fn changewhite(x: *lstate.GCObject) void {
    x.gch.header.marked ^= WHITEBITS;
}
pub inline fn gray2black(x: *lstate.GCObject) void {
    x.gch.header.marked |= bitmask(BLACKBIT);
}

pub const GC_SWEEPPAGESTEPCOST = 16;

pub inline fn GC_INTERRUPT(g: *lstate.global_State, L: *lua.State, state: c_int) void {
    if (g.cb.interrupt) |interrupt| {
        @branchHint(.unlikely);
        interrupt(L, state);
    }
}

pub const maskmarks: u8 = ~(bitmask(BLACKBIT) | WHITEBITS);

pub inline fn makewhite(g: *lstate.global_State, x: *lstate.GCObject) void {
    x.gch.header.marked = (x.gch.header.marked & maskmarks) | Cwhite(g);
}

pub inline fn white2gray(x: *lstate.GCObject) void {
    x.gch.header.marked &= ~(bitmask(WHITE0BIT) | bitmask(WHITE1BIT));
}
pub inline fn black2gray(x: *lstate.GCObject) void {
    x.gch.header.marked &= ~(bitmask(BLACKBIT));
}

pub inline fn stringmark(s: *lobject.TString) void {
    s.header.marked &= ~(bitmask(WHITE0BIT) | bitmask(WHITE1BIT));
}

pub inline fn markvalue(g: *lstate.global_State, o: anytype) void {
    std.debug.assert(!o.iscollectable() or o.ttype() == o.value.gc.?.gch.header.tt);
    if (o.iscollectable() and iswhite(o.gcvalue()))
        reallymarkobject(g, o.gcvalue());
}

pub inline fn markobject(g: *lstate.global_State, t: *lstate.GCObject) void {
    if (iswhite(t))
        reallymarkobject(g, t);
}

pub inline fn Cwhite(g: *const lstate.global_State) u8 {
    return g.currentwhite & WHITEBITS;
}

pub inline fn CneedsGC(L: *const lua.State) bool {
    return L.global.totalbytes >= L.global.GCthreshold;
}

pub inline fn CcheckGC(L: *lua.State) Errorset.Table!void {
    if (comptime build_config.hard_stack_tests)
        try ldo.Dreallocstack(L, @intCast(L.stacksize - lstate.EXTRA_STACK), false);
    if (CneedsGC(L)) {
        if (comptime build_config.hard_mem_tests >= 1)
            lgcdebug.Cvalidate(L);
        _ = try Cstep(L, true);
    } else {
        if (comptime build_config.hard_mem_tests >= 2)
            lgcdebug.Cvalidate(L);
    }
}

pub inline fn Cbarrier(L: *lua.State, p: *lstate.GCObject, v: *const lobject.TValue) void {
    if (v.iscollectable() and isblack(p) and iswhite(v.gcvalue())) {
        Cbarrierf(L, p, v.gcvalue());
    }
}

pub inline fn Cbarriert(L: *lua.State, t: *lobject.LuaTable, v: *const lobject.TValue) void {
    if (v.iscollectable() and isblack(t.obj2gco()) and iswhite(v.gcvalue())) {
        Cbarriertable(L, t, v.gcvalue());
    }
}

pub inline fn Cbarrierfast(L: *lua.State, t: *lstate.GCObject) void {
    if (isblack(t))
        Cbarrierback(L, t, &L.gclist);
}

pub inline fn Cobjbarrier(L: *lua.State, p: *lstate.GCObject, o: *lstate.GCObject) void {
    if (isblack(p) and iswhite(o))
        Cbarrierf(L, p, o);
}

pub inline fn Cthreadbarrier(L: *lua.State) void {
    if (isblack(@ptrCast(@alignCast(L)))) {
        Cbarrierback(L, @ptrCast(@alignCast(L)), &L.gclist);
    }
}

pub inline fn Cobjectbarrier(L: *lua.State) void {
    if (isblack(@ptrCast(@alignCast(L)))) {
        Cbarrierback(L, @ptrCast(@alignCast(L)), &L.gclist);
    }
}

pub inline fn Cinit(L: *lua.State, o: *lstate.GCObject, tt: u8) void {
    o.gch.header.marked = Cwhite(L.global);
    o.gch.header.tt = tt;
    o.gch.header.memcat = L.activememcat;
}

fn removeentry(n: *lobject.LuaNode) void {
    std.debug.assert(n.gval().ttisnil());
    if (n.gkey().iscollectable())
        n.gkey().setttype(.Deadkey); // dead key; remove it
}

fn reallymarkobject(g: *lstate.global_State, o: *lstate.GCObject) void {
    std.debug.assert(iswhite(o) and !isdead(g, o));
    white2gray(o);
    switch (o.gch.ttype()) {
        @intFromEnum(lua.Type.String) => return,
        @intFromEnum(lua.Type.Userdata) => {
            const mt = o.tou().metatable;
            gray2black(o); // udata are never gray
            if (mt) |t|
                markobject(g, @ptrCast(@alignCast(t)));
        },
        @intFromEnum(lua.Type.UpVal) => {
            const uv = o.touv();
            markvalue(g, uv.v);
            if (!uv.upisopen()) // closed?
                gray2black(o); // open upvalues are never black
            return;
        },
        @intFromEnum(lua.Type.Function) => {
            o.tocl().gclist = g.gray;
            g.gray = o;
            return;
        },
        @intFromEnum(lua.Type.Table) => {
            o.toh().gclist = g.gray;
            g.gray = o;
            return;
        },
        @intFromEnum(lua.Type.Thread) => {
            o.toth().gclist = g.gray;
            g.gray = o;
            return;
        },
        @intFromEnum(lua.Type.Buffer) => {
            gray2black(o); // buffers are never gray
            return;
        },
        @intFromEnum(lua.Type.Proto) => {
            o.top().gclist = g.gray;
            g.gray = o;
            return;
        },
        else => unreachable,
    }
}

fn gettablemode(g: *lstate.global_State, h: *lobject.LuaTable) ?[:0]const u8 {
    const mode = ltm.gfasttm(g, h.metatable, .TM_MODE);
    if (mode) |m|
        if (m.ttisstring())
            return m.tsvalue().toSlice();
    return null; // no weak mode
}

fn traversetable(g: *lstate.global_State, h: *lobject.LuaTable) bool {
    var i: usize = 0;
    var weakkey: bool = false;
    var weakvalue: bool = false;
    if (h.metatable) |mt|
        markobject(g, @ptrCast(@alignCast(mt)));

    // is there a weak mode?
    if (gettablemode(g, h)) |modev| {
        weakkey = (std.mem.indexOfScalar(u8, modev, 'k') != null);
        weakvalue = (std.mem.indexOfScalar(u8, modev, 'v') != null);
        if (weakkey or weakvalue) { // is really weak?
            h.gclist = g.weak; // must be cleared after GC, ...
            g.weak = h.obj2gco(); // ... so put in the appropriate list
        }
    }

    if (weakkey and weakvalue)
        return true;
    if (!weakvalue) {
        i = @intCast(h.sizearray);
        while (i > 0) : (i -= 1)
            markvalue(g, &h.array.?[i - 1]);
    }
    i = lobject.sizenode(h);
    while (i > 0) : (i -= 1) {
        const n: *lobject.LuaNode = @ptrCast(h.gnode(i - 1));
        std.debug.assert(n.gkey().ttype() != @intFromEnum(lua.Type.Deadkey) or n.gval().ttisnil());
        if (n.gval().ttisnil())
            removeentry(@ptrCast(n)) // remove empty entries
        else {
            std.debug.assert(!n.gkey().ttisnil());
            if (!weakkey)
                markvalue(g, n.gkey());
            if (!weakvalue)
                markvalue(g, n.gval());
        }
    }
    return weakkey or weakvalue;
}

/// All marks are conditional because a GC may happen while the
/// prototype is still being created
fn traverseproto(g: *lstate.global_State, f: *lobject.Proto) void {
    if (f.source) |s|
        stringmark(s);
    if (f.debugname) |d|
        stringmark(d);
    for (0..@intCast(f.sizek)) |i| // mark literals
        markvalue(g, &f.k.?[i]);
    for (0..@intCast(f.sizeupvalues)) |i| { // mark upvalue names
        if (f.upvalues.?[i]) |n|
            stringmark(n);
    }
    for (0..@intCast(f.sizep)) |i| { // mark nested protos
        if (f.p.?[i]) |proto|
            markobject(g, @ptrCast(@alignCast(proto)));
    }
    for (0..@intCast(f.sizelocvars)) |i| { // mark local-variable names
        if (f.locvars.?[i].varname) |varname|
            stringmark(varname);
    }
}

fn traverseclosure(g: *lstate.global_State, cl: *lobject.Closure) void {
    markobject(g, @ptrCast(@alignCast(cl.env)));
    if (cl.isC != 0) {
        for (cl.d.c.upvalues()[0..cl.nupvalues]) |*upval| // mark its upvalues
            markvalue(g, upval);
    } else {
        std.debug.assert(cl.nupvalues == cl.d.l.p.nups);
        markobject(g, @ptrCast(@alignCast(cl.d.l.p)));
        for (cl.d.l.upreferences()[0..cl.nupvalues]) |*upref| // mark its upvalues
            markvalue(g, upref);
    }
}

fn traversestack(g: *lstate.global_State, L: *lua.State) void {
    markobject(g, @ptrCast(@alignCast(L.gt)));
    if (L.namecall) |nc|
        stringmark(nc);
    for (L.stack[0..(L.top - L.stack)]) |*o|
        markvalue(g, o);
    var uv: ?*lobject.UpVal = L.openupval;
    while (uv) |u| : (uv = u.u.open.threadnext) {
        std.debug.assert(u.upisopen());
        u.markedopen = 1;
        markobject(g, @ptrCast(@alignCast(u)));
    }
}

fn traverseclassobject(g: *lstate.global_State, classobject: *lobject.LuauClass) void {
    markobject(g, @ptrCast(@alignCast(classobject.name)));
    markobject(g, @ptrCast(@alignCast(classobject.memberstooffset)));
    for (0..@intCast(classobject.numberofallmembers)) |i|
        markobject(g, @ptrCast(@alignCast(classobject.offsettomember[i])));
    for (0..@intCast(classobject.numberofallmembers - classobject.numberofinstancemembers)) |i|
        markobject(g, @ptrCast(@alignCast(&classobject.staticmembers[i])));
    markobject(g, @ptrCast(@alignCast(classobject.metatable)));
    if (classobject.instancemetatable) |mt|
        markobject(g, @ptrCast(@alignCast(mt)));
}

fn traverseclassinstances(g: *lstate.global_State, classinst: *lobject.LuauObject) void {
    markobject(g, @ptrCast(@alignCast(classinst.lclass)));
    for (0..@intCast(classinst.numberofmembers)) |i|
        markobject(g, @ptrCast(@alignCast(&classinst.members[i])));
}

fn clearstack(L: *lua.State) void {
    const stack_end = L.stack + @as(usize, @intCast(L.stacksize));
    for (L.top[0..(stack_end - L.top)]) |*o| // clear not-marked stack slice
        o.setnilvalue();
}

fn shrinkstack(L: *lua.State) Errorset.Memory!void {
    // compute used stack - note that we can't use th->top if we're in the middle of vararg call
    var lim = L.top;
    for (L.base_ci.?[0 .. (L.ci.? - L.base_ci.?) + 1]) |*ci| { // iterate through callinfo
        std.debug.assert(@intFromPtr(ci.top) <= @intFromPtr(L.stack_last));
        if (@intFromPtr(lim) < @intFromPtr(ci.top))
            lim = ci.top;
    }

    // shrink stack and callinfo arrays if we aren't using most of the space
    const ci_used = L.ci.? - L.base_ci.?; // number of `ci' in use
    const s_used = lim - L.stack; // part of stack in use
    if (L.size_ci > lua.config.I_MAXCALLS) // handling overflow?
        return; // do not touch the stacks

    if (3 * ci_used < L.size_ci and 2 * lstate.BASIC_CI_SIZE < L.size_ci)
        try ldo.DreallocCI(L, @divTrunc(@as(usize, @intCast(L.size_ci)), 2)); // still big enough...
    if (comptime build_config.hard_stack_tests)
        try ldo.DreallocCI(L, ci_used + 1);

    if (3 * s_used < L.stacksize and 2 * (lstate.BASIC_STACK_SIZE + lstate.EXTRA_STACK) < L.stacksize)
        try ldo.Dreallocstack(L, @divTrunc(@as(usize, @intCast(L.stacksize)), 2), false); // still big enough...
    if (comptime build_config.hard_stack_tests)
        try ldo.Dreallocstack(L, s_used, false);
}

fn propagatemark(g: *lstate.global_State) Errorset.Memory!usize {
    const o = g.gray.?;
    std.debug.assert(isgray(o));
    gray2black(o);
    switch (o.gch.ttype()) {
        @intFromEnum(lua.Type.Table) => {
            const h = o.toh();
            g.gray = h.gclist;
            if (traversetable(g, h)) // table is weak?
                black2gray(o); // keep it gray
            return @sizeOf(lobject.LuaTable) + @sizeOf(lobject.TValue) * @as(u32, @intCast(h.sizearray)) + @sizeOf(lobject.LuaNode) * lobject.sizenode(h);
        },
        @intFromEnum(lua.Type.Function) => {
            const cl = o.tocl();
            g.gray = cl.gclist;
            traverseclosure(g, cl);
            return if (cl.isC != 0) lfunc.sizeCclosure(cl.nupvalues) else lfunc.sizeLclosure(cl.nupvalues);
        },
        @intFromEnum(lua.Type.Thread) => {
            const th = o.toth();
            g.gray = th.gclist;
            const active = th.isactive or th == th.global.mainthread;

            traversestack(g, th);

            // active threads will need to be rescanned later to mark new stack writes so we mark them gray again
            if (active) {
                th.gclist = g.grayagain;
                g.grayagain = o;

                black2gray(o);
            }

            // the stack needs to be cleared after the last modification of the thread state before sweep begins
            // if the thread is inactive, we might not see the thread in this cycle so we must clear it now
            if (!active or g.gcstate == GCSatomic)
                clearstack(th);

            // we could shrink stack at any time but we opt to do it during initial mark to do that just once per cycle
            if (g.gcstate == GCSpropagate)
                try shrinkstack(th);

            return @sizeOf(lua.State) +
                (@sizeOf(lobject.TValue) * @as(u32, @intCast(th.stacksize))) +
                (@sizeOf(lstate.CallInfo) * @as(u32, @intCast(th.size_ci)));
        },
        @intFromEnum(lua.Type.Proto) => {
            const p = o.top();
            g.gray = p.gclist;
            traverseproto(g, p);

            return @sizeOf(lobject.Proto) + (@sizeOf(lcommon.Instruction) * @as(u32, @intCast(p.sizecode))) +
                (@sizeOf(*lobject.Proto) * @as(u32, @intCast(p.sizep))) +
                (@sizeOf(lobject.TValue) * @as(u32, @intCast(p.sizek))) +
                @as(u32, @intCast(p.sizelineinfo)) +
                (@sizeOf(lobject.LocVar) * @as(u32, @intCast(p.sizelocvars))) +
                (@sizeOf(lobject.UpVal) * @as(u32, @intCast(p.sizeupvalues))) +
                @as(u32, @intCast(p.sizetypeinfo));
        },
        @intFromEnum(lua.Type.Class) => {
            const classobject = o.toclass();
            g.gray = classobject.gclist;
            traverseclassobject(g, classobject);
            return @sizeOf(lobject.LuauClass) +
                (@as(u32, @intCast(classobject.numberofallmembers)) - @as(u32, @intCast(classobject.numberofinstancemembers))) * @sizeOf(lobject.TValue) +
                @as(u32, @intCast(classobject.numberofallmembers)) * @sizeOf(*lobject.TString);
        },
        @intFromEnum(lua.Type.Object) => {
            const classinst = o.toobject();
            g.gray = classinst.gclist;
            traverseclassinstances(g, classinst);
            return @sizeOf(lobject.LuauObject) +
                (@as(u32, @intCast(classinst.numberofmembers)) * @sizeOf(lobject.TValue));
        },
        else => unreachable,
    }
    return 0;
}

fn propagateall(g: *lstate.global_State) Errorset.Memory!usize {
    var work: usize = 0;
    while (g.gray != null)
        work += try propagatemark(g);
    return work;
}

///
/// The next function tells whether a key or value can be cleared from
/// a weak table. Non-collectable objects are never removed from weak
/// tables. Strings behave as `values', so are never removed too. for
/// other objects: if really collected, cannot keep them.
///
fn isobjcleared(o: *lstate.GCObject) bool {
    if (o.gch.ttype() == @intFromEnum(lua.Type.String)) {
        stringmark(&o.ts); // strings are `values', so are never weak
        return false;
    }
    return iswhite(o);
}

pub inline fn iscleared(o: anytype) bool {
    return o.iscollectable() and isobjcleared(o.gcvalue());
}

/// clear collected entries from weaktables
fn cleartable(L: *lua.State, il: ?*lstate.GCObject) Errorset.Table!usize {
    var work: usize = 0;
    var ol: ?*lstate.GCObject = il;
    while (ol) |l| {
        const h = l.toh();
        work += @sizeOf(lobject.LuaTable) + (@sizeOf(lobject.TValue) * @as(u32, @intCast(h.sizearray))) + (@sizeOf(lobject.LuaNode) * lobject.sizenode(h));

        var i: usize = @intCast(h.sizearray);
        while (i > 0) : (i -= 1) {
            const o = &h.array.?[i - 1];
            if (iscleared(o)) // value was collected?
                o.setnilvalue(); // remove value
        }
        i = lobject.sizenode(h);
        var activevalues: usize = 0;
        while (i > 0) : (i -= 1) {
            const n: *lobject.LuaNode = @ptrCast(h.gnode(i - 1));

            // non-empty entry?
            if (!n.gval().ttisnil()) {
                // can we clear key or value?
                if (iscleared(n.gkey()) or iscleared(n.gval())) {
                    n.gval().setnilvalue(); // remove value ...
                    removeentry(n); // remove entry from table
                } else {
                    activevalues += 1;
                }
            }
        }

        if (gettablemode(L.global, h)) |mode| {
            // are we allowed to shrink this weak table?
            if (std.mem.indexOfScalar(u8, mode, 's') != null) {
                // shrink at 37.5% occupancy
                if (activevalues < @divTrunc(lobject.sizenode(h) * 3, 8))
                    try ltable.Hresizehash(L, h, activevalues);
            }
        }

        ol = h.gclist;
    }
    return work;
}

fn freeobj(L: *lua.State, o: *lstate.GCObject, page: *lmem.lua_Page) void {
    switch (o.gch.header.tt) {
        @intFromEnum(lua.Type.Proto) => lfunc.Ffreeproto(L, o.top(), page),
        @intFromEnum(lua.Type.Function) => lfunc.Ffreeclosure(L, o.tocl(), page),
        @intFromEnum(lua.Type.UpVal) => lfunc.Ffreeupval(L, o.touv(), page),
        @intFromEnum(lua.Type.Table) => ltable.Hfree(L, o.toh(), page),
        @intFromEnum(lua.Type.Thread) => {
            std.debug.assert(o.toth() != L and o.toth() != L.global.mainthread);
            lstate.Efreethread(L, o.toth(), page);
        },
        @intFromEnum(lua.Type.String) => lstring.Sfree(L, o.tots(), page),
        @intFromEnum(lua.Type.Userdata) => ludata.Ufreeudata(L, o.tou(), page),
        @intFromEnum(lua.Type.Buffer) => lbuffer.Bfreebuffer(L, o.tobuf(), page),
        @intFromEnum(lua.Type.Class) => lclass.Rfreeclass(L, o.toclass(), page),
        @intFromEnum(lua.Type.Object) => lclass.Rfreeobject(L, o.toobject(), page),
        else => unreachable,
    }
}

fn shrinkbuffers(L: *lua.State) Errorset.Memory!void {
    const g = L.global;
    // check size of string hash
    if (g.strt.nuse < @divTrunc(g.strt.size, 4) and g.strt.size > lua.config.MINSTRTABSIZE * 2)
        try lstring.Sresize(L, @intCast(@divTrunc(g.strt.size, 2))); // table is too big
}

fn shrinkbuffersfull(L: *lua.State) Errorset.Memory!void {
    const g = L.global;
    // check size of string hash
    var hashsize = g.strt.size;
    while (g.strt.nuse < @divTrunc(hashsize, 4) and hashsize > lua.config.MINSTRTABSIZE * 2)
        hashsize = @divTrunc(hashsize, 2);
    if (hashsize != g.strt.size)
        try lstring.Sresize(L, hashsize); // table is too big
}

fn deletegco(L: *lua.State, page: *lmem.lua_Page, gco: *lstate.GCObject) bool {
    freeobj(L, gco, page);
    return true;
}

pub fn Cfreeall(L: *lua.State) void {
    const g = L.global;
    std.debug.assert(L == g.mainthread);

    lmem.Mvisitgco(L, *lua.State, L, deletegco);

    for (0..@intCast(g.strt.size)) |i| // free all string lists
        std.debug.assert(g.strt.hash.?[i] == null);

    std.debug.assert(L.global.strt.nuse == 0);
}

fn markudatadirectfields(g: *lstate.global_State) void {
    for (0..ludata.UTAG_INTERNAL_LIMIT) |i| {
        if (g.udatadirectfields[i]) |f|
            markobject(g, f.obj2gco());
    }
}

fn markmt(g: *lstate.global_State) void {
    for (0..lua.Type.T_COUNT) |i| {
        if (g.mt[i]) |mt|
            markobject(g, @ptrCast(@alignCast(mt)));
    }
}

fn marktaggedmt(g: *lstate.global_State) void {
    for (0..lua.config.UTAG_LIMIT) |i| {
        if (g.udatamt[i]) |mt|
            markobject(g, @ptrCast(@alignCast(mt)));
    }
}

fn markroot(L: *lua.State) void {
    const g = L.global;
    g.gray = null;
    g.grayagain = null;
    g.weak = null;
    markobject(g, @ptrCast(@alignCast(g.mainthread)));
    // make global table be traversed before main stack
    markobject(g, @ptrCast(@alignCast(g.mainthread.gt)));
    markvalue(g, L.registry());

    for (0..ludata.UTAG_INTERNAL_LIMIT) |i| {
        const udatadirect = &L.global.udatadirect[i];

        markvalue(g, &udatadirect.indextm);
        markvalue(g, &udatadirect.newindextm);
        markvalue(g, &udatadirect.namecalltm);
    }

    markudatadirectfields(g);

    markmt(g);
    marktaggedmt(g);

    g.gcstate = GCSpropagate;
}

fn remarkupvals(g: *lstate.global_State) usize {
    var work: usize = 0;

    var uv: *lobject.UpVal = g.uvhead.u.open.next orelse return 0;
    while (uv != &g.uvhead) : (uv = uv.u.open.next.?) {
        work += @sizeOf(lobject.UpVal);

        std.debug.assert(uv.upisopen());
        std.debug.assert(uv.u.open.next.?.u.open.prev == uv and uv.u.open.prev.?.u.open.next == uv);
        std.debug.assert(!isblack(uv.obj2gco())); // open upvalues are never black

        if (isgray(uv.obj2gco()))
            markvalue(g, uv.v);
    }

    return work;
}

fn clearupvals(L: *lua.State) usize {
    const g = L.global;

    var work: usize = 0;

    var count: usize = 0;
    var uv: *lobject.UpVal = g.uvhead.u.open.next orelse return 0;
    while (uv != &g.uvhead) {
        defer count += 1;
        work += @sizeOf(lobject.UpVal);

        std.debug.assert(uv.upisopen());
        std.debug.assert(uv.u.open.next.?.u.open.prev == uv and uv.u.open.prev.?.u.open.next == uv);
        std.debug.assert(!isblack(uv.obj2gco())); // open upvalues are never black
        std.debug.assert(iswhite(uv.obj2gco()) or !uv.v.iscollectable() or !iswhite(uv.v.gcvalue()));

        if (uv.markedopen != 0) {
            // upvalue is still open (belongs to alive thread)
            std.debug.assert(isgray(uv.obj2gco()));
            uv.markedopen = 0; // for next cycle
            uv = uv.u.open.next.?;
        } else {
            // upvalue is either dead, or alive but the thread is dead; unlink and close
            const next = uv.u.open.next.?;
            lfunc.Fcloseupval(L, uv, iswhite(uv.obj2gco()));
            uv = next;
        }
    }

    return work;
}

fn atomic(L: *lua.State) Errorset.Table!usize {
    const g = L.global;
    std.debug.assert(g.gcstate == GCSatomic);

    var work: usize = 0;

    // TODO: LUAI_GCMETRICS

    // remark occasional upvalues of (maybe) dead threads
    work += remarkupvals(g);
    // traverse objects caught by write barrier and by 'remarkupvals'
    work += try propagateall(g);

    // TODO: LUAI_GCMETRICS

    // remark weak tables
    g.gray = g.weak;
    g.weak = null;
    std.debug.assert(!iswhite(@ptrCast(@alignCast(g.mainthread))));
    markobject(g, @ptrCast(@alignCast(L))); // mark running thread
    markmt(g); // mark basic metatables (again)

    marktaggedmt(g); // mark tagged userdata metatables (again)

    markudatadirectfields(g); // mark direct field dispatch tables (again)

    work += try propagateall(g);

    // TODO: LUAI_GCMETRICS

    // remark gray again
    g.gray = g.grayagain;
    g.grayagain = null;
    work += try propagateall(g);

    // TODO: LUAI_GCMETRICS

    // remove collected objects from weak tables
    work += try cleartable(L, g.weak);
    g.weak = null;

    // TODO: LUAI_GCMETRICS

    // close orphaned live upvalues of dead threads and clear dead upvalues
    work += clearupvals(L);

    // TODO: LUAI_GCMETRICS

    // flip current white
    g.currentwhite = otherwhite(g);
    g.sweepgcopage = g.allgcopages;
    g.gcstate = GCSsweep;

    return work;
}

// a version of generic luaM_visitpage specialized for the main sweep stage
fn sweepgcopage(L: *lua.State, page: *lmem.lua_Page) usize {
    var start: [*]u8 = undefined;
    var end: [*]u8 = undefined;
    var busyBlocks: c_int = 0;
    var blockSize: c_int = 0;
    lmem.Mgetpagewalkinfo(page, &start, &end, &busyBlocks, &blockSize);

    std.debug.assert(busyBlocks > 0);

    const g = L.global;

    const deadmask = otherwhite(g);
    std.debug.assert(testbit(deadmask, FIXEDBIT) != 0); // make sure we never sweep fixed objects

    const newwhite = Cwhite(g);

    var pos: [*]u8 = start;
    while (pos != end) : (pos += @as(usize, @intCast(blockSize))) {
        const gco: *lstate.GCObject = @ptrCast(@alignCast(pos));

        // skip memory blocks that are already freed
        if (gco.gch.header.tt == @intFromEnum(lua.Type.Nil))
            continue;

        // is the object alive?
        if ((gco.gch.header.marked ^ WHITEBITS) & deadmask != 0) {
            std.debug.assert(!isdead(g, gco));
            // make it white (for next cycle)
            gco.gch.header.marked = (gco.gch.header.marked & maskmarks) | newwhite;
        } else {
            std.debug.assert(isdead(g, gco));
            freeobj(L, gco, page);

            // if the last block was removed, page would be removed as well
            busyBlocks -= 1;
            if (busyBlocks == 0)
                return @divTrunc(@intFromPtr(end) - @intFromPtr(start), @as(usize, @intCast(blockSize))) + 1;
        }
    }

    return @divTrunc(@intFromPtr(end) - @intFromPtr(start), @as(usize, @intCast(blockSize)));
}

fn gcstep(L: *lua.State, limit: usize) Errorset.Table!usize {
    var cost: usize = 0;
    const g = L.global;
    switch (g.gcstate) {
        GCSpause => {
            markroot(L); // start a new collection
            std.debug.assert(g.gcstate == GCSpropagate);
        },
        GCSpropagate => {
            while (g.gray != null and cost < limit)
                cost += try propagatemark(g);

            if (g.gray == null) {
                // TODO: LUAI_GCMETRICS

                // perform one iteration over 'gray again' list
                g.gray = g.grayagain;
                g.grayagain = null;

                g.gcstate = GCSpropagateagain;
            }
        },
        GCSpropagateagain => {
            while (g.gray != null and cost < limit)
                cost += try propagatemark(g);

            if (g.gray == null) { // no more `gray' objects
                // TODO: LUAI_GCMETRICS

                g.gcstate = GCSatomic;
            }
        },
        GCSatomic => {
            // TODO: LUAI_GCMETRICS

            g.gcstats.atomicstarttimestamp = lperf.clock();
            g.gcstats.atomicstarttotalsizebytes = g.totalbytes;

            cost = try atomic(L); // finish mark phase

            std.debug.assert(g.gcstate == GCSsweep);
        },
        GCSsweep => {
            while (g.sweepgcopage != null and cost < limit) {
                const next = lmem.Mgetnextpage(g.sweepgcopage.?); // page sweep might destroy the page

                const steps = sweepgcopage(L, g.sweepgcopage.?);

                g.sweepgcopage = next;
                cost += steps * GC_SWEEPPAGESTEPCOST;
            }

            // nothing more to sweep?
            if (g.sweepgcopage == null) {
                // don't forget to visit main thread, it's the only object not allocated in GCO pages
                std.debug.assert(!isdead(g, @ptrCast(@alignCast(g.mainthread))));
                makewhite(g, @ptrCast(@alignCast(g.mainthread))); // make it white (for next cycle)

                try shrinkbuffers(L);

                g.gcstate = GCSpause; // end collection
            }
        },
        else => unreachable, // Unexpected GC state
    }
    return cost;
}

fn getheaptriggererroroffset(g: *lstate.global_State) i64 {
    // adjust for error using Proportional-Integral controller
    // https://en.wikipedia.org/wiki/PID_controller
    const errorKb: i32 = @divTrunc((@as(i32, @intCast(g.gcstats.atomicstarttotalsizebytes)) - @as(i32, @intCast(g.gcstats.heapgoalsizebytes))), 1024);

    // we use sliding window for the error integral to avoid error sum 'windup' when the desired target cannot be reached
    const triggertermcount: i32 = @divTrunc(@sizeOf(@TypeOf(g.gcstats.triggerterms)), @sizeOf(@TypeOf(g.gcstats.triggerterms[0])));

    const slot = &g.gcstats.triggerterms[g.gcstats.triggertermpos % triggertermcount];
    const prev = slot.*;
    slot.* = errorKb;
    g.gcstats.triggerintegral += errorKb - prev;
    g.gcstats.triggertermpos += 1;

    // controller tuning
    // https://en.wikipedia.org/wiki/Ziegler%E2%80%93Nichols_method
    const Ku = 0.9; // ultimate gain (measured)
    const Tu = 2.5; // oscillation period (measured)

    const Kp = 0.45 * Ku; // proportional gain
    const Ti = 0.8 * Tu;
    const Ki = 0.54 * Ku / Ti; // integral gain

    const proportionalTerm = Kp * @as(f64, @floatFromInt(errorKb));
    const integralTerm = Ki * @as(f64, @floatFromInt(g.gcstats.triggerintegral));

    const totalTerm = proportionalTerm + integralTerm;

    return @as(i64, @intFromFloat(totalTerm * 1024));
}

fn getheaptrigger(g: *lstate.global_State, heapgoal: usize) usize {
    @setRuntimeSafety(false);
    // adjust threshold based on a guess of how many bytes will be allocated between the cycle start and sweep phase
    // our goal is to begin the sweep when used memory has reached the heap goal
    const durationthreshold = 1e-3;
    const allocationduration = g.gcstats.atomicstarttimestamp - g.gcstats.endtimestamp;

    // avoid measuring intervals smaller than 1ms
    if (allocationduration < durationthreshold)
        return heapgoal;

    const allocationrate = @as(f64, @floatFromInt(g.gcstats.atomicstarttotalsizebytes -% g.gcstats.endtotalsizebytes)) / allocationduration;
    const markduration = g.gcstats.atomicstarttimestamp - g.gcstats.starttimestamp;

    const expectedgrowth = @as(i64, @intFromFloat(markduration * allocationrate));
    const offset = getheaptriggererroroffset(g);
    const heaptrigger: i64 = @as(i64, @intCast(heapgoal)) - @as(i64, @intCast(expectedgrowth + offset));

    // clamp the trigger between memory use at the end of the cycle and the heap goal
    return if (heaptrigger < g.totalbytes) g.totalbytes else if (heaptrigger > heapgoal) heapgoal else @intCast(heaptrigger);
}

pub fn Cstep(L: *lua.State, assist: bool) Errorset.Table!usize {
    const g = L.global;

    const lim = g.gcstepsize * @divTrunc(g.gcstepmul, 100);
    std.debug.assert(g.totalbytes >= g.GCthreshold);
    const debt = g.totalbytes - g.GCthreshold;

    GC_INTERRUPT(g, L, 0);

    if (g.gcstate == GCSpause)
        g.gcstats.starttimestamp = lperf.clock();

    // TODO: LUAI_GCMETRICS

    const lastgcstate = g.gcstate;

    const work = try gcstep(L, @intCast(lim));

    // TODO: LUAI_GCMETRICS
    _ = assist;

    const actualstepsize = @divTrunc(work * 100, @as(usize, @intCast(g.gcstepmul)));
    // at the end of the last cycle
    if (g.gcstate == GCSpause) {
        // at the end of a collection cycle, set goal based on gcgoal setting
        const heapgoal = @divTrunc(g.totalbytes, 100) * @as(usize, @intCast(g.gcgoal));
        const heaptrigger = getheaptrigger(g, heapgoal);

        g.GCthreshold = heaptrigger;

        g.gcstats.heapgoalsizebytes = heapgoal;
        g.gcstats.endtimestamp = lperf.clock();
        g.gcstats.endtotalsizebytes = g.totalbytes;

        // TODO: LUAI_GCMETRICS
    } else {
        g.GCthreshold = g.totalbytes + actualstepsize;

        // compensate if GC is "behind schedule" (has some debt to pay)
        if (g.GCthreshold >= debt)
            g.GCthreshold -= debt;
    }

    GC_INTERRUPT(g, L, lastgcstate);

    return actualstepsize;
}

pub fn Cbarrierf(L: *lua.State, o: *lstate.GCObject, v: *lstate.GCObject) void {
    const g = L.global;
    std.debug.assert(isblack(o) and iswhite(v) and !isdead(g, v) and !isdead(g, o));
    std.debug.assert(g.gcstate != GCSpause);
    // must keep invariant?
    if (keepinvariant(g))
        reallymarkobject(g, v) // restore invariant
    else // don't mind
        makewhite(g, o); // mark as white just to avoid other barriers
}

pub fn Cbarriertable(L: *lua.State, t: *lobject.LuaTable, v: *lstate.GCObject) void {
    const g = L.global;
    const o = t.obj2gco();

    // in the second propagation stage, table assignment barrier works as a forward barrier
    if (g.gcstate == GCSpropagateagain) {
        std.debug.assert(isblack(o) and iswhite(v) and !isdead(g, v) and !isdead(g, o));
        reallymarkobject(g, v);
        return;
    }

    std.debug.assert(isblack(o) and !isdead(g, o));
    std.debug.assert(g.gcstate != GCSpause);
    black2gray(o); // make table gray (again)
    t.gclist = g.grayagain;
    g.grayagain = o;
}

pub fn Cbarrierback(L: *lua.State, o: *lstate.GCObject, gclist: *?*lstate.GCObject) void {
    const g = L.global;
    std.debug.assert(isblack(o) and !isdead(g, o));
    std.debug.assert(g.gcstate != GCSpause);

    black2gray(o);
    gclist.* = g.grayagain;
    g.grayagain = o;
}

pub fn Cupvalclosed(L: *lua.State, uv: *lobject.UpVal) void {
    const g = L.global;
    const o: *lstate.GCObject = uv.obj2gco();

    std.debug.assert(!uv.upisopen()); // upvalue was closed but needs GC state fixup

    if (isgray(o)) {
        if (keepinvariant(g)) {
            gray2black(o); // closed upvalues need barrier
            Cbarrier(L, @ptrCast(@alignCast(uv)), uv.v);
        } else { // sweep phase: sweep it (turning it into white)
            makewhite(g, o);
            std.debug.assert(g.gcstate != GCSpause);
        }
    }
}
