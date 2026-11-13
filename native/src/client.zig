//! Main-thread application state. Views dispatch actions; only network.zig does I/O.
const std = @import("std");
const nui = @import("nanoui");
const secrets = @import("credentials.zig");
const profiles = @import("profiles.zig");
const w = @import("wire.zig");
const themes = @import("themes.zig");
const settings = @import("profile_settings.zig");
pub const Model = @import("model.zig").Model;
pub const Request = @import("network.zig").Request;
pub const Kind = @import("network.zig").Kind;

pub const Transport = struct {
    ctx: ?*anyopaque = null,
    // Tests supply a transport; they never call Keychain or a production server.
    start: ?*const fn (?*anyopaque, *Request) void = null,
};

pub const Submission = struct {
    target: u64,
    profile: usize,
    text: []u8,
    request_id: []u8,
};

pub const DraftKey = struct { profile: usize, session: u64 };

pub const Client = struct {
    gpa: std.mem.Allocator,
    model: Model,
    window: ?*nui.Window = null,
    transport: Transport = .{},
    refs: usize = 1,
    dead: bool = false,
    generation: u64 = 1,
    view_generation: u64 = 1,
    diff_generation: u64 = 1,
    profile: usize = 0,
    token: []u8 = &.{},
    authenticated: bool = false,
    connecting: bool = false,
    online: bool = false,
    view_received: bool = false,
    allow_storage: bool = false,
    read_only: bool = false,
    initial_session: ?u64 = null,
    demo: bool = false,
    sidebar: bool = true,
    settings: bool = false,
    appearance_open: bool = false,
    profile_settings: [profiles.all.len]settings.Settings = @splat(.{}),
    preferences: ?nui.kv.Store = null,
    loading_theme: bool = false,
    show_changes: bool = false,
    loading_history: bool = false,
    loading_changes: bool = false,
    loading_diff: bool = false,
    opening_jojo: bool = false,
    sending: bool = false,
    stopping: bool = false,
    error_text: []u8 = &.{},
    notice: []u8 = &.{},
    tab: []u8,
    connection: []u8 = &.{},
    jojo_seq: u64 = 0,
    poll_session: []u8 = &.{},
    ack: u64 = 0,
    poll_generation: u64 = 1,
    failures: u8 = 0,
    retry_pending: bool = false,
    submission: ?Submission = null,
    drafts: std.AutoHashMapUnmanaged(DraftKey, []u8) = .empty,
    composer: nui.ui.TextBuffer = .{},
    token_input: nui.ui.TextBuffer = .{},
    search: nui.ui.TextBuffer = .{},
    scroll_id: u64 = 0,
    jump_latest: bool = true,

    pub const connect = @import("actions.zig").connect;
    pub const switchProfile = @import("actions.zig").switchProfile;
    pub const select = @import("actions.zig").select;
    pub const openJojo = @import("actions.zig").openJojo;
    pub const send = @import("actions.zig").send;
    pub const stop = @import("actions.zig").stop;
    pub const loadOlder = @import("actions.zig").loadOlder;
    pub const loadChanges = @import("actions.zig").loadChanges;
    pub const loadDiff = @import("actions.zig").loadDiff;
    pub const signOut = @import("actions.zig").signOut;
    pub const request = @import("network.zig").request;
    pub const poll = @import("network.zig").poll;
    pub const closePoll = @import("network.zig").closePoll;
    pub const reconnect = @import("network.zig").reconnect;

    pub fn create(gpa: std.mem.Allocator, transport: Transport) !*Client {
        const s = try gpa.create(Client);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .model = Model.init(gpa),
            .transport = transport,
            .tab = try identifier(gpa),
        };
        return s;
    }

    pub fn identifier(gpa: std.mem.Allocator) ![]u8 {
        var bytes: [16]u8 = undefined;
        try std.Io.Threaded.global_single_threaded.io().randomSecure(&bytes);
        return std.fmt.allocPrint(gpa, "{x:0>16}{x:0>16}", .{
            std.mem.readInt(u64, bytes[0..8], .little),
            std.mem.readInt(u64, bytes[8..16], .little),
        });
    }

    pub fn retain(s: *Client) void {
        s.refs += 1;
    }

    pub fn release(s: *Client) void {
        s.refs -= 1;
        if (s.refs != 0) return;
        s.model.deinit();
        s.clearSubmission();
        var it = s.drafts.valueIterator();
        while (it.next()) |v| s.gpa.free(v.*);
        s.drafts.deinit(s.gpa);
        s.gpa.free(s.tab);
        s.gpa.free(s.connection);
        s.gpa.free(s.poll_session);
        s.gpa.free(s.error_text);
        s.gpa.free(s.notice);
        secrets.erase(s.token);
        s.gpa.free(s.token);
        secrets.erase(s.token_input.buf.allocatedSlice());
        s.composer.deinit();
        s.token_input.deinit();
        s.search.deinit();
        s.gpa.destroy(s);
    }

    pub fn shutdown(s: *Client) void {
        s.closePoll();
        s.dead = true;
        s.window = null;
        s.generation += 1;
        s.release();
    }

    pub fn redraw(s: *Client) void {
        if (s.dead) return;
        if (s.window) |window| window.redraw();
    }

    pub fn fail(s: *Client, message: []const u8) void {
        const text = s.gpa.dupe(u8, message) catch return;
        s.gpa.free(s.error_text);
        s.error_text = text;
        s.redraw();
    }

    pub fn inform(s: *Client, message: []const u8) void {
        const text = s.gpa.dupe(u8, message) catch return;
        s.gpa.free(s.notice);
        s.notice = text;
    }

    pub fn clearError(s: *Client) void {
        s.gpa.free(s.error_text);
        s.error_text = &.{};
    }

    pub fn clearNotice(s: *Client) void {
        s.gpa.free(s.notice);
        s.notice = &.{};
    }

    pub fn clearSubmission(s: *Client) void {
        if (s.submission) |v| {
            s.gpa.free(v.text);
            s.gpa.free(v.request_id);
        }
        s.submission = null;
    }

    pub fn profileSettings(s: *Client) *settings.Settings {
        return &s.profile_settings[s.profile];
    }

    pub fn loadPreferences(s: *Client, store: nui.kv.Store) void {
        s.preferences = store;
        for (&s.profile_settings, 0..) |*options, i| {
            options.* = settings.load(s.gpa, store, i) catch {
                s.inform("Some profile settings could not be loaded. Other profiles are unchanged.");
                continue;
            };
        }
    }

    pub fn savePreferences(s: *Client) void {
        if (s.preferences) |store| settings.save(s.gpa, store, s.profile, s.profileSettings().*) catch {
            s.inform("Settings changed for this session. This profile's preferences could not be saved.");
        };
    }

    pub fn chooseTheme(s: *Client, id: []const u8) void {
        const choice = themes.canonical(id) orelse return;
        s.profileSettings().theme_id = choice;
        s.savePreferences();
        s.redraw();
    }

    pub fn refreshTheme(s: *Client) void {
        if (!s.authenticated or s.loading_theme or s.demo) return;
        s.loading_theme = true;
        s.request(.theme, "theme", null);
    }

    pub fn saveDraft(s: *Client) !void {
        const id = s.model.selected orelse return;
        const key: DraftKey = .{ .profile = s.profile, .session = id };
        const copy = try s.gpa.dupe(u8, s.composer.text());
        errdefer s.gpa.free(copy);
        const result = try s.drafts.getOrPut(s.gpa, key);
        if (result.found_existing) s.gpa.free(result.value_ptr.*);
        result.value_ptr.* = copy;
    }

    pub fn restoreDraft(s: *Client, id: u64) void {
        s.composer.set(s.drafts.get(.{ .profile = s.profile, .session = id }) orelse "");
    }

    pub fn clearProfileDrafts(s: *Client) void {
        var it = s.drafts.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.profile != s.profile) continue;
            s.gpa.free(entry.value_ptr.*);
            // Removal leaves tombstones and does not resize the table.
            _ = s.drafts.remove(key);
        }
    }

    pub fn autoConnect(s: *Client) void {
        if (!s.allow_storage or !s.profileSettings().remember_token) return;
        const saved = secrets.load(s.gpa, profiles.all[s.profile].key) catch {
            s.inform("Keychain is unavailable. Paste your token to connect for this session.");
            return;
        };
        if (saved) |t| {
            defer {
                secrets.erase(t);
                s.gpa.free(t);
            }
            s.connect(t);
        }
    }

    pub fn matches(s: *const Client, generation: u64, view_generation: u64, scoped: bool) bool {
        return !s.dead and s.generation == generation and (!scoped or s.view_generation == view_generation);
    }

    pub fn isJojo(s: *const Client) bool {
        return s.model.selected != null and s.model.selected == s.model.jojo;
    }

    pub fn title(s: *const Client) []const u8 {
        if (s.isJojo()) return "Jojo";
        return if (s.model.title.len > 0) s.model.title else "Conversation";
    }

    pub fn filtered(s: *const Client, title_text: []const u8) bool {
        const query = w.trim(s.search.text());
        if (query.len == 0) return true;
        if (query.len > title_text.len) return false;
        for (0..title_text.len - query.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(title_text[i .. i + query.len], query)) return true;
        }
        return false;
    }
};
