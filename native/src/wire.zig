//! Tolerant at optional fields; strict about the protocol's structural boundaries.
const std = @import("std");
pub const Value = std.json.Value;
pub const nil: Value = .null;

pub fn field(v: Value, name: []const u8) Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}

pub fn string(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}

pub fn text(v: Value, name: []const u8) []const u8 {
    return string(field(v, name));
}

pub fn number(v: Value) u64 {
    return switch (v) {
        .integer => if (v.integer >= 0) @intCast(v.integer) else 0,
        .string => std.fmt.parseInt(u64, v.string, 10) catch 0,
        else => 0,
    };
}

pub fn boolean(v: Value) bool {
    return v == .bool and v.bool;
}

pub fn array(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}

pub fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// RFC 3986 unreserved bytes; also correct for a cookie value and URL query component.
pub fn encode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) {
            try out.append(gpa, ch);
        } else try out.appendSlice(gpa, &.{ '%', hex[ch >> 4], hex[ch & 15] });
    }
    return out.toOwnedSlice(gpa);
}

pub fn decode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.InvalidEncoding;
            try out.append(gpa, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidEncoding);
            i += 2;
        } else try out.append(gpa, s[i]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn json(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}
