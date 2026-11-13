//! Device-local choices are namespaced by the server's stable profile key.
//! Credentials stay in Keychain/session memory, never in these records.
const std = @import("std");
const nui = @import("nanoui");
const profiles = @import("profiles.zig");
const credentials = @import("credentials.zig");
const themes = @import("themes.zig");
const w = @import("wire.zig");

pub const Settings = struct {
    theme_id: []const u8 = themes.default_id,
    remember_token: bool = credentials.persistent,
    // A server palette is cached only for its own profile, never persisted.
    desktop_theme: ?nui.ui.Theme = null,
};

pub const legacy_theme_key = "hexes.appearance.theme";
const keys = blk: {
    var result: [profiles.all.len][]const u8 = undefined;
    for (profiles.all, 0..) |profile, i| {
        result[i] = "hexes.profiles." ++ profile.key ++ ".settings";
    }
    break :blk result;
};

pub fn key(profile: usize) []const u8 {
    return keys[profile];
}

pub fn load(gpa: std.mem.Allocator, store: nui.kv.Store, profile: usize) !Settings {
    if (try store.get(gpa, key(profile))) |saved| {
        defer gpa.free(saved);
        const parsed = std.json.parseFromSlice(w.Value, gpa, saved, .{}) catch return .{};
        defer parsed.deinit();
        const remember = w.field(parsed.value, "remember_token");
        return .{
            .theme_id = themes.canonical(w.text(parsed.value, "theme")) orelse themes.default_id,
            .remember_token = if (remember == .bool) remember.bool and credentials.persistent else credentials.persistent,
        };
    }
    // The old shared theme belongs to the original primary workspace only.
    // CV must not inherit it, even when CV is the first profile opened.
    if (!w.equal(profiles.all[profile].key, "cloud")) return .{};
    const legacy = try store.get(gpa, legacy_theme_key) orelse return .{};
    defer gpa.free(legacy);
    return .{ .theme_id = themes.canonical(legacy) orelse themes.default_id };
}

pub fn save(gpa: std.mem.Allocator, store: nui.kv.Store, profile: usize, settings: Settings) !void {
    const json = try w.json(gpa, .{
        .theme = settings.theme_id,
        .remember_token = settings.remember_token,
    });
    defer gpa.free(json);
    try store.set(key(profile), json);
}

pub fn openPreferences(gpa: std.mem.Allocator) !nui.kv.Store {
    if (comptime @import("builtin").abi.isAndroid()) {
        const directory = try nui.path(gpa, .data, "Hexes");
        defer gpa.free(directory);
        nui.kv.attach(std.Io.Threaded.global_single_threaded.io(), directory);
    }
    return nui.kv.standard();
}
