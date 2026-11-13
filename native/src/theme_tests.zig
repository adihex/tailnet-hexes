const std = @import("std");
const nui = @import("nanoui");
const t = std.testing;
const themes = @import("themes.zig");
const w = @import("wire.zig");

test "all 22 web palettes preserve their identity and have readable control colors" {
    try t.expectEqual(@as(usize, 22), themes.presets.len);
    for (themes.presets, 0..) |option, i| {
        const theme = option.theme.?;
        try t.expectEqualStrings(option.id, themes.canonical(option.id).?);
        for (themes.presets[i + 1 ..]) |other| try t.expect(!w.equal(option.id, other.id));
        for ([_]nui.ui.Color{ theme.text, theme.muted, theme.danger, theme.success }) |color| {
            try t.expect(themes.contrast(color, theme.background) >= 4.499);
        }
        try t.expect(themes.contrast(theme.accent_text, theme.accent) >= 4.5);
        try t.expect(themes.contrast(theme.accent_text, theme.accent_hover) >= 4.5);
    }
}

test "system is native automatic appearance and missing server themes use Tokyo Night" {
    try t.expect(themes.resolve("system", null) == null);
    try t.expect(!themes.resolve("light", null).?.dark);
    try t.expect(themes.resolve("dark", null).?.dark);
    try t.expectEqualDeep(nui.ui.Color.hex(0x1a1b26), themes.resolve("desktop", null).?.background);
    try t.expectEqualDeep(themes.resolve("tokyo-night", null), themes.resolve("unknown", null));
}

test "server palettes accept only validated colors and resolve without borrowed JSON strings" {
    var desktop: ?nui.ui.Theme = null;
    {
        const parsed = try std.json.parseFromSlice(w.Value, t.allocator,
            \\{"colors":{"mode":"dark","background":"#102030","foreground":"#abcdef","accent":"#789abc"}}
        , .{});
        defer parsed.deinit();
        desktop = themes.server(parsed.value);
    }
    try t.expectEqualDeep(nui.ui.Color.hex(0x102030), themes.resolve("desktop", desktop).?.background);
    const invalid = try std.json.parseFromSlice(w.Value, t.allocator,
        \\{"colors":{"mode":"dark","background":"url(https://elsewhere)","foreground":"#ffffff"}}
    , .{});
    defer invalid.deinit();
    try t.expect(themes.server(invalid.value) == null);
}
