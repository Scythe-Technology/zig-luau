const Bytecode = @import("Bytecode.zig");

pub inline fn getOpLength(op: Bytecode.Opcode) usize {
    return switch (op) {
        .GETGLOBAL,
        .SETGLOBAL,
        .GETIMPORT,
        .GETTABLEKS,
        .SETTABLEKS,
        .NAMECALL,
        .JUMPIFEQ,
        .JUMPIFLE,
        .JUMPIFLT,
        .JUMPIFNOTEQ,
        .JUMPIFNOTLE,
        .JUMPIFNOTLT,
        .NEWTABLE,
        .SETLIST,
        .FORGLOOP,
        .LOADKX,
        .FASTCALL2,
        .FASTCALL2K,
        .FASTCALL3,
        .JUMPXEQKNIL,
        .JUMPXEQKB,
        .JUMPXEQKN,
        .JUMPXEQKS,
        .GETUDATAKS,
        .SETUDATAKS,
        .NAMECALLUDATA,
        .NEWCLASSMEMBER,
        .CALLFB,
        .CMPPROTO,
        => 2,
        else => 1,
    };
}

// sources:
// https://github.com/luau-lang/luau/blob/32d52d1b2ceef46fc25d87094a2d7f201c3ea5b8/Common/include/Luau/BytecodeUtils.h
