const std = @import("std");
const nui = @import("nanoui");
const Client = @import("client.zig").Client;
const view = @import("view.zig");
const demo = @import("demo.zig");
const themes = @import("themes.zig");
const settings = @import("profile_settings.zig");

pub const panic = nui.panic;
pub const std_options = nui.std_options;

pub fn main(init: std.process.Init) !void {
    const app = try nui.App.create(init, .{ .name = "Hexes" });
    defer app.destroy();
    // Requests can outlive a closing window. Their references keep this state
    // alive; dead callbacks never touch the App or its windows.
    const s = try Client.create(std.heap.c_allocator, .{});
    defer s.shutdown();
    s.allow_storage = app.flags.snapshot == null;
    var demo_mode = false;
    var phone = false;
    var theme_arg: ?[]const u8 = null;
    for (try init.minimal.args.toSlice(init.arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, "--hexes-demo")) demo_mode = true;
        if (std.mem.eql(u8, arg, "--hexes-phone")) phone = true;
        if (std.mem.eql(u8, arg, "--hexes-profile=cv")) s.profile = 1;
        if (std.mem.eql(u8, arg, "--hexes-read-only")) s.read_only = true;
        if (std.mem.startsWith(u8, arg, "--hexes-session=")) s.initial_session = try std.fmt.parseInt(u64, arg[16..], 10);
        if (std.mem.startsWith(u8, arg, "--hexes-theme=")) theme_arg = themes.canonical(arg[14..]) orelse return error.InvalidTheme;
    }
    if (demo_mode or s.read_only) s.allow_storage = false;
    if (s.allow_storage) {
        if (settings.openPreferences(s.gpa)) |store| {
            s.loadPreferences(store);
        } else |_| {
            s.inform("Device storage is unavailable. Profile settings are kept for this session only.");
        }
    }
    if (theme_arg) |id| s.profileSettings().theme_id = id;
    if (demo_mode) {
        try demo.load(s);
    } else if (s.read_only) {
        s.connect("");
    } else s.autoConnect();
    s.window = try app.newWindow(.{
        .title = "Hexes",
        // Also give direct checkout launches their icon, not only .app bundles.
        .icon = @embedFile("app_icon"),
        .width = if (phone) 393 else 1180,
        .height = if (phone) 852 else 820,
        // The view picks each profile's theme. A window override would pin
        // System appearance to the theme of whichever profile opened first.
        .content = .{ .view = .init(s, view.render) },
    });
    try app.setMenu(&.{
        .{ .role = .app_menu },
        .{ .role = .edit_menu },
        .{ .role = .window_menu },
    });
    try app.run();
    if (s.read_only and app.flags.snapshot != null) {
        if (!s.authenticated or !s.online or s.ack == 0) return error.ReadOnlyConnectionFailed;
        if (s.model.selected != null and !s.view_received) return error.ReadOnlyConversationMissing;
        std.log.info("Read-only connection verified: {d} sessions, {d} entries, {d} acknowledged events", .{
            s.model.sessions.items.len, s.model.timeline.entries.items.len, s.ack,
        });
    }
}
