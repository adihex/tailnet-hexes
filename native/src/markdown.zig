//! Small native Markdown renderer; no HTML, scripts, or implicit URL execution.
const std = @import("std");
const nui = @import("nanoui");
const ui = nui.ui;
const Client = @import("client.zig").Client;
const w = @import("wire.zig");

pub const Link = struct { label: []const u8, url: []const u8, session: ?u64 };
pub const Inline = struct { text: []const u8, spans: []ui.Span, links: []Link };

pub fn sessionId(url: []const u8) ?u64 {
    const prefixes = [_][]const u8{ "/s/", "/#/c/" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, url, prefix)) continue;
        const rest = std.mem.trimEnd(u8, url[prefix.len..], "/");
        const id = std.fmt.parseInt(u64, rest, 10) catch return null;
        return if (id > 0) id else null;
    }
    return null;
}

pub fn safeUrl(url: []const u8) bool {
    for (url) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "mailto:");
}

const Mention = struct { id: u64, end: usize };

fn sessionMention(source: []const u8, start: usize) ?Mention {
    if (start > 0 and std.mem.indexOfScalar(u8, " \t\n([", source[start - 1]) == null) return null;
    const rest = source[start..];
    var digits: usize = start;
    if (std.mem.startsWith(u8, rest, "/s/")) {
        digits += 3;
    } else if (rest.len >= 8 and std.ascii.eqlIgnoreCase(rest[0..8], "session ")) {
        digits += 8;
        if (digits < source.len and source[digits] == '#') digits += 1;
    } else return null;
    var end = digits;
    while (end < source.len and std.ascii.isDigit(source[end])) : (end += 1) {}
    if (end == digits) return null;
    if (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_' or source[end] == '/')) return null;
    const id = std.fmt.parseInt(u64, source[digits..end], 10) catch return null;
    return if (id > 0) .{ .id = id, .end = end } else null;
}

pub fn inlineText(a: std.mem.Allocator, source: []const u8) !Inline {
    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(ui.Span) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '[') {
            if (std.mem.indexOfPos(u8, source, i + 1, "](")) |mid| {
                if (std.mem.indexOfScalarPos(u8, source, mid + 2, ')')) |end| {
                    const url = source[mid + 2 .. end];
                    if (sessionId(url) != null or safeUrl(url)) {
                        const start = text.items.len;
                        const label = source[i + 1 .. mid];
                        try text.appendSlice(a, label);
                        try spans.append(a, .{ .start = @intCast(start), .end = @intCast(text.items.len), .underline = true });
                        try links.append(a, .{ .label = label, .url = url, .session = sessionId(url) });
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        const Marker = struct { text: []const u8, weight: ?ui.Weight = null, mono: bool = false, italic: bool = false, strike: bool = false };
        const markers = [_]Marker{
            .{ .text = "`", .mono = true },         .{ .text = "**", .weight = .semibold },
            .{ .text = "__", .weight = .semibold }, .{ .text = "~~", .strike = true },
            .{ .text = "*", .italic = true },
        };
        var matched = false;
        for (markers) |marker| {
            if (!std.mem.startsWith(u8, source[i..], marker.text)) continue;
            const from = i + marker.text.len;
            const end = std.mem.indexOfPos(u8, source, from, marker.text) orelse continue;
            if (end == from) continue;
            const start = text.items.len;
            try text.appendSlice(a, source[from..end]);
            try spans.append(a, .{
                .start = @intCast(start),
                .end = @intCast(text.items.len),
                .weight = marker.weight,
                .mono = marker.mono,
                .italic = marker.italic,
                .strike = marker.strike,
            });
            i = end + marker.text.len;
            matched = true;
            break;
        }
        if (matched) continue;
        if (sessionMention(source, i)) |mention| {
            const start = text.items.len;
            const label = source[i..mention.end];
            try text.appendSlice(a, label);
            try spans.append(a, .{ .start = @intCast(start), .end = @intCast(text.items.len), .underline = true });
            try links.append(a, .{ .label = label, .url = "", .session = mention.id });
            i = mention.end;
            continue;
        }
        try text.append(a, source[i]);
        i += 1;
    }
    return .{ .text = try text.toOwnedSlice(a), .spans = try spans.toOwnedSlice(a), .links = try links.toOwnedSlice(a) };
}

fn paragraph(s: *Client, c: *ui.Context, source: []const u8, size: f32, bold: bool) void {
    const parsed = inlineText(c.alloc(), source) catch {
        ui.text(c, source, .{ .wrap = true });
        return;
    };
    ui.richText(c, parsed.text, parsed.spans, .{ .size = size, .wrap = true, .leading = 1.4, .weight = if (bold) .semibold else .regular });
    for (parsed.links, 0..) |link, i| {
        ui.keyInt(c, i);
        if (link.session) |id| {
            if (ui.button(c, c.print("Open session #{d}", .{id}), .{ .variant = .ghost, .size = 12 }).clicked) s.select(id, link.label);
        } else if (ui.button(c, c.print("Open: {s}", .{link.label}), .{ .variant = .ghost, .size = 12 }).clicked) {
            if (!s.demo and s.transport.start == null) _ = nui.shell.openUrl(link.url);
        }
    }
}

pub fn render(s: *Client, c: *ui.Context, source: []const u8) void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var paragraph_text: std.ArrayList(u8) = .empty;
    var code: std.ArrayList(u8) = .empty;
    var fence: ?[]const u8 = null;
    var language: []const u8 = "";
    var index: usize = 0;
    while (lines.next()) |raw| : (index += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = w.trim(line);
        ui.keyInt(c, index);
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            if (fence) |mark| {
                if (std.mem.startsWith(u8, trimmed, mark)) {
                    codeBlock(c, language, code.items);
                    code.clearRetainingCapacity();
                    fence = null;
                } else {
                    code.appendSlice(c.alloc(), line) catch {};
                    code.append(c.alloc(), '\n') catch {};
                }
            } else {
                flush(s, c, &paragraph_text);
                fence = trimmed[0..3];
                language = w.trim(trimmed[3..]);
            }
            continue;
        }
        if (fence != null) {
            code.appendSlice(c.alloc(), line) catch {};
            code.append(c.alloc(), '\n') catch {};
            continue;
        }
        if (trimmed.len == 0) {
            flush(s, c, &paragraph_text);
            continue;
        }
        var hashes: usize = 0;
        while (hashes < trimmed.len and trimmed[hashes] == '#') : (hashes += 1) {}
        if (hashes > 0 and hashes <= 6 and hashes < trimmed.len and trimmed[hashes] == ' ') {
            flush(s, c, &paragraph_text);
            paragraph(s, c, w.trim(trimmed[hashes..]), if (hashes == 1) 23 else 18, true);
        } else if (w.equal(trimmed, "---") or w.equal(trimmed, "***")) {
            flush(s, c, &paragraph_text);
            ui.divider(c);
        } else if (trimmed.len > 2 and (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "> "))) {
            flush(s, c, &paragraph_text);
            const row = ui.div(c).row().wFull().gap(10);
            defer row.end();
            ui.text(c, if (trimmed[0] == '>') "│" else "•", .{ .color = c.theme.muted });
            const content = ui.div(c).column().grow().wFull();
            defer content.end();
            paragraph(s, c, trimmed[2..], 14, false);
        } else {
            if (paragraph_text.items.len > 0) paragraph_text.append(c.alloc(), '\n') catch {};
            paragraph_text.appendSlice(c.alloc(), line) catch {};
        }
    }
    if (fence != null) codeBlock(c, language, code.items);
    flush(s, c, &paragraph_text);
}

fn flush(s: *Client, c: *ui.Context, text: *std.ArrayList(u8)) void {
    if (text.items.len == 0) return;
    // Frame storage: old paragraphs must not be overwritten when the list is reused.
    const copy = c.alloc().dupe(u8, text.items) catch return;
    paragraph(s, c, copy, 14, false);
    text.clearRetainingCapacity();
}

fn codeBlock(c: *ui.Context, language: []const u8, text: []const u8) void {
    const box = ui.div(c).column().wFull().p(14).gap(8).rounded(10).bg(c.theme.surface).border(c.theme.border);
    defer box.end();
    if (language.len > 0) ui.label(c, language);
    const copy = c.alloc().dupe(u8, text) catch return;
    ui.text(c, copy, .{ .mono = true, .size = 12, .wrap = true, .leading = 1.35 });
}
