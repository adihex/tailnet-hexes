//! Deterministic, explicitly labelled sample data for offscreen UI checks.
const std = @import("std");
const Client = @import("client.zig").Client;
const w = @import("wire.zig");

pub fn load(s: *Client) !void {
    s.demo = true;
    s.authenticated = true;
    s.online = true;
    s.model.jojo = 1;
    const sessions = try std.json.parseFromSlice(w.Value, s.gpa,
        \\[
        \\ {"id":42,"title":"Build native Hexes","cwd":"/projects/hexes","updatedAt":30,"busy":false,"worktree":{"branch":"hexes/native-client"}},
        \\ {"id":73,"title":"Review the Android release","cwd":"/projects/mobile","updatedAt":20,"busy":true,"worktree":{"branch":"mobile/release"}},
        \\ {"id":18,"title":"Simplify the connection lifecycle","cwd":"/projects/hexes","updatedAt":10,"busy":false}
        \\]
    , .{});
    defer sessions.deinit();
    try s.model.setSessions(sessions.value);
    try s.model.select(42, "Build native Hexes");
    const view = try std.json.parseFromSlice(w.Value, s.gpa,
        \\{
        \\ "full":true,"conversation":{"id":42},"order":[100,101,102,103],"live":{"busy":false},
        \\ "entries":[
        \\  {"id":100,"kind":"user","text":"Let's bring Hexes to the Mac and Android. One native client, both workspaces."},
        \\  {"id":101,"kind":"assistant","blocks":[{"type":"text","text":"## A workspace that goes with you\nThe shared client is taking shape. Your servers and agents stay exactly where they are.\n\n- Switch between **Hexes** and **Hexes CV**.\n- Pick up a conversation on your phone.\n- Ask Jojo what needs your attention.\n\nThe interface adapts from a split workspace on Mac to focused screens on Android."}]},
        \\  {"id":102,"kind":"tool_result","name":"build","text":"Protocol tests passed. Desktop and phone layouts rendered offscreen."},
        \\  {"id":103,"kind":"assistant","text":"The next step is to validate the Android package on a device.\n\n```sh\nzig build -Dtarget=aarch64-linux-android\n```\n\n[Review the release session](/s/73)"}
        \\ ]
        \\}
    , .{});
    defer view.deinit();
    try s.model.timeline.apply(view.value);
    const changes = try std.json.parseFromSlice(w.Value, s.gpa,
        \\{"files":[{"path":"native/src/main.zig","kind":"added"},{"path":"native/src/client.zig","kind":"added"}]}
    , .{});
    defer changes.deinit();
    try s.model.setChanges(changes.value);
    s.model.diff_path = try s.gpa.dupe(u8, "native/src/main.zig");
    s.model.diff = try s.gpa.dupe(u8, "--- /dev/null\n+++ native/src/main.zig\n@@ -0,0 +1,2 @@\n+const nanoui = @import(\"nanoui\");\n+// One client, Mac and Android.");
    s.sidebar = false;
}
