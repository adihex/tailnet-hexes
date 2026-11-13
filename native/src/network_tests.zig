const std = @import("std");
const t = std.testing;
const client = @import("client.zig");
const Client = client.Client;
const Request = client.Request;
const w = @import("wire.zig");
const network = @import("network.zig");

const Fake = struct {
    requests: std.ArrayList(*Request) = .empty,

    fn start(ctx: ?*anyopaque, r: *Request) void {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.requests.append(t.allocator, r) catch unreachable;
    }

    fn pop(f: *Fake, kind: client.Kind) *Request {
        for (f.requests.items, 0..) |r, i| if (r.kind == kind) return f.requests.orderedRemove(i);
        unreachable;
    }

    fn finish(f: *Fake, s: *Client) void {
        s.shutdown();
        while (f.requests.items.len > 0) {
            const r = f.requests.orderedRemove(0);
            r.complete(0, "");
        }
        f.requests.deinit(t.allocator);
    }

    fn create(f: *Fake) !*Client {
        return Client.create(t.allocator, .{ .ctx = f, .start = start });
    }

    fn connect(f: *Fake, s: *Client) void {
        s.connect("test-only-token");
        f.pop(.connect).complete(200, "[{\"id\":42,\"title\":\"Test session\"}]");
        f.pop(.theme).complete(200, "{\"theme\":null}");
    }
};

test "old profile replies are ignored and cookies never cross profiles" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    s.connect("cloud-test-token");
    const old = f.pop(.connect);
    try t.expect(std.mem.indexOf(u8, old.cookie, "cloud-test-token") != null);
    s.switchProfile(1);
    old.complete(200, "[{\"id\":9,\"title\":\"Wrong profile\"}]");
    try t.expect(!s.authenticated);
    try t.expectEqual(@as(usize, 0), s.model.sessions.items.len);
    s.connect("cv-test-token");
    const fresh = f.pop(.connect);
    try t.expect(std.mem.startsWith(u8, fresh.url, "https://adi-linux.tail6c6fd6.ts.net:8797/"));
    try t.expect(std.mem.indexOf(u8, fresh.cookie, "cloud-test-token") == null);
    fresh.complete(401, "{}");
    try t.expect(!s.authenticated);
}

test "poll acknowledgements reset on a new server session and duplicate events are ignored" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    f.pop(.poll).complete(200,
        \\{"session":"one","events":[{"seq":5,"event":"pip","data":{"id":7}},{"seq":5,"event":"pip","data":{"id":99}}]}
    );
    try t.expectEqual(@as(u64, 5), s.ack);
    try t.expectEqual(@as(u64, 7), s.model.jojo.?);
    const next = f.pop(.poll);
    try t.expect(std.mem.indexOf(u8, next.url, "ack=5") != null);
    next.complete(200, "{\"session\":\"two\",\"events\":[{\"seq\":1,\"event\":\"pip\",\"data\":{\"id\":8}}]}");
    try t.expectEqual(@as(u64, 1), s.ack);
    try t.expectEqual(@as(u64, 8), s.model.jojo.?);
}

test "failed polls back off and authentication failures stop the chain" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    f.pop(.poll).complete(503, "{}");
    try t.expect(s.retry_pending);
    try t.expectEqual(@as(usize, 0), f.requests.items.len);
    try t.expectEqual(@as(u64, 1000), network.backoff(1));
    try t.expectEqual(@as(u64, 30000), network.backoff(100));
    s.reconnect();
    f.pop(.poll).complete(401, "{}");
    try t.expect(!s.authenticated);
    try t.expect(!s.retry_pending);
}

test "ambiguous delivery preserves the draft and retry request ID" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    s.select(42, "Test session");
    s.composer.set("Hello");
    s.send();
    const first = f.pop(.submit);
    const parsed = try std.json.parseFromSlice(w.Value, t.allocator, first.body, .{});
    defer parsed.deinit();
    const id = try t.allocator.dupe(u8, w.text(parsed.value, "requestId"));
    defer t.allocator.free(id);
    first.complete(0, "");
    try t.expectEqualStrings("Hello", s.composer.text());
    s.send();
    const second = f.pop(.submit);
    const retry = try std.json.parseFromSlice(w.Value, t.allocator, second.body, .{});
    defer retry.deinit();
    try t.expectEqualStrings(id, w.text(retry.value, "requestId"));
    // Edits typed while the request is in flight must not be erased on acknowledgement.
    s.composer.set("Next thought");
    second.complete(200, "{}");
    try t.expectEqualStrings("Next thought", s.composer.text());
}

test "conversation switches preserve drafts and reject stale snapshots" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    s.select(42, "One");
    const old = f.pop(.poll); // The global connection (also stale).
    s.composer.set("Unsent");
    s.select(43, "Two");
    old.complete(200, "{\"session\":\"old\",\"events\":[{\"seq\":1,\"event\":\"pip\",\"data\":{\"id\":999}}]}");
    try t.expect(s.model.jojo == null);
    try t.expectEqualStrings("", s.composer.text());
    s.select(42, "One");
    try t.expectEqualStrings("Unsent", s.composer.text());
}

test "a status 200 login page cannot acknowledge or erase a message" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    s.select(42, "Test session");
    s.composer.set("Keep this draft");
    s.send();
    const first = f.pop(.submit);
    first.complete(200, "<html>Please sign in</html>");
    try t.expect(!s.sending);
    try t.expectEqualStrings("Keep this draft", s.composer.text());
    try t.expect(s.submission != null);
    const id = try t.allocator.dupe(u8, s.submission.?.request_id);
    defer t.allocator.free(id);
    s.send();
    try t.expectEqualStrings(id, s.submission.?.request_id);
    f.pop(.submit).complete(200, "{\"error\":\"not accepted\"}");
    try t.expectEqualStrings("Keep this draft", s.composer.text());
    s.send();
    f.pop(.submit).complete(200, "{}");
    try t.expectEqualStrings("", s.composer.text());
    try t.expect(s.submission == null);
}

test "late initial polls close with their original profile credentials" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    const old = f.pop(.poll);
    s.switchProfile(1);
    s.connect("cv-only");
    const fresh = f.pop(.connect);
    old.complete(200, "{\"session\":\"abandoned\",\"events\":[]}");
    const close = f.pop(.close);
    try t.expect(std.mem.startsWith(u8, close.url, "https://hexes-cloud-arm.tail6c6fd6.ts.net/"));
    try t.expect(std.mem.endsWith(u8, close.url, "session=abandoned&close=1"));
    try t.expect(std.mem.indexOf(u8, close.cookie, "cv-only") == null);
    close.complete(200, "{}");
    fresh.complete(200, "[]");
    try t.expect(s.authenticated);
}

test "Jojo uses the server connection and ignores replies after navigation" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    f.pop(.poll).complete(200, "{\"session\":\"one\",\"events\":[{\"seq\":1,\"event\":\"hello\",\"data\":{\"connection\":\"server-connection\"}}]}");
    s.openJojo();
    const jojo = f.pop(.jojo);
    const data = try std.json.parseFromSlice(w.Value, t.allocator, jojo.body, .{});
    defer data.deinit();
    try t.expectEqualStrings("server-connection", w.text(data.value, "connection"));
    try t.expectEqual(@as(u64, 1), w.number(w.field(data.value, "seq")));
    s.select(42, "Keep this conversation");
    jojo.complete(200, "{\"pip\":{\"id\":7}}");
    try t.expectEqual(@as(u64, 42), s.model.selected.?);
    try t.expect(!s.opening_jojo);
}

test "shutdown leaves callbacks safe without touching a destroyed window" {
    var f: Fake = .{};
    const s = try f.create();
    s.connect("test-only-token");
    const r = f.pop(.connect);
    s.shutdown();
    r.complete(200, "[]");
    f.requests.deinit(t.allocator);
}

test "desktop theme is optional and old profile palettes cannot cross servers" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    s.refreshTheme();
    f.pop(.theme).complete(404, "<html>Older server</html>");
    try t.expect(s.authenticated);
    try t.expect(s.profileSettings().desktop_theme == null);
    s.refreshTheme();
    const old = f.pop(.theme);
    s.switchProfile(1);
    old.complete(200,
        \\{"theme":{"colors":{"mode":"dark","background":"#000000","foreground":"#ffffff"}}}
    );
    try t.expect(s.profileSettings().desktop_theme == null);
}

test "Follow desktop restores only its own server palette across profile switches" {
    var f: Fake = .{};
    const s = try f.create();
    defer f.finish(s);
    f.connect(s);
    s.refreshTheme();
    f.pop(.theme).complete(200,
        \\{"theme":{"colors":{"mode":"dark","background":"#102030","foreground":"#ffffff"}}}
    );
    s.switchProfile(1);
    try t.expect(s.profileSettings().desktop_theme == null);
    f.connect(s);
    s.refreshTheme();
    f.pop(.theme).complete(200,
        \\{"theme":{"colors":{"mode":"light","background":"#ffffff","foreground":"#102030"}}}
    );
    s.refreshTheme();
    const old_cv = f.pop(.theme);
    s.switchProfile(0);
    try t.expectEqualDeep(@import("nanoui").ui.Color.hex(0x102030), s.profileSettings().desktop_theme.?.background);
    old_cv.complete(200,
        \\{"theme":{"colors":{"mode":"dark","background":"#000000","foreground":"#ffffff"}}}
    );
    try t.expectEqualDeep(@import("nanoui").ui.Color.hex(0x102030), s.profileSettings().desktop_theme.?.background);
    s.switchProfile(1);
    try t.expect(!s.profileSettings().desktop_theme.?.dark);
}
