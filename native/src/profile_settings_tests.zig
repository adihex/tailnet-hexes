const std = @import("std");
const nui = @import("nanoui");
const t = std.testing;
const settings = @import("profile_settings.zig");
const credentials = @import("credentials.zig");
const Client = @import("client.zig").Client;
const w = @import("wire.zig");

test "profile preferences persist independently without touching user defaults" {
    var memory: nui.kv.Memory = .{ .gpa = t.allocator };
    defer memory.deinit();
    const store = memory.store();
    try t.expectEqualStrings("desktop", (try settings.load(t.allocator, store, 0)).theme_id);
    try t.expectEqualStrings("desktop", (try settings.load(t.allocator, store, 1)).theme_id);
    try settings.save(t.allocator, store, 0, .{ .theme_id = "gruvbox", .remember_token = false });
    try settings.save(t.allocator, store, 1, .{ .theme_id = "catppuccin-latte" });
    const cloud = try settings.load(t.allocator, store, 0);
    const cv = try settings.load(t.allocator, store, 1);
    try t.expectEqualStrings("gruvbox", cloud.theme_id);
    try t.expect(!cloud.remember_token);
    try t.expectEqualStrings("catppuccin-latte", cv.theme_id);
    try t.expectEqual(credentials.persistent, cv.remember_token);
    try t.expect(!w.equal(settings.key(0), settings.key(1)));
}

test "the legacy shared theme belongs only to Hexes and never overrides scoped choices" {
    var memory: nui.kv.Memory = .{ .gpa = t.allocator };
    defer memory.deinit();
    const store = memory.store();
    try store.set(settings.legacy_theme_key, "gruvbox");
    // Loading CV first must not adopt the old shared value.
    try t.expectEqualStrings("desktop", (try settings.load(t.allocator, store, 1)).theme_id);
    try t.expectEqualStrings("gruvbox", (try settings.load(t.allocator, store, 0)).theme_id);
    try settings.save(t.allocator, store, 0, .{ .theme_id = "nord" });
    try store.set(settings.legacy_theme_key, "light");
    try t.expectEqualStrings("nord", (try settings.load(t.allocator, store, 0)).theme_id);
}

test "corrupt or unknown settings fall back only within their own profile" {
    var memory: nui.kv.Memory = .{ .gpa = t.allocator };
    defer memory.deinit();
    const store = memory.store();
    try settings.save(t.allocator, store, 0, .{ .theme_id = "gruvbox" });
    try store.set(settings.key(1), "not-json");
    try t.expectEqualStrings("desktop", (try settings.load(t.allocator, store, 1)).theme_id);
    try store.set(settings.key(1), "{\"theme\":\"deleted-theme\",\"remember_token\":\"yes\"}");
    const cv = try settings.load(t.allocator, store, 1);
    try t.expectEqualStrings("desktop", cv.theme_id);
    try t.expectEqual(credentials.persistent, cv.remember_token);
    try t.expectEqualStrings("gruvbox", (try settings.load(t.allocator, store, 0)).theme_id);
}

test "only device choices are persisted, not server palettes or credentials" {
    var memory: nui.kv.Memory = .{ .gpa = t.allocator };
    defer memory.deinit();
    const store = memory.store();
    try settings.save(t.allocator, store, 1, .{
        .theme_id = "desktop",
        .desktop_theme = nui.ui.Theme.light,
    });
    const raw = (try store.get(t.allocator, settings.key(1))).?;
    defer t.allocator.free(raw);
    const parsed = try std.json.parseFromSlice(w.Value, t.allocator, raw, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 2), parsed.value.object.count());
    try t.expectEqualStrings("desktop", w.text(parsed.value, "theme"));
    try t.expect(w.field(parsed.value, "remember_token") == .bool);
    try t.expect((try settings.load(t.allocator, store, 1)).desktop_theme == null);
}

test "profile switches restore independent choices even without persistent storage" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    s.chooseTheme("gruvbox");
    s.profileSettings().remember_token = false;
    s.switchProfile(1);
    try t.expectEqualStrings("desktop", s.profileSettings().theme_id);
    try t.expectEqual(credentials.persistent, s.profileSettings().remember_token);
    s.chooseTheme("light");
    s.switchProfile(0);
    try t.expectEqualStrings("gruvbox", s.profileSettings().theme_id);
    try t.expect(!s.profileSettings().remember_token);
    s.switchProfile(1);
    try t.expectEqualStrings("light", s.profileSettings().theme_id);
}

test "both profiles restore their saved choices in a fresh client" {
    var memory: nui.kv.Memory = .{ .gpa = t.allocator };
    defer memory.deinit();
    {
        const s = try Client.create(t.allocator, .{});
        defer s.shutdown();
        s.loadPreferences(memory.store());
        s.chooseTheme("gruvbox");
        s.profileSettings().remember_token = false;
        s.savePreferences();
        s.switchProfile(1);
        s.chooseTheme("nord");
    }
    const reopened = try Client.create(t.allocator, .{});
    defer reopened.shutdown();
    reopened.profile = 1;
    reopened.loadPreferences(memory.store());
    try t.expectEqualStrings("nord", reopened.profileSettings().theme_id);
    reopened.switchProfile(0);
    try t.expectEqualStrings("gruvbox", reopened.profileSettings().theme_id);
    try t.expect(!reopened.profileSettings().remember_token);
}

test "signing out clears only that profile's drafts and leaves other settings alone" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    s.chooseTheme("gruvbox");
    s.select(42, "Cloud");
    s.composer.set("Personal draft");
    s.switchProfile(1);
    s.chooseTheme("light");
    s.select(42, "CV");
    s.composer.set("Work draft");
    try s.saveDraft();
    s.signOut();
    try t.expect(s.drafts.get(.{ .profile = 1, .session = 42 }) == null);
    try t.expectEqualStrings("light", s.profileSettings().theme_id);
    s.switchProfile(0);
    s.select(42, "Cloud");
    try t.expectEqualStrings("Personal draft", s.composer.text());
    try t.expectEqualStrings("gruvbox", s.profileSettings().theme_id);
}
