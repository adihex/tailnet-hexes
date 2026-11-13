//! Snapshot windows are authoritative; loaded older history lives outside that window.
const std = @import("std");
const w = @import("wire.zig");
const Value = w.Value;

pub const Entry = struct {
    id: u64,
    kind: Kind,
    text: []u8,
    name: []u8,
    is_error: bool = false,

    pub const Kind = enum { user, assistant, tool, system };

    pub fn parse(gpa: std.mem.Allocator, v: Value) !Entry {
        const kind = w.text(v, "kind");
        const role = w.text(v, "role");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const plain = w.text(v, "text");
        if (plain.len > 0) {
            try out.appendSlice(gpa, plain);
        } else {
            for (w.array(w.field(v, "blocks"))) |block| {
                // Thinking stays private; tool calls get their own concise row.
                if (w.equal(w.text(block, "type"), "thinking")) continue;
                var text = w.text(block, "text");
                if (text.len == 0 and w.equal(w.text(block, "type"), "text")) text = w.text(block, "content");
                if (text.len == 0) continue;
                if (out.items.len > 0) try out.append(gpa, '\n');
                try out.appendSlice(gpa, text);
            }
        }
        if (out.items.len == 0) {
            const output = w.text(v, "output");
            if (output.len > 0) try out.appendSlice(gpa, output);
        }
        const name = try gpa.dupe(u8, w.text(v, "name"));
        errdefer gpa.free(name);
        return .{
            .id = w.number(w.field(v, "id")),
            .kind = if (w.equal(kind, "user") or w.equal(role, "user")) .user else if (w.equal(kind, "assistant") or w.equal(role, "assistant")) .assistant else if (std.mem.startsWith(u8, kind, "tool") or w.equal(kind, "shell")) .tool else .system,
            .text = try out.toOwnedSlice(gpa),
            .name = name,
            .is_error = w.boolean(w.field(v, "isError")),
        };
    }

    pub fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(e.text);
        gpa.free(e.name);
    }
};

pub const Timeline = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    older: std.ArrayList(Entry) = .empty,
    live: []u8 = &.{},
    busy: bool = false,
    history_done: bool = false,

    pub fn clear(t: *Timeline) void {
        for (t.entries.items) |*e| e.deinit(t.gpa);
        for (t.older.items) |*e| e.deinit(t.gpa);
        t.entries.clearRetainingCapacity();
        t.older.clearRetainingCapacity();
        t.gpa.free(t.live);
        t.live = &.{};
        t.busy = false;
        t.history_done = false;
    }

    pub fn deinit(t: *Timeline) void {
        t.clear();
        t.entries.deinit(t.gpa);
        t.older.deinit(t.gpa);
    }

    fn find(entries: []const Entry, id: u64) ?usize {
        for (entries, 0..) |e, i| if (e.id == id) return i;
        return null;
    }

    pub fn apply(t: *Timeline, data: Value) !void {
        if (data != .object or w.field(data, "entries") != .array) return error.InvalidView;
        if (w.boolean(w.field(data, "full"))) {
            for (t.entries.items) |*e| e.deinit(t.gpa);
            t.entries.clearRetainingCapacity();
        }
        for (w.array(w.field(data, "entries"))) |v| {
            var e = try Entry.parse(t.gpa, v);
            errdefer e.deinit(t.gpa);
            if (e.id == 0) {
                e.deinit(t.gpa);
                continue;
            }
            if (find(t.entries.items, e.id)) |i| {
                t.entries.items[i].deinit(t.gpa);
                t.entries.items[i] = e;
            } else try t.entries.append(t.gpa, e);
        }
        // Order is a server-supplied branch/order, not necessarily numeric ID order.
        if (w.field(data, "order") == .array) {
            var ordered: std.ArrayList(Entry) = .empty;
            errdefer ordered.deinit(t.gpa);
            for (w.array(w.field(data, "order"))) |v| {
                const id = w.number(v);
                if (find(ordered.items, id) != null) continue;
                if (find(t.entries.items, id)) |i| try ordered.append(t.gpa, t.entries.items[i]);
            }
            for (t.entries.items) |*e| if (find(ordered.items, e.id) == null) e.deinit(t.gpa);
            t.entries.deinit(t.gpa);
            t.entries = ordered;
        }
        // A history page can overlap a reconnected snapshot.
        var i: usize = 0;
        while (i < t.older.items.len) {
            if (find(t.entries.items, t.older.items[i].id) != null) {
                var e = t.older.orderedRemove(i);
                e.deinit(t.gpa);
            } else i += 1;
        }
        const live = w.field(data, "live");
        if (live == .object) {
            t.busy = w.boolean(w.field(live, "busy"));
            const generation = w.field(live, "generation");
            var message = try Entry.parse(t.gpa, w.field(generation, "message"));
            defer message.deinit(t.gpa);
            const copy = try t.gpa.dupe(u8, message.text);
            t.gpa.free(t.live);
            t.live = copy;
        }
    }

    pub fn before(t: *const Timeline) ?u64 {
        if (t.older.items.len > 0) return t.older.items[0].id;
        if (t.entries.items.len > 0) return t.entries.items[0].id;
        return null;
    }

    pub fn history(t: *Timeline, data: Value) !void {
        const values = if (data == .array) data else w.field(data, "entries");
        if (values != .array) return error.InvalidHistory;
        var added: usize = 0;
        for (values.array.items) |v| {
            const id = w.number(w.field(v, "id"));
            if (id == 0 or find(t.entries.items, id) != null or find(t.older.items, id) != null) continue;
            var e = try Entry.parse(t.gpa, v);
            errdefer e.deinit(t.gpa);
            try t.older.append(t.gpa, e);
            added += 1;
        }
        std.mem.sort(Entry, t.older.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.id < b.id;
            }
        }.less);
        t.history_done = added == 0;
    }
};
