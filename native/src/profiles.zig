const std = @import("std");
const w = @import("wire.zig");

pub const Profile = struct {
    key: []const u8,
    name: []const u8,
    subtitle: []const u8,
    url: []const u8,
};

// Origins from the supplied Chrome app bundles. Credentials never cross profiles.
pub const all = [_]Profile{
    .{ .key = "cloud", .name = "Hexes", .subtitle = "Cloud workspace", .url = "https://hexes-cloud-arm.tail6c6fd6.ts.net" },
    .{ .key = "cv", .name = "Hexes CV", .subtitle = "CV workspace", .url = "https://adi-linux.tail6c6fd6.ts.net:8797" },
};

/// Accept an owner token or its sign-in URL, but never a different server's URL.
pub fn token(gpa: std.mem.Allocator, input: []const u8, profile: usize) ![]u8 {
    const s = w.trim(input);
    if (s.len == 0 or s.len > 8192) return error.InvalidToken;
    var value = s;
    var decoded: ?[]u8 = null;
    defer if (decoded) |d| gpa.free(d);
    if (std.mem.indexOf(u8, s, "://") != null) {
        const origin = all[profile].url;
        if (!std.mem.startsWith(u8, s, origin) or s.len <= origin.len or s[origin.len] != '/') return error.WrongServer;
        const query = std.mem.indexOfScalar(u8, s, '?') orelse return error.InvalidToken;
        const end = std.mem.indexOfScalarPos(u8, s, query, '#') orelse s.len;
        var params = std.mem.splitScalar(u8, s[query + 1 .. end], '&');
        value = "";
        while (params.next()) |part| {
            if (std.mem.startsWith(u8, part, "token=")) {
                decoded = try w.decode(gpa, part[6..]);
                value = decoded.?;
                break;
            }
        }
    }
    if (value.len == 0) return error.InvalidToken;
    for (value) |ch| if (ch <= 0x20 or ch == 0x7f) return error.InvalidToken;
    return gpa.dupe(u8, value);
}
