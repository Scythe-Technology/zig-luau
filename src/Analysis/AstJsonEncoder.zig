const std = @import("std");

const Ast = @import("../Ast/Ast.zig");

extern "c" fn zig_Luau_Analysis_AstJsonEncoder_toJson(*Ast.Node, *usize) [*c]const u8;
extern "c" fn zig_Luau_Analysis_AstJsonEncoder_free([*c]const u8) void;

pub fn toJson(allocator: std.mem.Allocator, node: *Ast.Node) ![]const u8 {
    var size: usize = 0;
    const json = zig_Luau_Analysis_AstJsonEncoder_toJson(node, &size);
    defer zig_Luau_Analysis_AstJsonEncoder_free(json);
    if (json == null)
        return error.OutOfMemory;
    const result = try allocator.dupe(u8, json[0..size]);
    return result;
}

test toJson {
    const Lexer = @import("../Ast/Lexer.zig");
    const Parser = @import("../Ast/Parser.zig");
    const Allocator = @import("../Ast/Allocator.zig");

    {
        const allocator = Allocator.init();
        defer allocator.deinit();

        const table = Lexer.AstNameTable.init(allocator);
        defer table.deinit();
        const source =
            \\local x = 1
            \\
        ;

        var parse_result = Parser.parse(source, table, allocator);
        defer parse_result.deinit();

        const root = parse_result.root;

        const data = try toJson(std.testing.allocator, @ptrCast(@alignCast(root)));
        defer std.testing.allocator.free(data);

        try std.testing.expectEqualStrings(
            \\{"type":"AstStatBlock","location":"0,0 - 1,0","hasEnd":true,"body":[{"type":"AstStatLocal","location":"0,0 - 0,11","vars":[{"luauType":null,"name":"x","type":"AstLocal","location":"0,6 - 0,7"}],"values":[{"type":"AstExprConstantNumber","location":"0,10 - 0,11","value":1}]}]}
        , data);
    }
}
