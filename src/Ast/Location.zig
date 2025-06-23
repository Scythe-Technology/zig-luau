pub const Location = extern struct {
    begin: Position = .zeros,
    end: Position = .zeros,

    pub fn eq(self: Location, other: Location) bool {
        return self.begin.eq(other.begin) and self.end.eq(other.end);
    }

    pub const Position = extern struct {
        line: c_uint,
        column: c_uint,

        pub const zeros: Position = .{ .line = 0, .column = 0 };

        pub fn eq(self: Position, other: Position) bool {
            return self.line == other.line and self.column == other.column;
        }
        pub fn lessThan(self: Position, other: Position) bool {
            if (self.line == other.line)
                return self.column < other.column;
            return self.line < other.line;
        }
        pub inline fn lessThanOrEq(self: Position, other: Position) bool {
            return self.eq(other) or self.lessThan(other);
        }
        pub inline fn greaterThan(self: Position, other: Position) bool {
            return !self.lessThanOrEq(other);
        }
        pub inline fn greaterThanOrEq(self: Position, other: Position) bool {
            return !self.lessThan(other);
        }
    };
};

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Location.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Location.cpp
