//! The web client's palettes, mapped to native controls with readable labels.
const std = @import("std");
const nui = @import("nanoui");
const ui = nui.ui;
const Color = ui.Color;
const palettes = @import("palettes.zig");
const w = @import("wire.zig");

pub const default_id = "desktop";
pub const Option = struct { id: []const u8, name: []const u8, theme: ?ui.Theme };

pub const modes = [_]Option{
    .{ .id = "desktop", .name = "Follow desktop", .theme = null },
    .{ .id = "system", .name = "System", .theme = null },
    .{ .id = "light", .name = "Light", .theme = ui.Theme.light },
    .{ .id = "dark", .name = "Dark", .theme = ui.Theme.dark_theme },
};

pub const presets = blk: {
    @setEvalBranchQuota(500_000);
    var result: [palettes.all.len]Option = undefined;
    for (palettes.all, 0..) |p, i| result[i] = .{ .id = p.id, .name = p.name, .theme = native(p) };
    break :blk result;
};

pub fn canonical(id: []const u8) ?[]const u8 {
    for (modes ++ presets) |option| if (w.equal(id, option.id)) return option.id;
    return null;
}

pub fn name(id: []const u8) []const u8 {
    for (modes ++ presets) |option| if (w.equal(id, option.id)) return option.name;
    return "Follow desktop";
}

pub fn resolve(id: []const u8, desktop: ?ui.Theme) ?ui.Theme {
    if (w.equal(id, "system")) return null;
    if (w.equal(id, "desktop")) return desktop orelse resolve("tokyo-night", null);
    for (modes ++ presets) |option| if (w.equal(id, option.id)) return option.theme;
    return resolve(default_id, desktop);
}

pub fn server(value: w.Value) ?ui.Theme {
    const colors = w.field(value, "colors");
    const bg = hex(w.text(colors, "background")) orelse return null;
    const fg = hex(w.text(colors, "foreground")) orelse return null;
    const mode = w.text(colors, "mode");
    if (!w.equal(mode, "light") and !w.equal(mode, "dark")) return null;
    return native(.{
        .id = "desktop",
        .name = "Follow desktop",
        .light = w.equal(mode, "light"),
        .background = bg,
        .foreground = fg,
        .bright = hex(w.text(colors, "bright_foreground")) orelse fg,
        .accent = hex(w.text(colors, "accent")) orelse hex(w.text(colors, "blue")) orelse fg,
        .red = hex(w.text(colors, "red")) orelse 0xf7768e,
        .green = hex(w.text(colors, "green")) orelse 0x9ece6a,
    });
}

fn hex(text: []const u8) ?u24 {
    if (text.len != 7 or text[0] != '#') return null;
    return std.fmt.parseInt(u24, text[1..], 16) catch null;
}

fn native(p: palettes.Palette) ui.Theme {
    const bg = Color.hex(p.background);
    const fg = Color.hex(p.foreground);
    const accent = Color.hex(p.accent);
    const ink = contrastingInk(accent);
    return .{
        .dark = !p.light,
        .background = bg,
        .surface = bg.mix(fg, 0.04),
        .surface_hover = bg.mix(fg, 0.08),
        .text = readable(Color.hex(p.bright), bg),
        .muted = readable(bg.mix(fg, if (p.light) 0.78 else 0.62), bg),
        .border = bg.mix(fg, if (p.light) 0.15 else 0.13),
        .accent = accent,
        .accent_hover = accent.mix(if (ink.r == 0) Color.white else Color.black, 0.08),
        .accent_text = ink,
        .track = bg.mix(fg, 0.18),
        .knob = fg,
        .danger = readable(Color.hex(p.red), bg),
        .success = readable(Color.hex(p.green), bg),
        .shadow = Color.black.alpha(if (p.light) 0.12 else 0.4),
    };
}

fn luminance(c: Color) f32 {
    const linear = struct {
        fn channel(v: f32) f32 {
            return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        }
    }.channel;
    return linear(c.r) * 0.2126 + linear(c.g) * 0.7152 + linear(c.b) * 0.0722;
}

pub fn contrast(a: Color, b: Color) f32 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}

fn contrastingInk(background: Color) Color {
    return if (contrast(Color.black, background) >= contrast(Color.white, background)) Color.black else Color.white;
}

fn readable(color: Color, background: Color) Color {
    if (contrast(color, background) >= 4.5) return color;
    const ink = contrastingInk(background);
    var low: f32 = 0;
    var high: f32 = 1;
    for (0..16) |_| {
        const mid = (low + high) / 2;
        if (contrast(color.mix(ink, mid), background) >= 4.5) high = mid else low = mid;
    }
    return color.mix(ink, high);
}
