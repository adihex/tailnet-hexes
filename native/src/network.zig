//! One acknowledged long-poll chain. Old replies cannot touch a new profile or view.
const std = @import("std");
const nui = @import("nanoui");
const Client = @import("client.zig").Client;
const profiles = @import("profiles.zig");
const secrets = @import("credentials.zig");
const w = @import("wire.zig");
const themes = @import("themes.zig");

pub const Kind = enum { connect, poll, close, jojo, submit, stop, history, changes, diff, theme };

pub const Request = struct {
    client: *Client,
    kind: Kind,
    generation: u64,
    view_generation: u64,
    poll_generation: u64,
    diff_generation: u64,
    url: []u8,
    body: []u8,
    cookie: []u8,
    post: bool,

    pub fn complete(r: *Request, status: u16, body: []const u8) void {
        const s = r.client;
        defer {
            s.gpa.free(r.url);
            s.gpa.free(r.body);
            secrets.erase(r.cookie);
            s.gpa.free(r.cookie);
            s.gpa.destroy(r);
            s.release();
        }
        const scoped = switch (r.kind) {
            .connect, .close, .theme => false,
            else => true,
        };
        if (!s.matches(r.generation, r.view_generation, scoped)) {
            r.closeAbandonedPoll(status, body);
            return;
        }
        if (r.kind == .close) return;
        if (r.kind == .poll and r.poll_generation != s.poll_generation) {
            r.closeAbandonedPoll(status, body);
            return;
        }
        if (r.kind == .diff and r.diff_generation != s.diff_generation) return;
        received(r, status, body) catch {
            s.fail(if (r.kind == .submit)
                "Delivery could not be confirmed. Retry the unchanged message to reuse its request ID."
            else
                "Unexpected server response. Check the server and sign-in token, then reconnect.");
            if (r.kind == .connect) s.connecting = false;
            if (r.kind == .poll) scheduleRetry(s);
        };
        s.redraw();
    }

    fn closeAbandonedPoll(r: *Request, status: u16, body: []const u8) void {
        if (r.kind != .poll or status != 200) return;
        const s = r.client;
        const parsed = std.json.parseFromSlice(w.Value, s.gpa, body, .{}) catch return;
        defer parsed.deinit();
        const session = w.text(parsed.value, "session");
        if (session.len == 0) return;
        if (r.generation == s.generation and w.equal(session, s.poll_session)) return;
        // An initial reply can arrive after a profile switch. Release that
        // connection using its captured origin and cookie, never the new ones.
        const boundary = std.mem.indexOf(u8, r.url, "/api/") orelse return;
        const encoded = w.encode(s.gpa, session) catch return;
        defer s.gpa.free(encoded);
        const close = s.gpa.create(Request) catch return;
        close.* = r.*;
        close.kind = .close;
        close.post = false;
        close.url = std.fmt.allocPrint(s.gpa, "{s}poll?session={s}&close=1", .{ r.url[0 .. boundary + 5], encoded }) catch {
            s.gpa.destroy(close);
            return;
        };
        close.body = s.gpa.dupe(u8, "") catch {
            s.gpa.free(close.url);
            s.gpa.destroy(close);
            return;
        };
        close.cookie = s.gpa.dupe(u8, r.cookie) catch {
            s.gpa.free(close.body);
            s.gpa.free(close.url);
            s.gpa.destroy(close);
            return;
        };
        s.retain();
        dispatch(close);
    }
};

pub fn request(s: *Client, kind: Kind, path: []const u8, body: ?[]const u8) void {
    if (s.dead or s.demo) return;
    start(s, kind, path, body) catch {
        s.connecting = false;
        s.sending = false;
        s.stopping = false;
        s.opening_jojo = false;
        s.loading_history = false;
        s.loading_changes = false;
        s.loading_diff = false;
        s.loading_theme = false;
        s.fail("Not enough memory to start the request. Your draft is unchanged.");
    };
}

fn start(s: *Client, kind: Kind, path: []const u8, body: ?[]const u8) !void {
    const r = try s.gpa.create(Request);
    errdefer s.gpa.destroy(r);
    const url = try std.fmt.allocPrint(s.gpa, "{s}/api/{s}", .{ profiles.all[s.profile].url, path });
    errdefer s.gpa.free(url);
    const contents = try s.gpa.dupe(u8, body orelse "");
    errdefer s.gpa.free(contents);
    const encoded = try w.encode(s.gpa, s.token);
    defer s.gpa.free(encoded);
    const cookie = try std.fmt.allocPrint(s.gpa, "pocket_auth={s}", .{encoded});
    r.* = .{
        .client = s,
        .kind = kind,
        .generation = s.generation,
        .view_generation = s.view_generation,
        .poll_generation = s.poll_generation,
        .diff_generation = s.diff_generation,
        .url = url,
        .body = contents,
        .cookie = cookie,
        .post = body != null,
    };
    s.retain();
    dispatch(r);
}

fn dispatch(r: *Request) void {
    const s = r.client;
    if (s.transport.start) |send| return send(s.transport.ctx, r);
    nui.http.fetch(s.gpa, .{
        .url = r.url,
        .method = if (r.post) "POST" else "GET",
        .body = r.body,
        .headers = &.{
            .{ .name = "Cookie", .value = r.cookie },
            .{ .name = "X-Pocket", .value = "1" },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Cache-Control", .value = "no-store" },
        },
        .timeout = if (r.kind == .poll) 45 else 20,
    }, r, answered);
}

fn answered(r: *Request, response: nui.http.Response) void {
    r.complete(response.status, response.body);
}

pub fn poll(s: *Client) void {
    if (!s.authenticated or s.dead or s.demo) return;
    const selected = if (s.model.selected) |id| std.fmt.allocPrint(s.gpa, "&c={d}", .{id}) catch return else s.gpa.dupe(u8, "") catch return;
    defer s.gpa.free(selected);
    const session = w.encode(s.gpa, s.poll_session) catch return;
    defer s.gpa.free(session);
    const path = std.fmt.allocPrint(s.gpa, "poll?tab={s}{s}&session={s}&ack={d}", .{ s.tab, selected, session, s.ack }) catch return;
    defer s.gpa.free(path);
    s.request(.poll, path, null);
}

pub fn closePoll(s: *Client) void {
    s.poll_generation += 1;
    s.retry_pending = false;
    s.failures = 0;
    if (s.poll_session.len > 0) {
        const encoded = w.encode(s.gpa, s.poll_session) catch return;
        defer s.gpa.free(encoded);
        const path = std.fmt.allocPrint(s.gpa, "poll?session={s}&close=1", .{encoded}) catch return;
        defer s.gpa.free(path);
        s.request(.close, path, null);
    }
    s.gpa.free(s.poll_session);
    s.poll_session = &.{};
    s.gpa.free(s.connection);
    s.connection = &.{};
    s.ack = 0;
}

pub fn reconnect(s: *Client) void {
    if (!s.authenticated or s.connecting) return;
    s.closePoll();
    s.clearError();
    s.online = false;
    s.poll();
    s.refreshTheme();
}

pub fn backoff(failures: u8) u64 {
    return @min(30_000, @as(u64, 1000) << @intCast(@min(failures -| 1, 5)));
}

const Retry = struct { client: *Client, generation: u64, poll_generation: u64 };

fn scheduleRetry(s: *Client) void {
    if (s.dead or !s.authenticated or s.retry_pending) return;
    s.online = false;
    s.failures +|= 1;
    s.retry_pending = true;
    if (s.transport.start != null) return; // Tests advance retries explicitly.
    const retry = s.gpa.create(Retry) catch return;
    retry.* = .{ .client = s, .generation = s.generation, .poll_generation = s.poll_generation };
    s.retain();
    nui.App.after(backoff(s.failures), retry, retryNow);
}

fn retryNow(context: ?*anyopaque) callconv(.c) void {
    const retry: *Retry = @ptrCast(@alignCast(context.?));
    const s = retry.client;
    defer {
        s.gpa.destroy(retry);
        s.release();
    }
    if (s.dead or retry.generation != s.generation or retry.poll_generation != s.poll_generation) return;
    s.retry_pending = false;
    s.poll();
}

fn received(r: *Request, status: u16, body: []const u8) !void {
    const s = r.client;
    if (r.kind == .theme) {
        s.loading_theme = false;
        // Older servers may not expose a desktop theme. Do not let this
        // optional endpoint disrupt sign-in, the conversation, or a draft.
        if (status < 200 or status >= 300) return;
        const parsed = std.json.parseFromSlice(w.Value, s.gpa, body, .{}) catch return;
        defer parsed.deinit();
        s.profileSettings().desktop_theme = themes.server(w.field(parsed.value, "theme"));
        return;
    }
    switch (r.kind) {
        .connect => s.connecting = false,
        .submit => s.sending = false,
        .stop => s.stopping = false,
        .jojo => s.opening_jojo = false,
        .history => s.loading_history = false,
        .changes => s.loading_changes = false,
        .diff => s.loading_diff = false,
        else => {},
    }
    if (status < 200 or status >= 300) {
        if (status == 401 or status == 403) {
            s.authenticated = false;
            s.online = false;
            s.closePoll();
            return s.fail("Sign-in expired or was refused. Paste a valid token for this server.");
        }
        if (r.kind == .poll) {
            scheduleRetry(s);
            return;
        }
        if (r.kind == .submit) return s.fail("Delivery could not be confirmed. Retry the unchanged message to reuse its request ID.");
        return s.fail(if (status == 0) "Server unreachable. Check Tailscale and the selected server, then retry." else "The server could not complete that action. Retry, or open the web client for details.");
    }
    if (r.kind == .diff) {
        const copy = try s.gpa.dupe(u8, body);
        s.gpa.free(s.model.diff);
        s.model.diff = copy;
        return;
    }
    const parsed = try std.json.parseFromSlice(w.Value, s.gpa, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const data = parsed.value;
    if (r.kind == .stop or r.kind == .submit) {
        // A proxy's HTML login page with status 200 is not a delivery receipt.
        if (data != .object or w.field(data, "error") != .null) return error.InvalidReceipt;
    }
    if (r.kind == .stop) {
        s.inform("Stop requested. Waiting for the server's live status.");
        return;
    }
    if (r.kind == .submit) {
        if (s.submission) |sub| {
            if (w.equal(w.trim(s.composer.text()), sub.text)) s.composer.clear();
        }
        try s.saveDraft();
        s.clearSubmission();
        return;
    }
    switch (r.kind) {
        .connect => {
            try s.model.setSessions(data);
            s.authenticated = true;
            s.online = true;
            s.refreshTheme();
            // Clear all allocated field bytes too, not just the visible length.
            secrets.erase(s.token_input.buf.allocatedSlice());
            s.token_input.clear();
            if (s.allow_storage) {
                if (s.profileSettings().remember_token) {
                    secrets.save(profiles.all[s.profile].key, s.token) catch {
                        s.inform("Connected for this session. Keychain could not save the token.");
                    };
                } else secrets.forget(profiles.all[s.profile].key) catch {
                    s.inform("Connected for this session. Keychain could not forget this profile's old token.");
                };
            }
            if (s.read_only and s.model.sessions.items.len > 0) {
                const first = s.model.sessions.items[0];
                const id = s.initial_session orelse first.id;
                var title: []const u8 = "Conversation";
                for (s.model.sessions.items) |session| {
                    if (session.id == id) {
                        title = session.title;
                        break;
                    }
                }
                s.select(id, title);
            } else s.poll();
        },
        .jojo => {
            const id = w.number(w.field(w.field(data, "pip"), "id"));
            if (id == 0) return s.fail("Jojo is not available on this server. Check that its extension is enabled.");
            s.model.jojo = id;
            s.select(id, "Jojo");
        },
        .poll => try pollResult(s, data),
        .history => try s.model.timeline.history(data),
        .changes => try s.model.setChanges(data),
        else => {},
    }
}

fn pollResult(s: *Client, data: w.Value) !void {
    const session = w.text(data, "session");
    if (session.len == 0 or w.field(data, "events") != .array) return error.InvalidPoll;
    if (!w.equal(session, s.poll_session)) {
        const copy = try s.gpa.dupe(u8, session);
        s.gpa.free(s.poll_session);
        s.poll_session = copy;
        s.ack = 0;
    }
    for (w.array(w.field(data, "events"))) |ev| {
        const seq = w.number(w.field(ev, "seq"));
        if (seq <= s.ack) continue;
        const name = w.text(ev, "event");
        const value = w.field(ev, "data");
        if (w.equal(name, "hello")) {
            const copy = try s.gpa.dupe(u8, w.text(value, "connection"));
            s.gpa.free(s.connection);
            s.connection = copy;
        } else if (w.equal(name, "sessions")) {
            try s.model.setSessions(value);
        } else if (w.equal(name, "pip")) {
            const id = w.number(w.field(value, "id"));
            s.model.jojo = if (id == 0) null else id;
        } else if (w.equal(name, "view") or w.equal(name, "pipview")) {
            const id = w.number(w.field(w.field(value, "conversation"), "id"));
            if (id != 0 and id == s.model.selected) {
                try s.model.timeline.apply(value);
                s.view_received = true;
            }
        }
        s.ack = seq; // Only acknowledge successfully applied events.
    }
    s.online = true;
    s.failures = 0;
    s.retry_pending = false;
    s.poll();
}
