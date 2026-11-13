//! User intents, shared by the desktop and phone views.
const std = @import("std");
const nui = @import("nanoui");
const Client = @import("client.zig").Client;
const Model = @import("model.zig").Model;
const profiles = @import("profiles.zig");
const secrets = @import("credentials.zig");
const w = @import("wire.zig");

pub fn connect(s: *Client, input: []const u8) void {
    if (s.sending or s.connecting) return;
    const token = if (s.read_only and input.len == 0) s.gpa.dupe(u8, "") catch return else profiles.token(s.gpa, input, s.profile) catch |err| {
        s.fail(if (err == error.WrongServer) "That sign-in link belongs to a different server. Choose its profile first." else "Paste an owner token or the full sign-in link.");
        return;
    };
    s.closePoll();
    s.generation += 1;
    secrets.erase(s.token);
    s.gpa.free(s.token);
    s.token = token;
    s.connecting = true;
    s.authenticated = false;
    s.online = false;
    s.clearError();
    s.request(.connect, "sessions", null);
}

pub fn switchProfile(s: *Client, profile: usize) void {
    if (profile >= profiles.all.len or profile == s.profile) return;
    if (s.sending) return s.fail("Wait for this message's delivery result before switching servers.");
    s.saveDraft() catch return s.fail("Could not keep your draft. Server was not changed.");
    s.closePoll();
    s.generation += 1;
    s.view_generation += 1;
    s.profile = profile;
    s.model.deinit();
    s.model = Model.init(s.gpa);
    secrets.erase(s.token);
    s.gpa.free(s.token);
    s.token = &.{};
    secrets.erase(s.token_input.buf.allocatedSlice());
    s.token_input.clear();
    s.composer.clear();
    s.search.clear();
    s.clearSubmission();
    s.authenticated = false;
    s.connecting = false;
    s.online = false;
    s.opening_jojo = false;
    s.sending = false;
    s.stopping = false;
    s.loading_history = false;
    s.loading_changes = false;
    s.loading_diff = false;
    s.show_changes = false;
    s.settings = false;
    s.loading_theme = false;
    s.clearError();
    s.clearNotice();
    s.autoConnect();
    s.redraw();
}

pub fn select(s: *Client, id: u64, title: []const u8) void {
    if (id == s.model.selected) {
        s.sidebar = false;
        s.settings = false;
        return;
    }
    if (s.sending) return s.fail("Wait for this message's delivery result before changing conversations.");
    s.saveDraft() catch return s.fail("Could not keep your draft. Conversation was not changed.");
    s.closePoll();
    s.view_generation += 1;
    s.model.select(id, title) catch return s.fail("Not enough memory to open this conversation.");
    s.restoreDraft(id);
    s.sidebar = false;
    s.settings = false;
    s.show_changes = false;
    s.loading_history = false;
    s.loading_changes = false;
    s.loading_diff = false;
    s.online = false;
    s.view_received = false;
    s.jump_latest = true;
    s.opening_jojo = false;
    s.clearError();
    s.poll();
}

pub fn openJojo(s: *Client) void {
    if (!s.authenticated or s.opening_jojo) return;
    if (s.read_only) return s.fail("Read-only validation never opens or changes Jojo.");
    if (s.demo) {
        s.model.jojo = 1;
        s.select(1, "Jojo");
        return;
    }
    if (s.connection.len == 0) return s.fail("Wait for the live connection, then open Jojo again.");
    s.jojo_seq += 1;
    const body = w.json(s.gpa, .{ .connection = s.connection, .on = true, .seq = s.jojo_seq }) catch return;
    defer s.gpa.free(body);
    s.opening_jojo = true;
    s.request(.jojo, "pip", body);
}

pub fn send(s: *Client) void {
    const id = s.model.selected orelse return;
    const text = w.trim(s.composer.text());
    if (text.len == 0 or s.sending or !s.authenticated) return;
    if (s.read_only or s.demo) return s.fail("This is a read-only workspace. No message was sent.");
    if (s.submission) |v| {
        if (v.target != id or v.profile != s.profile or !w.equal(v.text, text)) s.clearSubmission();
    }
    if (s.submission == null) {
        const copy = s.gpa.dupe(u8, text) catch return;
        const request_id = Client.identifier(s.gpa) catch {
            s.gpa.free(copy);
            return;
        };
        s.submission = .{ .target = id, .profile = s.profile, .text = copy, .request_id = request_id };
    }
    const sub = s.submission.?;
    const body = if (s.model.timeline.busy)
        w.json(s.gpa, .{ .text = sub.text, .requestId = sub.request_id, .mode = "steer" }) catch return
    else
        w.json(s.gpa, .{ .text = sub.text, .requestId = sub.request_id }) catch return;
    defer s.gpa.free(body);
    const path = std.fmt.allocPrint(s.gpa, "c/{d}/submit", .{id}) catch return;
    defer s.gpa.free(path);
    s.clearError();
    s.sending = true;
    s.jump_latest = true;
    s.request(.submit, path, body);
}

pub fn stop(s: *Client) void {
    const id = s.model.selected orelse return;
    if (s.stopping or s.demo or s.read_only) return;
    const path = std.fmt.allocPrint(s.gpa, "c/{d}/abort", .{id}) catch return;
    defer s.gpa.free(path);
    s.stopping = true;
    s.request(.stop, path, "{}");
}

pub fn loadOlder(s: *Client) void {
    if (s.loading_history or s.model.timeline.history_done or s.demo) return;
    const id = s.model.selected orelse return;
    const before = s.model.timeline.before() orelse return;
    const path = std.fmt.allocPrint(s.gpa, "c/{d}/history?before={d}", .{ id, before }) catch return;
    defer s.gpa.free(path);
    s.loading_history = true;
    s.request(.history, path, null);
}

pub fn loadChanges(s: *Client) void {
    const id = s.model.selected orelse return;
    s.show_changes = true;
    if (s.loading_changes or s.demo) return;
    const path = std.fmt.allocPrint(s.gpa, "c/{d}/changes", .{id}) catch return;
    defer s.gpa.free(path);
    s.loading_changes = true;
    s.request(.changes, path, null);
}

pub fn loadDiff(s: *Client, path: []const u8) void {
    const id = s.model.selected orelse return;
    if (s.demo) return;
    const encoded = w.encode(s.gpa, path) catch return;
    defer s.gpa.free(encoded);
    const route = std.fmt.allocPrint(s.gpa, "c/{d}/changes/diff?path={s}", .{ id, encoded }) catch return;
    defer s.gpa.free(route);
    const copy = s.gpa.dupe(u8, path) catch return;
    s.gpa.free(s.model.diff_path);
    s.model.diff_path = copy;
    s.diff_generation += 1;
    s.loading_diff = true;
    s.request(.diff, route, null);
}

pub fn signOut(s: *Client) void {
    if (s.sending) return s.fail("Wait for this message's delivery result before signing out.");
    if (s.allow_storage) secrets.forget(profiles.all[s.profile].key) catch {
        return s.fail("Could not remove the Keychain item. Sign-out was not completed.");
    };
    s.closePoll();
    s.generation += 1;
    s.view_generation += 1;
    secrets.erase(s.token);
    s.gpa.free(s.token);
    s.token = &.{};
    secrets.erase(s.token_input.buf.allocatedSlice());
    s.token_input.clear();
    s.composer.clear();
    s.model.deinit();
    s.model = Model.init(s.gpa);
    s.clearProfileDrafts();
    s.clearSubmission();
    s.authenticated = false;
    s.online = false;
    s.connecting = false;
    s.settings = false;
    s.profileSettings().desktop_theme = null;
    s.loading_theme = false;
    s.clearError();
    s.clearNotice();
}
