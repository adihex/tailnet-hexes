const std = @import("std");
const ui = @import("nanoui").ui;
const t = std.testing;
const Client = @import("client.zig").Client;
const view = @import("view.zig");
const demo = @import("demo.zig");

fn clickProfile(tester: *ui.Tester, s: *Client, profile: usize) !void {
    const name = @import("profiles.zig").all[profile].name;
    var match: ?u32 = null;
    for (tester.ctx.a11y_items.items) |item| {
        if (item.role != .button or !std.mem.eql(u8, item.label, name)) continue;
        if (match != null) return error.AmbiguousProfileButton;
        match = item.node_index;
    }
    const index = match orelse return error.ProfileButtonNotFound;
    const rect = tester.ctx.nodes.items[index].rect;
    tester.click(rect.x + rect.w / 2, rect.y + rect.h / 2);
    // A real window services switchProfile's redraw after the input frame.
    // In particular, System resumes the window's base appearance then.
    tester.frame();
    try t.expectEqual(profile, s.profile);
}

test "desktop onboarding masks token and offers both server profiles" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    s.token_input.set("not-a-real-secret");
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 1180, .height = 820 });
    defer tester.deinit();
    try t.expect(tester.hasText("Hexes CV"));
    try t.expect(tester.hasText("Connect to workspace"));
    try t.expect(!tester.hasText("not-a-real-secret"));
}

test "desktop workspace exposes conversation, native Markdown and changes" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    try demo.load(s);
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 1180, .height = 820 });
    defer tester.deinit();
    try t.expect(tester.hasText("Build native Hexes"));
    try tester.clickText("Changes");
    try t.expect(s.show_changes);
    try t.expect(tester.hasText("Uncommitted changes"));
    try tester.clickText("Conversation");
    try t.expect(!s.show_changes);
}

test "phone Back and session navigation use stacked screens" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    try demo.load(s);
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 393, .height = 852 });
    defer tester.deinit();
    try t.expect(tester.hasText("Sessions"));
    try tester.clickText("Sessions");
    try t.expect(s.sidebar);
    try t.expect(tester.hasText("Jojo"));
    try tester.clickText("Review the Android release");
    try t.expectEqual(@as(u64, 73), s.model.selected.?);
    try t.expect(!s.sidebar);
}

test "phone onboarding keeps workspace choice and connection controls available" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 393, .height = 852 });
    defer tester.deinit();
    try t.expect(tester.hasText("Connect to workspace"));
    try tester.clickText("Hexes CV");
    try t.expectEqual(@as(usize, 1), s.profile);
}

test "short phone onboarding can scroll the connection button above the keyboard" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 393, .height = 480 });
    defer tester.deinit();
    const before = tester.findText("Connect to workspace").?;
    tester.scroll(180, 300, -600);
    const after = tester.findText("Connect to workspace").?;
    try t.expect(after.y < before.y);
    try t.expect(after.y >= 0 and after.y + after.h <= 480);
}

test "phone appearance is available before sign-in and returns to onboarding" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 393, .height = 852 });
    defer tester.deinit();
    try tester.clickText("Appearance");
    try t.expect(s.appearance_open);
    try tester.clickText("Light");
    try t.expectEqualStrings("light", s.profileSettings().theme_id);
    try t.expect(!tester.ctx.theme.dark);
    try tester.clickText("Back");
    try t.expect(!s.appearance_open);
    try t.expect(tester.hasText("Connect to workspace"));
}

test "desktop palette changes preserve the conversation and draft and save the choice" {
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    try demo.load(s);
    s.composer.set("Keep my draft");
    var memory: @import("nanoui").kv.Memory = .{ .gpa = t.allocator };
    defer memory.deinit();
    s.preferences = memory.store();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 1180, .height = 820 });
    defer tester.deinit();
    try tester.clickText("Appearance");
    try tester.clickText("Gruvbox");
    try t.expectEqualStrings("gruvbox", s.profileSettings().theme_id);
    try t.expectEqualStrings("gruvbox", (try @import("profile_settings.zig").load(t.allocator, memory.store(), 0)).theme_id);
    try t.expectEqualStrings("Keep my draft", s.composer.text());
    try tester.clickText("Back");
    try t.expectEqual(@as(u64, 42), s.model.selected.?);
    try t.expectEqualDeep(ui.Color.hex(0x282828), tester.ctx.theme.background);
}

test "desktop and phone profile switches restore their own rendered themes" {
    for ([_]f32{ 1180, 393 }) |width| {
        const s = try Client.create(t.allocator, .{});
        defer s.shutdown();
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(s, view.render), .{ .width = width, .height = 852 });
        defer tester.deinit();
        try tester.clickText("Appearance");
        try tester.clickText("Light");
        try t.expect(!tester.ctx.theme.dark);
        try tester.clickText("Back");
        try clickProfile(&tester, s, 1);
        try tester.clickText("Appearance");
        try t.expect(tester.hasText("Saved for Hexes CV only, on this device. Other profiles keep their own themes and account preferences."));
        try tester.clickText("Dark");
        try t.expect(tester.ctx.theme.dark);
        try tester.clickText("Back");
        try clickProfile(&tester, s, 0);
        try tester.clickText("Appearance");
        try t.expectEqualStrings("light", s.profileSettings().theme_id);
        try t.expect(!tester.ctx.theme.dark);
        try tester.clickText("Back");
        try clickProfile(&tester, s, 1);
        try tester.clickText("Appearance");
        try t.expectEqualStrings("dark", s.profileSettings().theme_id);
        try t.expect(tester.ctx.theme.dark);
    }
}

test "the Keychain remember checkbox is saved only for its workspace" {
    if (!@import("credentials.zig").persistent) return;
    const s = try Client.create(t.allocator, .{});
    defer s.shutdown();
    var memory: @import("nanoui").kv.Memory = .{ .gpa = t.allocator };
    defer memory.deinit();
    s.loadPreferences(memory.store());
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(s, view.render), .{ .width = 1180, .height = 820 });
    defer tester.deinit();
    try tester.clickText("Remember in macOS Keychain");
    try t.expect(!s.profileSettings().remember_token);
    try clickProfile(&tester, s, 1);
    try t.expect(s.profileSettings().remember_token);
    try clickProfile(&tester, s, 0);
    try t.expect(!s.profileSettings().remember_token);
    const saved = try @import("profile_settings.zig").load(t.allocator, memory.store(), 0);
    try t.expect(!saved.remember_token);
}

test "a profile using System follows the device rather than the other profile" {
    for ([_]bool{ false, true }) |dark| {
        const s = try Client.create(t.allocator, .{});
        defer s.shutdown();
        var tester: ui.Tester = undefined;
        try tester.init(t.allocator, .init(s, view.render), .{ .width = 393, .height = 852, .dark = dark });
        defer tester.deinit();
        try tester.clickText("Appearance");
        try tester.clickText(if (dark) "Light" else "Dark");
        try t.expectEqual(!dark, tester.ctx.theme.dark);
        try tester.clickText("Back");
        try clickProfile(&tester, s, 1);
        try tester.clickText("Appearance");
        try tester.clickText("System");
        try t.expectEqualStrings("system", s.profileSettings().theme_id);
        tester.frame();
        try t.expectEqual(dark, tester.ctx.theme.dark);
        try tester.clickText("Back");
        try clickProfile(&tester, s, 0);
        try t.expectEqual(!dark, tester.ctx.theme.dark);
        try clickProfile(&tester, s, 1);
        try t.expectEqual(dark, tester.ctx.theme.dark);
    }
}
