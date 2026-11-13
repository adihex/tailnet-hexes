//! The same view adapts from a Mac's split workspace to a phone's stacked screens.
const std = @import("std");
const nui = @import("nanoui");
const ui = nui.ui;
const Client = @import("client.zig").Client;
const profiles = @import("profiles.zig");
const credentials = @import("credentials.zig");
const conversation = @import("conversation.zig");
const themes = @import("themes.zig");
const appearance = @import("appearance.zig");

pub const breakpoint: f32 = 760;

pub fn render(s: *Client, c: *ui.Context) void {
    const options = s.profileSettings();
    c.theme_chosen = themes.resolve(options.theme_id, options.desktop_theme);
    if (c.theme_chosen) |theme| c.theme = theme;
    if (c.shortcut(.{ .key = 'k', .cmd = true })) {
        s.sidebar = true;
        s.search.focus();
        c.changed = true;
    }
    if (c.shortcut(.{ .key = 'l', .cmd = true })) s.composer.focus();
    if (c.shortcut(.{ .key = 'r', .cmd = true })) s.reconnect();
    if (c.shortcut(.{ .key = ui.Shortcut.escape }) and c.size.w < breakpoint and !s.sidebar) {
        s.sidebar = true;
        c.changed = true;
    }
    ui.key(c, profiles.all[s.profile].key);
    const root = ui.div(c).row().sizeFull().safeArea().bg(c.theme.background);
    defer root.end();
    const wide = c.size.w >= breakpoint;
    if (wide or (!s.appearance_open and (s.sidebar or !s.authenticated))) sidebar(s, c, wide);
    if (wide or s.appearance_open or (!s.sidebar and s.authenticated)) {
        const main = ui.div(c).column().wFull().grow().hFull().clip();
        defer main.end();
        if (s.appearance_open) {
            appearance.render(s, c);
        } else if (!s.authenticated or s.settings) {
            account(s, c);
        } else {
            topbar(s, c, wide);
            if (s.error_text.len > 0) errorBanner(s, c);
            if (s.notice.len > 0) notice(s, c);
            if (s.show_changes) conversation.changes(s, c) else if (s.model.selected != null) conversation.render(s, c) else welcome(s, c);
        }
    }
}

fn brand(c: *ui.Context) void {
    const row = ui.div(c).row().itemsCenter().gap(10);
    defer row.end();
    const mark = ui.div(c).size(34, 34).center().rounded(10).bg(c.theme.accent.alpha(0.13));
    ui.text(c, "⬡", .{ .size = 27, .weight = .bold, .color = c.theme.accent });
    mark.end();
    ui.text(c, "Hexes", .{ .size = 22, .weight = .bold, .tracking = -0.5 });
}

fn sidebar(s: *Client, c: *ui.Context, wide: bool) void {
    const panel = ui.div(c).column().hFull().p(18).gap(14).bg(c.theme.surface);
    _ = if (wide) panel.w(278) else panel.wFull();
    defer panel.end();
    brand(c);
    profilePicker(s, c);
    ui.text(c, profiles.all[s.profile].subtitle, .{ .size = 12, .color = c.theme.muted });
    if (!s.authenticated) {
        const content = ui.div(c).column().wFull().grow().scrollY().clip();
        if (!wide) auth(s, c);
        content.end();
        appearanceButton(s, c);
        ui.text(c, "Your tailnet. Your agents.", .{ .size = 12, .color = c.theme.muted });
        return;
    }
    ui.key(c, "search");
    _ = ui.textField(c, &s.search, .{ .placeholder = "Search conversations", .width = .fill, .size = 13 });
    ui.key(c, "jojo");
    const jojo = ui.div(c).row().wFull().h(54).px(12).itemsCenter().gap(10).rounded(10).bg(if (s.isJojo()) c.theme.accent.alpha(0.12) else c.theme.surface).hover(c.theme.surface_hover).control();
    const jojo_clicked = jojo.clicked();
    ui.icon(c, "sparkles", .{ .size = 19, .color = c.theme.accent });
    ui.text(c, if (s.opening_jojo) "Opening Jojo…" else "Jojo", .{ .weight = .semibold });
    ui.spacer(c);
    ui.text(c, "Assistant", .{ .size = 11, .color = c.theme.muted });
    jojo.end();
    if (jojo_clicked) s.openJojo();
    ui.label(c, c.print("CONVERSATIONS  ·  {d}", .{s.model.sessions.items.len}));
    const list = ui.div(c).column().wFull().grow().scrollY().clip().gap(5);
    for (s.model.sessions.items) |session| {
        if (session.id == s.model.jojo or !s.filtered(session.title)) continue;
        ui.keyInt(c, session.id);
        const selected = session.id == s.model.selected;
        const row = ui.div(c).column().wFull().p(12).gap(7).rounded(10).bg(if (selected) c.theme.accent.alpha(0.10) else c.theme.surface).hover(c.theme.surface_hover).control();
        const clicked = row.clicked();
        const title_row = ui.div(c).row().wFull().gap(7).itemsCenter();
        const dot = ui.div(c).size(6, 6).roundedFull().bg(if (session.busy) c.theme.success else c.theme.muted.alpha(0.55));
        dot.end();
        ui.text(c, if (session.title.len > 0) session.title else c.print("Session #{d}", .{session.id}), .{ .size = 13, .weight = if (selected) .semibold else .regular, .truncate = .ellipsis });
        title_row.end();
        ui.text(c, c.print("#{d}  ·  {s}", .{ session.id, if (session.waiting) @as([]const u8, "Needs you") else if (session.busy) "Working" else "Sleeping" }), .{ .size = 11, .color = c.theme.muted });
        row.end();
        if (clicked) {
            s.select(session.id, session.title);
        }
    }
    if (s.model.sessions.items.len == 0) ui.label(c, "No sessions yet. Ask Jojo to start one.");
    list.end();
    ui.divider(c);
    const footer = ui.div(c).row().wFull().itemsCenter().gap(8);
    defer footer.end();
    ui.text(c, if (s.demo) "Demo · offline" else if (s.online) "Connected" else "Reconnecting…", .{ .size = 12, .color = if (s.online) c.theme.success else c.theme.muted });
    ui.spacer(c);
    appearanceButton(s, c);
    if (ui.button(c, "Account", .{ .variant = .ghost, .size = 12 }).clicked) {
        s.appearance_open = false;
        s.settings = true;
        s.sidebar = false;
    }
}

fn appearanceButton(s: *Client, c: *ui.Context) void {
    if (ui.button(c, "Appearance", .{ .variant = .ghost, .size = 12 }).clicked) {
        s.appearance_open = true;
        s.sidebar = false;
    }
}

pub fn profilePicker(s: *Client, c: *ui.Context) void {
    const row = ui.div(c).row().wFull().gap(6);
    defer row.end();
    for (profiles.all, 0..) |profile, i| {
        ui.key(c, profile.key);
        if (ui.button(c, profile.name, .{ .width = .fill, .variant = if (i == s.profile) .primary else .secondary, .size = 13, .disabled = s.sending or s.demo }).clicked) {
            s.switchProfile(i);
            c.changed = true;
        }
    }
}

fn auth(s: *Client, c: *ui.Context) void {
    const col = ui.div(c).column().wFull().gap(16).pt(18);
    defer col.end();
    ui.text(c, "Your agents,\nwithin reach.", .{ .size = 30, .weight = .bold, .leading = 1.1, .wrap = true });
    ui.text(c, "Connect to your private Hexes server over Tailscale. Paste an owner token or its sign-in link.", .{ .wrap = true, .size = 14, .leading = 1.45, .color = c.theme.muted });
    ui.label(c, "OWNER TOKEN");
    ui.key(c, "owner-token");
    const field = ui.textField(c, &s.token_input, .{ .placeholder = "Token or sign-in link", .password = true, .width = .fill, .size = 15 });
    if (credentials.persistent) {
        if (ui.checkbox(c, "Remember in macOS Keychain", &s.profileSettings().remember_token)) s.savePreferences();
    } else {
        ui.text(c, "Session-only sign-in. Tokens are never saved to a plaintext file.", .{ .wrap = true, .size = 12, .color = c.theme.muted });
    }
    if (ui.button(c, if (s.connecting) "Connecting…" else "Connect to workspace", .{
        .variant = .primary,
        .width = .fill,
        .size = 16,
        .disabled = s.connecting,
    }).clicked or (field.submitted and !s.connecting)) s.connect(s.token_input.text());
    if (s.error_text.len > 0) ui.text(c, s.error_text, .{ .wrap = true, .size = 13, .color = c.theme.danger });
    if (s.notice.len > 0) ui.text(c, s.notice, .{ .wrap = true, .size = 12, .color = c.theme.muted });
    ui.text(c, profiles.all[s.profile].url, .{ .wrap = true, .mono = true, .size = 11, .color = c.theme.muted });
}

fn account(s: *Client, c: *ui.Context) void {
    const outer = ui.div(c).column().sizeFull().p(if (c.size.w < breakpoint) 24 else 48).center().scrollY().clip();
    defer outer.end();
    const inner = ui.div(c).column().wFull().maxW(460).gap(18);
    defer inner.end();
    if (s.authenticated) {
        ui.heading(c, "Workspace account");
        ui.label(c, profiles.all[s.profile].name);
        ui.text(c, if (credentials.persistent and s.profileSettings().remember_token) "Credentials use macOS Keychain, scoped to this server." else "Your token is kept only for this session.", .{ .wrap = true });
        if (ui.button(c, "Back to workspace", .{ .variant = .primary }).clicked) s.settings = false;
        if (ui.button(c, "Sign out and forget token", .{ .variant = .danger, .disabled = s.demo }).clicked) s.signOut();
        ui.text(c, "Native core preview · 0.1.0\nFiles, terminal, voice input and notifications remain in the web / Expo clients.", .{ .wrap = true, .size = 12, .color = c.theme.muted });
    } else auth(s, c);
}

fn topbar(s: *Client, c: *ui.Context, wide: bool) void {
    const bar = ui.div(c).row().wFull().h(70).px(if (wide) 28 else 14).gap(12).itemsCenter().border(c.theme.border);
    defer bar.end();
    if (!wide and ui.button(c, "Sessions", .{ .variant = .ghost, .size = 12 }).clicked) s.sidebar = true;
    const title = ui.div(c).column().wFull().grow().gap(4);
    ui.text(c, if (s.model.selected == null) "Workspace" else s.title(), .{ .size = 16, .weight = .semibold, .truncate = .ellipsis });
    ui.text(c, if (s.read_only) "Read-only validation" else if (s.demo) "Sample workspace · no network" else if (!s.online) "Reconnecting to your tailnet…" else if (s.model.timeline.busy) "Working" else "Ready when you are", .{ .size = 11, .color = c.theme.muted });
    title.end();
    if (s.model.selected != null and !s.isJojo()) {
        if (ui.button(c, "Changes", .{ .variant = if (s.show_changes) .primary else .ghost, .size = 12 }).clicked) s.loadChanges();
    }
}

pub fn errorBanner(s: *Client, c: *ui.Context) void {
    const box = ui.div(c).row().wFull().p(12).gap(10).itemsCenter().bg(c.theme.danger.alpha(0.08));
    defer box.end();
    ui.text(c, s.error_text, .{ .wrap = true, .size = 12, .color = c.theme.danger });
    if (ui.button(c, "Dismiss", .{ .variant = .ghost, .size = 11 }).clicked) s.clearError();
}

fn notice(s: *Client, c: *ui.Context) void {
    const box = ui.div(c).row().wFull().p(10).gap(10);
    defer box.end();
    ui.text(c, s.notice, .{ .wrap = true, .size = 12, .color = c.theme.muted });
    if (ui.button(c, "OK", .{ .variant = .ghost, .size = 11 }).clicked) {
        s.clearNotice();
    }
}

fn welcome(s: *Client, c: *ui.Context) void {
    const box = ui.div(c).column().sizeFull().p(30).center().gap(18);
    defer box.end();
    ui.icon(c, "hexagon", .{ .size = 52, .color = c.theme.accent });
    ui.text(c, "A home for your agents.", .{ .size = 28, .weight = .bold, .wrap = true });
    ui.text(c, "Pick a conversation, or ask Jojo what needs you.\nYour agents keep working when you close the app.", .{ .wrap = true, .leading = 1.5, .color = c.theme.muted });
    if (ui.button(c, "Talk to Jojo", .{ .variant = .primary, .disabled = s.opening_jojo }).clicked) s.openJojo();
    if (ui.button(c, "Reconnect", .{ .variant = .ghost }).clicked) s.reconnect();
}
