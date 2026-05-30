const std = @import("std");

pub const Location = extern struct {
    begin: Position = .zeros,
    end: Position = .zeros,

    pub fn eq(self: Location, other: Location) bool {
        return self.begin.eq(other.begin) and self.end.eq(other.end);
    }

    pub fn encloses(self: Location, other: Location) bool {
        return self.begin.lessThanOrEq(other.begin) and self.end.greaterThanOrEq(other.end);
    }

    pub fn overlaps(self: Location, other: Location) bool {
        return (self.begin.lessThanOrEq(other.begin) and self.end.greaterThanOrEq(other.begin)) or (self.begin.lessThanOrEq(other.end) and self.end.greaterThanOrEq(other.end)) or (other.begin.greaterThanOrEq(self.begin) and other.end.lessThanOrEq(self.end));
    }

    pub fn contains(self: Location, position: Position) bool {
        return self.begin.lessThanOrEq(position) and position.lessThan(self.end);
    }

    pub fn containsClosed(self: Location, position: Position) bool {
        return self.begin.lessThanOrEq(position) and position.lessThanOrEq(self.end);
    }

    pub const Position = extern struct {
        line: c_uint,
        column: c_uint,

        pub const missing: Position = .{ .line = std.math.maxInt(u32), .column = std.math.maxInt(u32) };
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

        pub fn hasValue(self: Position) bool {
            return self.line != std.math.maxInt(u32) and self.column != std.math.maxInt(u32);
        }
    };
};

// sources:
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/include/Luau/Location.h
// https://github.com/luau-lang/luau/blob/a2303a6ae68c53035eccf230c4450b9f068536af/Ast/src/Location.cpp
