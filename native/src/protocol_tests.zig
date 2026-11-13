const std = @import("std");
const t = std.testing;
const w = @import("wire.zig");
const profiles = @import("profiles.zig");
const Timeline = @import("timeline.zig").Timeline;
const Model = @import("model.zig").Model;
const md = @import("markdown.zig");

test "token links are scoped to an exact server origin and decoded once" {
    const token = try profiles.token(t.allocator, "https://hexes-cloud-arm.tail6c6fd6.ts.net/login?token=a%2Bb%25&next=/", 0);
    defer t.allocator.free(token);
    try t.expectEqualStrings("a+b%", token);
    try t.expectError(error.WrongServer, profiles.token(t.allocator, "https://adi-linux.tail6c6fd6.ts.net:8797/login?token=test", 0));
    try t.expectError(error.WrongServer, profiles.token(t.allocator, "https://hexes-cloud-arm.tail6c6fd6.ts.net.evil/login?token=test", 0));
    try t.expectError(error.InvalidToken, profiles.token(t.allocator, "a\r\nCookie: other", 0));
    try t.expectError(error.InvalidToken, profiles.token(t.allocator, "https://hexes-cloud-arm.tail6c6fd6.ts.net/login?next=/", 0));
    const encoded = try w.encode(t.allocator, "a+b%/é");
    defer t.allocator.free(encoded);
    try t.expectEqualStrings("a%2Bb%25%2F%C3%A9", encoded);
}

fn apply(timeline: *Timeline, source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(w.Value, t.allocator, source, .{});
    defer parsed.deinit();
    try timeline.apply(parsed.value);
}

test "snapshot patches replace entries and obey authoritative branch order" {
    var timeline: Timeline = .{ .gpa = t.allocator };
    defer timeline.deinit();
    try apply(&timeline,
        \\{"full":true,"entries":[{"id":9,"kind":"user","text":"Hi"},{"id":3,"kind":"assistant","text":"Old"}],"order":[9,3],"live":{"busy":true}}
    );
    try t.expectEqual(@as(u64, 9), timeline.entries.items[0].id);
    try apply(&timeline,
        \\{"entries":[{"id":3,"kind":"assistant","blocks":[{"type":"text","text":"New"}]}],"order":[3],"live":{"busy":false}}
    );
    try t.expectEqual(@as(usize, 1), timeline.entries.items.len);
    try t.expectEqualStrings("New", timeline.entries.items[0].text);
    try t.expect(!timeline.busy);
}

test "live generations render text but do not expose thinking" {
    var timeline: Timeline = .{ .gpa = t.allocator };
    defer timeline.deinit();
    try apply(&timeline,
        \\{"entries":[],"live":{"busy":true,"generation":{"message":{"blocks":[{"type":"thinking","text":"private"},{"type":"text","text":"Streaming…"}]}}}}
    );
    try t.expectEqualStrings("Streaming…", timeline.live);
    try t.expect(timeline.busy);
    try apply(&timeline, "{\"entries\":[],\"live\":{\"busy\":false}}");
    try t.expectEqualStrings("", timeline.live);
}

test "older history survives a full reconnect without duplicating overlap" {
    var timeline: Timeline = .{ .gpa = t.allocator };
    defer timeline.deinit();
    try apply(&timeline, "{\"full\":true,\"entries\":[{\"id\":20,\"text\":\"Latest\"}],\"order\":[20]}");
    const history = try std.json.parseFromSlice(w.Value, t.allocator, "[{\"id\":10,\"text\":\"Older\"},{\"id\":20,\"text\":\"Stale\"}]", .{});
    defer history.deinit();
    try timeline.history(history.value);
    try t.expectEqual(@as(usize, 1), timeline.older.items.len);
    try t.expectEqualStrings("Latest", timeline.entries.items[0].text);
    try apply(&timeline, "{\"full\":true,\"entries\":[{\"id\":20,\"text\":\"Newest\"}],\"order\":[20]}");
    try t.expectEqual(@as(usize, 1), timeline.older.items.len);
    try t.expectEqualStrings("Newest", timeline.entries.items[0].text);
    try timeline.history(history.value);
    try t.expect(timeline.history_done);
}

test "sessions exclude archived records and sort latest first" {
    var model = Model.init(t.allocator);
    defer model.deinit();
    const parsed = try std.json.parseFromSlice(w.Value, t.allocator,
        \\[{"id":1,"title":"One","updatedAt":1},{"id":2,"title":"Two","updatedAt":2},{"id":3,"archived":true}]
    , .{});
    defer parsed.deinit();
    try model.setSessions(parsed.value);
    try t.expectEqual(@as(usize, 2), model.sessions.items.len);
    try t.expectEqual(@as(u64, 2), model.sessions.items[0].id);
}

test "Markdown is literal-safe and supports Jojo session links and UTF-8 spans" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const result = try md.inlineText(arena.allocator(), "Héllo **world** and `code` [session](/s/42)");
    try t.expectEqualStrings("Héllo world and code session", result.text);
    try t.expectEqual(@as(usize, 3), result.spans.len);
    try t.expectEqual(@as(u64, 42), result.links[0].session.?);
    try t.expect(!md.safeUrl("javascript:alert(1)"));
    try t.expect(!md.safeUrl("file:///etc/passwd"));
    try t.expect(md.sessionId("/s/42oops") == null);
    try t.expect(md.safeUrl("https://example.com"));
}

test "Jojo plain session mentions open natively without interpreting code or URL paths" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const source = "Try session #42, Session 73 or /s/9. Not `/s/8`, https://elsewhere/s/7 or /s/6oops.";
    const result = try md.inlineText(arena.allocator(), source);
    try t.expectEqual(@as(usize, 3), result.links.len);
    try t.expectEqual(@as(u64, 42), result.links[0].session.?);
    try t.expectEqual(@as(u64, 73), result.links[1].session.?);
    try t.expectEqual(@as(u64, 9), result.links[2].session.?);
}
