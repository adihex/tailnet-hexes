//! A native theme picker, shared by Mac and Android.
const ui = @import("nanoui").ui;
const Client = @import("client.zig").Client;
const themes = @import("themes.zig");
const profiles = @import("profiles.zig");
const w = @import("wire.zig");

pub fn render(s: *Client, c: *ui.Context) void {
    const outer = ui.div(c).column().sizeFull().p(24).gap(18).scrollY().clip();
    defer outer.end();
    const heading = ui.div(c).row().wFull().itemsCenter().gap(12);
    ui.heading(c, "Appearance");
    ui.spacer(c);
    if (ui.button(c, "Back", .{ .variant = .ghost }).clicked) s.appearance_open = false;
    heading.end();
    ui.text(c, c.print("Saved for {s} only, on this device. Other profiles keep their own themes and account preferences.", .{profiles.all[s.profile].name}), .{ .wrap = true, .size = 13, .color = c.theme.muted });
    if (s.notice.len > 0) ui.text(c, s.notice, .{ .wrap = true, .size = 12, .color = c.theme.muted });
    ui.label(c, "APPEARANCE");
    const modes = ui.div(c).row().wFull().gap(8);
    for (themes.modes[1..]) |option| {
        ui.key(c, option.id);
        if (ui.button(c, option.name, .{
            .width = .fill,
            .variant = if (w.equal(s.profileSettings().theme_id, option.id)) .primary else .secondary,
        }).clicked) choose(s, c, option.id);
    }
    modes.end();
    card(s, c, themes.modes[0]);
    ui.text(c, if (s.profileSettings().desktop_theme != null)
        "Using the selected server's desktop palette."
    else
        "No server desktop palette is available. Follow desktop uses Tokyo Night until one is returned.", .{ .wrap = true, .size = 12, .color = c.theme.muted });
    if (s.authenticated and !s.demo) {
        if (ui.button(c, if (s.loading_theme) "Refreshing…" else "Refresh desktop theme", .{ .variant = .ghost, .disabled = s.loading_theme }).clicked) s.refreshTheme();
    }
    ui.label(c, "WEB APP PALETTES");
    const columns: usize = if (c.size.w >= 760) 2 else 1;
    var index: usize = 0;
    while (index < themes.presets.len) : (index += columns) {
        ui.keyInt(c, index);
        const row = ui.div(c).row().wFull().gap(10);
        for (themes.presets[index..@min(index + columns, themes.presets.len)]) |option| card(s, c, option);
        row.end();
    }
    ui.text(c, "Follow desktop refreshes on connection, reconnect, or Refresh. Wallpaper, tiling and web theme-reveal animations are not part of this native preview.", .{ .wrap = true, .size = 12, .color = c.theme.muted });
}

fn card(s: *Client, c: *ui.Context, option: themes.Option) void {
    ui.key(c, option.id);
    const palette = themes.resolve(option.id, s.profileSettings().desktop_theme) orelse c.theme;
    const selected = w.equal(s.profileSettings().theme_id, option.id);
    const box = ui.div(c).row().wFull().h(76).p(14).gap(12).itemsCenter().rounded(10)
        .bg(palette.background).border(if (selected) c.theme.accent else c.theme.border).control();
    const clicked = box.clicked();
    const swatches = ui.div(c).row().gap(4);
    for ([_]ui.Color{ palette.accent, palette.success, palette.danger }) |color| {
        const dot = ui.div(c).size(9, 20).rounded(3).bg(color);
        dot.end();
    }
    swatches.end();
    const label = ui.div(c).column().wFull().grow().gap(4);
    ui.text(c, option.name, .{ .size = 14, .weight = .semibold, .color = palette.text, .truncate = .ellipsis });
    ui.text(c, if (selected) "Selected" else if (palette.dark) "Dark palette" else "Light palette", .{ .size = 11, .color = palette.muted });
    label.end();
    box.end();
    if (clicked) choose(s, c, option.id);
}

fn choose(s: *Client, c: *ui.Context, id: []const u8) void {
    s.chooseTheme(id);
    c.changed = true;
}
