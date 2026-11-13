const std = @import("std");
const ui = @import("nanoui").ui;
const Client = @import("client.zig").Client;
const Entry = @import("timeline.zig").Entry;
const md = @import("markdown.zig");
const w = @import("wire.zig");

pub fn render(s: *Client, c: *ui.Context) void {
    ui.keyInt(c, s.model.selected orelse 0);
    const scroll_index = c.open(.{
        .width = .fill,
        .grow = 1,
        .scroll = true,
        .clip = true,
        .follow_end = true,
        .selectable = true,
        .padding = .all(if (c.size.w < 760) 18 else 32),
        .align_items = .center,
    }, "transcript");
    s.scroll_id = c.node(scroll_index).id;
    if (s.jump_latest) {
        c.scroll.put(c.gpa, s.scroll_id, 1e9) catch {};
        c.scroll_follow.put(c.gpa, s.scroll_id, true) catch {};
        s.jump_latest = false;
    }
    const transcript = ui.div(c).column().wFull().maxW(820).gap(24);
    if (!s.model.timeline.history_done and s.model.timeline.before() != null) {
        if (ui.button(c, if (s.loading_history) "Loading history…" else "Load older messages", .{ .variant = .ghost, .size = 12, .disabled = s.loading_history }).clicked) s.loadOlder();
    }
    for (s.model.timeline.older.items) |*entry| row(s, c, entry);
    for (s.model.timeline.entries.items) |*entry| row(s, c, entry);
    if (s.model.timeline.live.len > 0) {
        ui.key(c, "live");
        const live = ui.div(c).column().wFull().gap(10);
        ui.text(c, "HEXES  ·  WORKING", .{ .size = 10, .weight = .bold, .color = c.theme.accent });
        md.render(s, c, s.model.timeline.live);
        live.end();
    }
    if (s.model.timeline.entries.items.len == 0 and s.model.timeline.older.items.len == 0 and s.model.timeline.live.len == 0) {
        ui.text(c, if (s.online) "This conversation is ready." else "Connecting to the conversation…", .{ .color = c.theme.muted, .wrap = true });
        if (s.isJojo()) ui.text(c, "Ask what needs you, review ongoing work, or start a new session.", .{ .color = c.theme.muted, .wrap = true });
    }
    transcript.end();
    c.end();
    const max = c.scroll_max.get(s.scroll_id) orelse 0;
    const current = c.scroll.get(s.scroll_id) orelse 0;
    if (max - current > 30) {
        const jump = ui.div(c).row().wFull().justifyCenter().py(4);
        if (ui.button(c, "Jump to latest", .{ .size = 12 }).clicked) s.jump_latest = true;
        jump.end();
    }
    composer(s, c);
}

fn row(s: *Client, c: *ui.Context, entry: *const Entry) void {
    if (entry.text.len == 0 and entry.name.len == 0) return;
    ui.keyInt(c, entry.id);
    if (entry.kind == .tool) {
        const tool = ui.div(c).column().wFull().p(12).gap(8).rounded(8).border(c.theme.border);
        defer tool.end();
        const state = c.state(struct { open: bool = false }, "expanded");
        if (ui.button(c, c.print("{s} {s}", .{ if (state.open) @as([]const u8, "Hide") else "Show", if (entry.name.len > 0) entry.name else "tool output" }), .{ .variant = .ghost, .size = 12 }).clicked) state.open = !state.open;
        if (entry.is_error) ui.text(c, "Tool reported an error", .{ .size = 12, .color = c.theme.danger });
        if (state.open) ui.text(c, entry.text, .{ .wrap = true, .mono = true, .size = 12 });
        return;
    }
    const mine = entry.kind == .user;
    const box = ui.div(c).column().wFull().p(if (mine) 18 else 0).gap(10).rounded(12);
    if (mine) _ = box.bg(c.theme.accent.alpha(0.07));
    defer box.end();
    ui.text(c, if (mine) "YOU" else if (entry.kind == .assistant) "HEXES" else "ACTIVITY", .{
        .size = 10,
        .weight = .bold,
        .tracking = 1,
        .color = if (mine) c.theme.accent else c.theme.muted,
    });
    if (entry.kind == .system) ui.text(c, entry.text, .{ .wrap = true, .size = 12, .color = c.theme.muted }) else md.render(s, c, entry.text);
}

fn composer(s: *Client, c: *ui.Context) void {
    const area = ui.div(c).column().wFull().px(if (c.size.w < 760) 14 else 28).py(14).gap(8).itemsCenter();
    defer area.end();
    const box = ui.div(c).column().wFull().maxW(820).p(14).gap(10).rounded(14).bg(c.theme.surface).border(c.theme.border);
    defer box.end();
    ui.key(c, "composer");
    const field = ui.textField(c, &s.composer, .{
        .placeholder = if (s.isJojo()) "Ask Jojo anything about your workspace…" else "Message this hex…",
        .width = .fill,
        .multiline = true,
        .max_lines = 7,
        .bare = true,
        .size = 14,
    });
    const controls = ui.div(c).row().wFull().itemsCenter().gap(8);
    defer controls.end();
    ui.text(c, if (s.sending) "Sending…" else if (s.model.timeline.busy) "Next message steers the agent" else if (c.size.w < 760) "Message your agent" else "Return to send · Shift-Return for a new line", .{ .size = 10, .wrap = true, .color = c.theme.muted });
    ui.spacer(c);
    if (s.model.timeline.busy) {
        if (ui.button(c, if (s.stopping) "Stopping…" else "Stop", .{ .variant = .ghost, .size = 12, .disabled = s.stopping or s.read_only or s.demo }).clicked) s.stop();
    }
    const enabled = w.trim(s.composer.text()).len > 0 and !s.sending and !s.read_only and !s.demo;
    const clicked = ui.button(c, if (s.sending) "Sending…" else if (s.model.timeline.busy) "Steer" else "Send", .{ .variant = .primary, .size = 14, .disabled = !enabled }).clicked;
    if ((clicked or field.submitted or c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) and enabled) s.send();
}

pub fn changes(s: *Client, c: *ui.Context) void {
    const panel = ui.div(c).column().wFull().grow().p(if (c.size.w < 760) 16 else 28).gap(14).scrollY().clip();
    defer panel.end();
    const heading = ui.div(c).row().wFull().gap(10).itemsCenter();
    ui.heading(c, "Uncommitted changes");
    ui.spacer(c);
    if (ui.button(c, "Conversation", .{ .variant = .ghost, .size = 12 }).clicked) s.show_changes = false;
    heading.end();
    if (s.loading_changes) ui.label(c, "Loading changes…");
    if (!s.loading_changes and s.model.changes.items.len == 0) ui.label(c, "No uncommitted files.");
    for (s.model.changes.items, 0..) |change, i| {
        ui.keyInt(c, i);
        if (ui.button(c, c.print("{s}  ·  {s}", .{ change.kind, change.path }), .{ .variant = .ghost, .size = 12, .width = .fill }).clicked) s.loadDiff(change.path);
    }
    if (s.model.diff_path.len > 0) ui.text(c, s.model.diff_path, .{ .mono = true, .weight = .semibold, .wrap = true });
    if (s.loading_diff) {
        ui.label(c, "Loading diff…");
        return;
    }
    const diff = ui.div(c).column().wFull().gap(2).p(12).rounded(8).bg(c.theme.surface);
    c.node(diff.index).style.selectable = true;
    defer diff.end();
    var lines = std.mem.splitScalar(u8, s.model.diff, '\n');
    while (lines.next()) |line| {
        const color = if (std.mem.startsWith(u8, line, "+")) c.theme.success else if (std.mem.startsWith(u8, line, "-")) c.theme.danger else if (std.mem.startsWith(u8, line, "@@")) c.theme.accent else c.theme.text;
        ui.text(c, line, .{ .mono = true, .size = 12, .wrap = true, .color = color });
    }
}
