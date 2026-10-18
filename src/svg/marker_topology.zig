const std = @import("std");
const v = @import("ziggurat_vector");

// Borrowed, preparation-only topology. No owner, allocator or flattened path.
pub const Limits = v.Arc.Directions;
pub const Kind = enum { start, mid, end };
pub const Role = struct { point: v.Point, direction: ?f64, kind: Kind };
pub const Inspection = struct { vertices: usize = 0, subpaths: usize = 0, legacy: bool = true };

fn vector(a: v.Point, b: v.Point) ?v.Point {
    const result: v.Point = .{ .x = b.x - a.x, .y = b.y - a.y };
    return if (result.x == 0 and result.y == 0) null else result;
}
pub inline fn polynomialOutgoing(start: v.Point, command: v.Command) !?v.Point {
    return switch (command) {
        .line => |p| vector(start, p),
        .quadratic => |q| vector(start, q.control) orelse vector(start, q.end),
        .cubic => |q| vector(start, q.first) orelse vector(start, q.second) orelse vector(start, q.end),
        else => error.UnsupportedMarkerGeometry,
    };
}
pub inline fn polynomialIncoming(start: v.Point, command: v.Command) !?v.Point {
    return switch (command) {
        .line => |p| vector(start, p),
        .quadratic => |q| vector(q.control, q.end) orelse vector(start, q.end),
        .cubic => |q| vector(q.second, q.end) orelse vector(q.first, q.end) orelse vector(start, q.end),
        else => error.UnsupportedMarkerGeometry,
    };
}
fn endPoint(command: v.Command, origin: v.Point) !v.Point {
    return switch (command) {
        .move, .line => |p| p,
        .quadratic => |q| q.end,
        .cubic => |q| q.end,
        .arc => |a| a.end,
        .close => origin,
    };
}
fn omitted(start: v.Point, command: v.Command) bool {
    return command == .arc and start.x == command.arc.end.x and start.y == command.arc.end.y;
}
fn limits(start: v.Point, command: v.Command, origin: v.Point) !?Limits {
    if (command == .arc) return try command.arc.endpointDirections(start);
    if (command == .close) {
        const chord = vector(start, origin) orelse return null;
        return .{ .outgoing = chord, .incoming = chord };
    }
    const first = (try polynomialOutgoing(start, command)) orelse return null;
    return .{ .outgoing = first, .incoming = if (command == .line) first else (try polynomialIncoming(start, command)).? };
}
fn increment(value: *usize) !void {
    value.* = std.math.add(usize, value.*, 1) catch return error.CapacityExceeded;
}

// Arity is inspected before resolving mid: omitted A is not a vertex. This
// scan borrows an already validated Path; it is not Arc precision acceptance.
// Any requested role must run validate before the first paint/Plan.
pub fn inspect(work: anytype, commands: []const v.Command) !Inspection {
    var result: Inspection = .{};
    var pen: v.Point = .{};
    var origin: v.Point = .{};
    var after_close = false;
    for (commands, 0..) |command, index| {
        try work.visit();
        if (index == 0 and command != .move) return error.UnsupportedMarkerGeometry;
        switch (command) {
            .move => |point| {
                if (index != 0) result.legacy = false;
                try increment(&result.subpaths);
                try increment(&result.vertices);
                pen = point;
                origin = point;
                after_close = false;
            },
            .close => {
                if (after_close) return error.UnsupportedMarkerGeometry;
                if (index == 1) result.legacy = false;
                try increment(&result.vertices);
                pen = origin;
                after_close = true;
            },
            else => {
                // Owning Path requires M after Z. The SVG parser inserts that
                // M for subsequent drawing commands and preserves raw moves.
                if (after_close) return error.UnsupportedMarkerGeometry;
                if (omitted(pen, command)) {
                    result.legacy = false;
                } else try increment(&result.vertices);
                pen = try endPoint(command, origin);
            },
        }
    }
    if (commands.len <= 1) result.legacy = false;
    return result;
}
pub fn validate(work: anytype, commands: []const v.Command) !void {
    var pen: v.Point = .{};
    var origin: v.Point = .{};
    for (commands) |command| {
        try work.visit();
        if (command == .move) {
            pen = command.move;
            origin = pen;
        } else {
            // This invokes the shared public Arc validator even for omitted A.
            _ = try limits(pen, command, origin);
            pen = try endPoint(command, origin);
        }
    }
}
pub fn bisector(a: v.Point, b: v.Point) ?f64 {
    const a_scale = @max(@abs(a.x), @abs(a.y));
    const b_scale = @max(@abs(b.x), @abs(b.y));
    const cross = (a.x / a_scale) * (b.y / b_scale) - (a.y / a_scale) * (b.x / b_scale);
    const dot = (a.x / a_scale) * (b.x / b_scale) + (a.y / a_scale) * (b.y / b_scale);
    if (cross == 0 and dot < 0) return null;
    return std.math.atan2(a.y, a.x) + std.math.atan2(cross, dot) / 2;
}

const positive_x: v.Point = .{ .x = 1, .y = 0 };
const Subpath = struct {
    begin: usize,
    end: usize,
    origin: v.Point,
    closed: bool = false,
    retained: usize = 0,
    first: ?v.Point = null,
    last: ?v.Point = null,
    fn seam(self: Subpath) ?f64 {
        return bisector(self.last orelse positive_x, self.first orelse positive_x);
    }
};
fn describe(work: anytype, commands: []const v.Command, begin: usize) !Subpath {
    try work.visit();
    const origin = commands[begin].move;
    var result: Subpath = .{ .begin = begin, .end = commands.len, .origin = origin };
    var pen = origin;
    for (commands[begin + 1 ..], begin + 1..) |command, index| {
        // A delimiter is charged when observed and again when its next
        // subpath's point is consumed. This is bounded by the subpath count.
        try work.visit();
        if (command == .move) {
            result.end = index;
            break;
        }
        const value = try limits(pen, command, origin);
        if (command != .arc or value != null) result.retained += 1;
        if (value) |directions| {
            if (result.first == null) result.first = directions.outgoing;
            result.last = directions.incoming;
        }
        pen = try endPoint(command, origin);
        if (command == .close) {
            result.closed = true;
            result.end = index + 1;
            break;
        }
    }
    return result;
}

// One active subpath plus monotonic role/anchor scans. Boundaries never borrow
// directions across M. Closed seams use a bounded describe pass, not per-vertex
// backscans, and Z stays a real line segment even when zero length.
pub const Cursor = struct {
    commands: []const v.Command,
    total_vertices: usize,
    global_vertex: usize = 0,
    next_subpath: usize = 0,
    subpath: ?Subpath = null,
    phase: enum { begin, segments, next, done } = .begin,
    pending_single_end: bool = false,
    segment: ?usize = null,
    scanned: usize = 0,
    previous: ?struct { index: usize, incoming: v.Point } = null,
    following: ?struct { index: usize, directions: Limits } = null,

    pub fn init(commands: []const v.Command, inspection: Inspection) Cursor {
        return .{ .commands = commands, .total_vertices = inspection.vertices };
    }
    fn start(self: *const Cursor, index: usize) !v.Point {
        return try endPoint(self.commands[index - 1], self.subpath.?.origin);
    }
    fn retainedAfter(self: *Cursor, work: anytype, after: usize) !?usize {
        var index = after;
        while (index + 1 < self.subpath.?.end) {
            try work.visit();
            index += 1;
            if (!omitted(try self.start(index), self.commands[index])) return index;
        }
        return null;
    }
    fn scanAnchor(self: *Cursor, work: anytype) !void {
        self.following = null;
        while (self.scanned + 1 < self.subpath.?.end) {
            try work.visit();
            self.scanned += 1;
            const value = (try limits(try self.start(self.scanned), self.commands[self.scanned], self.subpath.?.origin)) orelse continue;
            self.following = .{ .index = self.scanned, .directions = value };
            return;
        }
    }
    fn midDirection(self: *Cursor, work: anytype, left: usize, right: usize) !?f64 {
        if (self.scanned == self.subpath.?.begin) {
            try self.scanAnchor(work);
            if (self.following) |anchor| if (anchor.index == left) {
                self.previous = .{ .index = anchor.index, .incoming = anchor.directions.incoming };
                try self.scanAnchor(work);
            };
        } else if (self.following) |anchor| if (anchor.index == left) {
            self.previous = .{ .index = anchor.index, .incoming = anchor.directions.incoming };
            try self.scanAnchor(work);
        };
        const before: ?v.Point = if (self.previous) |p| p.incoming else null;
        const after: ?v.Point = if (self.following) |p| p.directions.outgoing else null;
        const incoming = if (self.previous != null and self.previous.?.index == left) self.previous.?.incoming else after orelse before orelse positive_x;
        const outgoing = if (self.following != null and self.following.?.index == right) self.following.?.directions.outgoing else before orelse after orelse positive_x;
        return bisector(incoming, outgoing);
    }
    fn role(self: *Cursor, work: anytype, point: v.Point, angle: ?f64) !Role {
        try work.visit();
        const index = self.global_vertex;
        self.global_vertex += 1;
        if (self.total_vertices == 1) self.pending_single_end = true;
        return .{ .point = point, .direction = angle, .kind = if (index == 0) .start else if (index + 1 == self.total_vertices) .end else .mid };
    }
    pub fn next(self: *Cursor, work: anytype) !?Role {
        if (self.total_vertices == 0) return null;
        if (self.pending_single_end) {
            try work.visit();
            self.pending_single_end = false;
            self.phase = .done;
            return .{ .point = self.subpath.?.origin, .direction = 0, .kind = .end };
        }
        while (true) switch (self.phase) {
            .done => return null,
            .next => {
                self.next_subpath = self.subpath.?.end;
                self.phase = if (self.next_subpath == self.commands.len) .done else .begin;
            },
            .begin => {
                self.subpath = try describe(work, self.commands, self.next_subpath);
                const sub = self.subpath.?;
                self.segment = null;
                self.scanned = sub.begin;
                self.previous = null;
                self.following = null;
                self.phase = if (sub.retained == 0) .next else .segments;
                const first = sub.first orelse positive_x;
                return try self.role(work, sub.origin, if (sub.closed) sub.seam() else std.math.atan2(first.y, first.x));
            },
            .segments => {
                const left = self.segment orelse (try self.retainedAfter(work, self.subpath.?.begin)).?;
                const right = try self.retainedAfter(work, left);
                const point = try endPoint(self.commands[left], self.subpath.?.origin);
                const angle = if (right) |next_index| try self.midDirection(work, left, next_index) else blk: {
                    self.phase = .next;
                    const last = self.subpath.?.last orelse positive_x;
                    break :blk if (self.subpath.?.closed) self.subpath.?.seam() else std.math.atan2(last.y, last.x);
                };
                self.segment = right;
                return try self.role(work, point, angle);
            },
        };
    }
};
