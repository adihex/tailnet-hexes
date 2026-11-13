const std = @import("std");
const w = @import("wire.zig");
pub const Timeline = @import("timeline.zig").Timeline;

pub const Session = struct {
    id: u64,
    title: []u8,
    cwd: []u8,
    branch: []u8,
    busy: bool,
    waiting: bool,
    updated: u64,

    fn deinit(s: *Session, gpa: std.mem.Allocator) void {
        gpa.free(s.title);
        gpa.free(s.cwd);
        gpa.free(s.branch);
    }
};

pub const Change = struct { path: []u8, kind: []u8 };

pub const Model = struct {
    gpa: std.mem.Allocator,
    sessions: std.ArrayList(Session) = .empty,
    timeline: Timeline,
    changes: std.ArrayList(Change) = .empty,
    diff: []u8 = &.{},
    diff_path: []u8 = &.{},
    selected: ?u64 = null,
    jojo: ?u64 = null,
    title: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa, .timeline = .{ .gpa = gpa } };
    }

    pub fn clearChanges(m: *Model) void {
        for (m.changes.items) |e| {
            m.gpa.free(e.path);
            m.gpa.free(e.kind);
        }
        m.changes.clearRetainingCapacity();
        m.gpa.free(m.diff);
        m.gpa.free(m.diff_path);
        m.diff = &.{};
        m.diff_path = &.{};
    }

    pub fn deinit(m: *Model) void {
        for (m.sessions.items) |*s| s.deinit(m.gpa);
        m.sessions.deinit(m.gpa);
        m.timeline.deinit();
        m.clearChanges();
        m.changes.deinit(m.gpa);
        m.gpa.free(m.title);
    }

    pub fn setSessions(m: *Model, data: w.Value) !void {
        if (data != .array) return error.InvalidSessions;
        var next: std.ArrayList(Session) = .empty;
        errdefer {
            for (next.items) |*s| s.deinit(m.gpa);
            next.deinit(m.gpa);
        }
        for (data.array.items) |v| {
            const id = w.number(w.field(v, "id"));
            if (id == 0 or w.boolean(w.field(v, "archived"))) continue;
            const title = try m.gpa.dupe(u8, w.text(v, "title"));
            errdefer m.gpa.free(title);
            const cwd = try m.gpa.dupe(u8, w.text(v, "cwd"));
            errdefer m.gpa.free(cwd);
            const branch = try m.gpa.dupe(u8, w.text(w.field(v, "worktree"), "branch"));
            errdefer m.gpa.free(branch);
            try next.append(m.gpa, .{
                .id = id,
                .title = title,
                .cwd = cwd,
                .branch = branch,
                .busy = w.boolean(w.field(v, "busy")),
                .waiting = w.boolean(w.field(v, "waiting")),
                .updated = w.number(w.field(v, "updatedAt")),
            });
        }
        std.mem.sort(Session, next.items, {}, struct {
            fn less(_: void, a: Session, b: Session) bool {
                return a.updated > b.updated;
            }
        }.less);
        for (m.sessions.items) |*s| s.deinit(m.gpa);
        m.sessions.deinit(m.gpa);
        m.sessions = next;
    }

    pub fn select(m: *Model, id: u64, title: []const u8) !void {
        const copy = try m.gpa.dupe(u8, title);
        m.gpa.free(m.title);
        m.title = copy;
        m.selected = id;
        m.timeline.clear();
        m.clearChanges();
    }

    pub fn setChanges(m: *Model, data: w.Value) !void {
        if (w.field(data, "files") != .array) return error.InvalidChanges;
        m.clearChanges();
        for (w.array(w.field(data, "files"))) |v| {
            const path = try m.gpa.dupe(u8, w.text(v, "path"));
            errdefer m.gpa.free(path);
            const kind = try m.gpa.dupe(u8, w.text(v, "kind"));
            errdefer m.gpa.free(kind);
            try m.changes.append(m.gpa, .{ .path = path, .kind = kind });
        }
    }
};
