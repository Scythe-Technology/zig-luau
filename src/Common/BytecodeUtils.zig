const Bytecode = @import("Bytecode.zig");

pub inline fn getOpLength(op: Bytecode.Opcode) usize {
    return switch (op) {
        .LOP_GETGLOBAL,
        .LOP_SETGLOBAL,
        .LOP_GETIMPORT,
        .LOP_GETTABLEKS,
        .LOP_SETTABLEKS,
        .LOP_NAMECALL,
        .LOP_JUMPIFEQ,
        .LOP_JUMPIFLE,
        .LOP_JUMPIFLT,
        .LOP_JUMPIFNOTEQ,
        .LOP_JUMPIFNOTLE,
        .LOP_JUMPIFNOTLT,
        .LOP_NEWTABLE,
        .LOP_SETLIST,
        .LOP_FORGLOOP,
        .LOP_LOADKX,
        .LOP_FASTCALL2,
        .LOP_FASTCALL2K,
        .LOP_FASTCALL3,
        .LOP_JUMPXEQKNIL,
        .LOP_JUMPXEQKB,
        .LOP_JUMPXEQKN,
        .LOP_JUMPXEQKS,
        => 2,
        else => 1,
    };
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Common/include/Luau/BytecodeUtils.h
