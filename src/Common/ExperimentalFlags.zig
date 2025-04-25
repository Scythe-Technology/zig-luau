const std = @import("std");

pub inline fn isAnalysisFlagExperimental(flag: []const u8) bool {
    // Flags in this list are disabled by default in various command-line tools. They may have behavior that is not fully final,
    // or critical bugs that are found after the code has been submitted. This list is intended _only_ for flags that affect
    // Luau's type checking. Flags that may change runtime behavior (e.g.: parser or VM flags) are not appropriate for this list.
    const kList = [_][]const u8{
        "LuauInstantiateInSubtyping", // requires some fixes to lua-apps code
        "LuauFixIndexerSubtypingOrdering", // requires some small fixes to lua-apps code since this fixes a false negative
        "StudioReportLuauAny2", // takes telemetry data for usage of any types
        "LuauTableCloneClonesType3", // requires fixes in lua-apps code, terrifyingly
        "LuauSolverV2",
    };

    for (comptime kList) |item|
        if (std.mem.eql(u8, flag, item))
            return true;

    return false;
}

test {
    std.testing.refAllDecls(@This());
}

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Common/include/Luau/ExperimentalFlags.h
