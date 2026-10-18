const std = @import("std");
const api = @import("root.zig");
pub const Point = api.Point;
pub const Contour = struct { start: usize, len: usize, closed: bool };
pub const Edge = struct { a: Point, b: Point };
const intervals = @import("intervals.zig");
const arcs = @import("arc.zig");

fn plus(a: Point, b: Point) Point {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
fn minus(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn times(a: Point, v: f64) Point {
    return .{ .x = a.x * v, .y = a.y * v };
}
fn dot(a: Point, b: Point) f64 {
    return a.x * b.x + a.y * b.y;
}
fn cross(a: Point, b: Point) f64 {
    return a.x * b.y - a.y * b.x;
}
fn length(a: Point) f64 {
    return @sqrt(dot(a, a));
}
fn midpoint(a: Point, b: Point) Point {
    return times(plus(a, b), 0.5);
}
fn equal(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

pub const Flat = struct {
    points: ?[]Point = null,
    contours: ?[]Contour = null,
    count: usize = 0,
    contour_count: usize = 0,
    start: usize = 0,
    active: bool = false,
    options: api.PrepareOptions,
    fn vertex(self: *Flat, point: Point) !void {
        // Bound both passes, including pathological subdivision work.
        if (self.count == self.options.limits.vertices) return error.VerticesFull;
        const p = self.options.transform.apply(point);
        if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y) or @abs(p.x) > 1e9 or @abs(p.y) > 1e9) return error.TransformedGeometryTooLarge;
        if (self.points) |points| points[self.count] = if (transformedStroke(self.options)) p else point;
        self.count += 1;
    }
    fn finish(self: *Flat, closed: bool) void {
        if (!self.active) return;
        if (self.contours) |contours| contours[self.contour_count] = .{ .start = self.start, .len = self.count - self.start, .closed = closed };
        self.contour_count += 1;
        self.active = false;
    }
    fn begin(self: *Flat, p: Point) !void {
        self.finish(false);
        self.start = self.count;
        self.active = true;
        try self.vertex(p);
    }
    pub fn flatten(self: *Flat, commands: []const api.Command) !void {
        var pen: Point = .{};
        for (commands) |command| {
            try self.options.check();
            switch (command) {
                .move => |p| {
                    try self.begin(p);
                    pen = p;
                },
                .line => |p| {
                    try self.vertex(p);
                    pen = p;
                },
                .quadratic => |q| {
                    // Conversion preserves the quadratic exactly in real arithmetic.
                    try self.curve(pen, plus(pen, times(minus(q.control, pen), 2.0 / 3.0)), plus(q.end, times(minus(q.control, q.end), 2.0 / 3.0)), q.end, 0);
                    pen = q.end;
                },
                .cubic => |q| {
                    try self.curve(pen, q.first, q.second, q.end, 0);
                    pen = q.end;
                },
                .arc => |value| {
                    try self.arc(pen, value);
                    pen = value.end;
                },
                .close => self.finish(true),
            }
        }
        self.finish(false);
    }
    fn curve(self: *Flat, a: Point, b: Point, c: Point, d: Point, depth: u8) !void {
        const transform = self.options.transform;
        const ha = transform.apply(a);
        const hd = transform.apply(d);
        const hb = transform.apply(b);
        const hc = transform.apply(c);
        const pa = if (self.options.stroke_output) |output| output.apply(ha) else ha;
        const pd = if (self.options.stroke_output) |output| output.apply(hd) else hd;
        const pb = if (self.options.stroke_output) |output| output.apply(hb) else hb;
        const pc = if (self.options.stroke_output) |output| output.apply(hc) else hc;
        // The convex hull lies within this distance of the chord segment,
        // including collinear curves that double back beyond its endpoints.
        const tolerance = self.options.tolerance / self.options.scale;
        const cuts = self.options.style == .stroke and self.options.style.stroke.hasCuts() and !transformedStroke(self.options);
        const local_tolerance = self.options.tolerance / @max(@as(f64, self.options.scale), 1);
        const host_cuts = transformedStroke(self.options) and self.options.style.stroke.hasCuts();
        if (@max(distanceSquared(pb, pa, pd), distanceSquared(pc, pa, pd)) <= tolerance * tolerance and
            (!host_cuts or @max(distanceSquared(hb, ha, hd), distanceSquared(hc, ha, hd)) <= local_tolerance * local_tolerance) and
            (!cuts or @max(distanceSquared(b, a, d), distanceSquared(c, a, d)) <= local_tolerance * local_tolerance)) return self.vertex(d);
        if (depth == 20) return error.CurveTooComplex;
        try self.options.check();
        const ab = midpoint(a, b);
        const bc = midpoint(b, c);
        const cd = midpoint(c, d);
        const abc = midpoint(ab, bc);
        const bcd = midpoint(bc, cd);
        const center = midpoint(abc, bcd);
        try self.curve(a, ab, abc, center, depth + 1);
        try self.curve(center, bcd, cd, d, depth + 1);
    }
    fn arc(self: *Flat, start: Point, value: api.Arc) !void {
        const ellipse = switch (try arcs.resolve(start, value)) {
            .none => return,
            .line => |point| return self.vertex(point),
            .ellipse => |ellipse| ellipse,
        };
        const host = self.options.transform;
        const matrix = if (self.options.stroke_output) |output| host.then(output.*) else host;
        const ax: Point = .{ .x = matrix.xx * ellipse.x_axis.x + matrix.xy * ellipse.x_axis.y, .y = matrix.yx * ellipse.x_axis.x + matrix.yy * ellipse.x_axis.y };
        const ay: Point = .{ .x = matrix.xx * ellipse.y_axis.x + matrix.xy * ellipse.y_axis.y, .y = matrix.yx * ellipse.y_axis.x + matrix.yy * ellipse.y_axis.y };
        var norm = @sqrt(dot(ax, ax) + dot(ay, ay)) * self.options.scale;
        if (transformedStroke(self.options) and self.options.style.stroke.hasCuts()) {
            const hx: Point = .{ .x = host.xx * ellipse.x_axis.x + host.xy * ellipse.x_axis.y, .y = host.yx * ellipse.x_axis.x + host.yy * ellipse.x_axis.y };
            const hy: Point = .{ .x = host.xx * ellipse.y_axis.x + host.xy * ellipse.y_axis.y, .y = host.yx * ellipse.y_axis.x + host.yy * ellipse.y_axis.y };
            norm = @max(norm, @sqrt(dot(hx, hx) + dot(hy, hy)) * @max(@as(f64, self.options.scale), 1));
        }
        if (self.options.style == .stroke and self.options.style.stroke.hasCuts() and !transformedStroke(self.options)) norm = @max(norm, @sqrt(dot(ellipse.x_axis, ellipse.x_axis) + dot(ellipse.y_axis, ellipse.y_axis)) * @max(@as(f64, self.options.scale), 1));
        try self.arcPart(ellipse, ellipse.start, ellipse.sweep, value.end, norm, 0);
    }
    fn arcPart(self: *Flat, ellipse: Ellipse, angle: f64, sweep: f64, end: Point, norm: f64, depth: u8) !void {
        const half_sine = @sin(sweep / 4);
        if (@abs(sweep) <= std.math.pi and 2 * half_sine * half_sine * norm <= self.options.tolerance) return self.vertex(end);
        if (depth == 20) return error.CurveTooComplex;
        try self.options.check();
        const half = sweep / 2;
        const center = ellipse.at(angle + half);
        try self.arcPart(ellipse, angle, half, center, norm, depth + 1);
        try self.arcPart(ellipse, angle + half, half, end, norm, depth + 1);
    }
};
const Ellipse = arcs.Ellipse;
fn distanceSquared(p: Point, a: Point, b: Point) f64 {
    const delta = minus(b, a);
    const size = dot(delta, delta);
    const weight = if (size == 0) 0 else std.math.clamp(dot(minus(p, a), delta) / size, 0, 1);
    const offset = minus(p, plus(a, times(delta, weight)));
    return dot(offset, offset);
}

pub const Edges = struct {
    storage: ?[]Edge = null,
    count: usize = 0,
    attempts: u64 = 0,
    stroke_work: u64 = 0,
    options: api.PrepareOptions,
    left: f64,
    top: f64,
    fn add(self: *Edges, a: Point, b: Point) !void {
        if (self.attempts == self.options.limits.edge_attempts) return error.GeometryBudgetExceeded;
        self.attempts += 1;
        if (equal(a, b)) return;
        const p = self.options.transform.apply(a);
        const q = self.options.transform.apply(b);
        const scale: f64 = self.options.scale;
        const pa: Point = .{ .x = p.x * scale - self.left, .y = p.y * scale - self.top };
        const pb: Point = .{ .x = q.x * scale - self.left, .y = q.y * scale - self.top };
        if (!std.math.isFinite(pa.x) or !std.math.isFinite(pa.y) or !std.math.isFinite(pb.x) or !std.math.isFinite(pb.y) or @abs(pa.x) > 16e9 or @abs(pa.y) > 16e9 or @abs(pb.x) > 16e9 or @abs(pb.y) > 16e9) return error.TransformedGeometryTooLarge;
        if (pa.y == pb.y) return;
        if (self.count == self.options.limits.edges) return error.EdgesFull;
        if (self.storage) |storage| storage[self.count] = .{ .a = pa, .b = pb };
        self.count += 1;
    }
    fn polygon(self: *Edges, points: []const Point) !void {
        if (points.len < 3) return;
        var area: f64 = 0;
        const origin = points[0];
        for (points, 0..) |point, i| area += cross(minus(point, origin), minus(points[(i + 1) % points.len], origin));
        if (area == 0) return;
        for (points, 0..) |point, i| {
            const next = points[(i + 1) % points.len];
            if (area > 0) try self.add(point, next) else try self.add(next, point);
        }
    }
    fn disk(self: *Edges, center: Point, radius: f64) !void {
        const matrix = self.options.transform;
        // Frobenius norm bounds transformed chord error even under shear.
        const norm = @sqrt(matrix.xx * matrix.xx + matrix.xy * matrix.xy + matrix.yx * matrix.yx + matrix.yy * matrix.yy) * self.options.scale;
        const physical_radius = radius * norm;
        if (physical_radius == 0) return;
        const ratio = std.math.clamp(self.options.tolerance / physical_radius, 0, 2);
        const angle = if (ratio < 1e-8) @sqrt(2 * ratio) else std.math.acos(1 - ratio);
        const count_float = if (angle == 0) std.math.inf(f64) else @ceil(std.math.pi / angle);
        if (!std.math.isFinite(count_float) or count_float > 65536) return error.CurveTooComplex;
        const count: usize = @intFromFloat(@max(8, count_float));
        // A singular transform can discard every generated edge. Preflight
        // the generating work independently of the final scan edge count.
        if (count > self.options.limits.edge_attempts - self.attempts) return error.GeometryBudgetExceeded;
        var previous: Point = plus(center, .{ .x = radius });
        for (1..count + 1) |index| {
            if (index % 256 == 0) try self.options.check();
            const radians = @as(f64, @floatFromInt(index)) * (2 * std.math.pi / @as(f64, @floatFromInt(count)));
            const next = if (index == count) plus(center, Point{ .x = radius }) else plus(center, Point{ .x = @cos(radians) * radius, .y = @sin(radians) * radius });
            try self.add(previous, next);
            previous = next;
        }
    }
    fn join(self: *Edges, p: Point, before: Point, after: Point, stroke: api.Stroke) !void {
        const turn = cross(before, after);
        const alignment = dot(before, after);
        if (turn == 0 and alignment >= 0) return;
        const radius = stroke.width / 2;
        if (stroke.join == .round) return self.disk(p, radius);
        if (turn == 0) return; // Reversing butt rectangles already cover a bevel.
        const side: f64 = if (turn > 0) -1 else 1;
        const normal_a: Point = .{ .x = -before.y, .y = before.x };
        const normal_b: Point = .{ .x = -after.y, .y = after.x };
        const a = plus(p, times(normal_a, radius * side));
        const b = plus(p, times(normal_b, radius * side));
        if (stroke.join == .miter and 1 + alignment > 0) {
            const offset = times(plus(normal_a, normal_b), radius * side / (1 + alignment));
            if (length(offset) <= stroke.miter_limit * radius) return self.polygon(&.{ p, a, plus(p, offset), b });
        }
        try self.polygon(&.{ p, a, b });
    }
    fn strokeContour(self: *Edges, points: []const Point, closed: bool, stroke: api.Stroke) !void {
        // A lone moveto is not a zero-length segment. An explicit repeated
        // endpoint still has two vertices and receives the requested cap.
        if (points.len == 1 and !closed) return;
        if (stroke.hasCuts()) return self.cutContour(points, closed, stroke);
        const radius = stroke.width / 2;
        var first: ?Point = null;
        var previous: ?Point = null;
        var first_position: Point = points[0];
        var last_position: Point = points[0];
        const count = if (closed) points.len else points.len - 1;
        for (0..count) |index| {
            const a = points[index];
            const b = points[(index + 1) % points.len];
            const delta = minus(b, a);
            const size = length(delta);
            if (size == 0) continue;
            const direction = times(delta, 1 / size);
            if (first == null) {
                first = direction;
                first_position = a;
            }
            if (previous) |before| try self.join(a, before, direction, stroke);
            const normal: Point = .{ .x = -direction.y * radius, .y = direction.x * radius };
            try self.polygon(&.{ plus(a, normal), minus(a, normal), minus(b, normal), plus(b, normal) });
            previous = direction;
            last_position = b;
        }
        if (first) |start| {
            const end = previous.?;
            if (closed) return self.join(first_position, end, start, stroke);
            switch (stroke.cap) {
                .butt => {},
                .round => {
                    try self.disk(first_position, radius);
                    try self.disk(last_position, radius);
                },
                .square => {
                    const sn: Point = .{ .x = -start.y * radius, .y = start.x * radius };
                    const en: Point = .{ .x = -end.y * radius, .y = end.x * radius };
                    const extended_start = minus(first_position, times(start, radius));
                    const extended_end = plus(last_position, times(end, radius));
                    try self.polygon(&.{ plus(first_position, sn), minus(first_position, sn), minus(extended_start, sn), plus(extended_start, sn) });
                    try self.polygon(&.{ plus(last_position, en), minus(last_position, en), minus(extended_end, en), plus(extended_end, en) });
                },
            }
        } else {
            switch (stroke.cap) {
                .butt => {},
                .round => try self.disk(first_position, radius),
                .square => try self.polygon(&.{ plus(first_position, .{ .x = -radius, .y = -radius }), plus(first_position, .{ .x = radius, .y = -radius }), plus(first_position, .{ .x = radius, .y = radius }), plus(first_position, .{ .x = -radius, .y = radius }) }),
            }
        }
    }
    fn cap(self: *Edges, position: Point, direction: Point, stroke: api.Stroke, start: bool) !void {
        const radius = stroke.width / 2;
        switch (stroke.cap) {
            .butt => {},
            .round => try self.disk(position, radius),
            .square => {
                const normal: Point = .{ .x = -direction.y * radius, .y = direction.x * radius };
                const end = plus(position, times(direction, if (start) -radius else radius));
                try self.polygon(&.{ plus(position, normal), minus(position, normal), minus(end, normal), plus(end, normal) });
            },
        }
    }
    fn cutContour(self: *Edges, points: []const Point, closed: bool, stroke: api.Stroke) !void {
        var work: intervals.Work = .{ .used = self.stroke_work, .options = self.options };
        defer self.stroke_work = work.used;
        const count = if (closed) points.len else points.len - 1;
        var total: f64 = 0;
        for (0..count) |index| {
            try work.step();
            const size = length(minus(points[(index + 1) % points.len], points[index]));
            if (size > 0 and total + size == total) return error.UnsupportedStrokePrecision;
            total += size;
        }
        var ranges = try intervals.Iterator.init(stroke, total, &work);
        var cursor: CutCursor = .{ .points = points, .count = count };
        var first: ?StrokeRun = null;
        var last: ?StrokeRun = null;
        while (try ranges.next(&work)) |range| {
            const run = try cursor.emit(self, stroke, range, &work);
            if (run.first == null) {
                // Zero on-dashes inherit the path's tangent; a genuinely
                // zero-length subpath uses the default positive x tangent.
                const tangent = cursor.tangent();
                try self.cap(run.first_position, tangent, stroke, true);
                try self.cap(run.first_position, tangent, stroke, false);
                continue;
            }
            if (closed and range.start == 0 and first == null) first = run else try self.cap(run.first_position, run.first.?, stroke, true);
            if (closed and range.end == total) last = run else try self.cap(run.last_position, run.previous.?, stroke, false);
        }
        if (first) |initial| {
            if (last) |final| try self.join(points[0], final.previous.?, initial.first.?, stroke) else try self.cap(initial.first_position, initial.first.?, stroke, true);
        } else if (last) |final| try self.cap(final.last_position, final.previous.?, stroke, false);
    }
    pub fn build(self: *Edges, points: []const Point, contours: []const Contour) !void {
        // Flat already stored the transformed centerline. Width, caps, joins
        // and cuts now share that coordinate space. add() applies only the
        // explicit host output map and physical scale. No inverse, extra
        // vertex plane or per-edge mode branch.
        const transform = self.options.transform;
        if (transformedStroke(self.options)) self.options.transform = if (self.options.stroke_output) |output| output.* else .{};
        defer self.options.transform = transform;
        for (contours) |contour| {
            try self.options.check();
            const vertices = points[contour.start..][0..contour.len];
            if (vertices.len == 0) continue;
            switch (self.options.style) {
                .fill => for (vertices, 0..) |point, index| {
                    try self.add(point, vertices[(index + 1) % vertices.len]);
                },
                .stroke => |stroke| try self.strokeContour(vertices, contour.closed, stroke),
            }
        }
    }
};

fn transformedStroke(options: api.PrepareOptions) bool {
    return options.style == .stroke and options.style.stroke.space == .transformed;
}

const StrokeRun = struct {
    first: ?Point = null,
    previous: ?Point = null,
    first_position: Point,
    last_position: Point,
    fn segment(self: *StrokeRun, edges: *Edges, stroke: api.Stroke, a: Point, b: Point) !void {
        const delta = minus(b, a);
        const size = length(delta);
        if (size == 0) return;
        const direction = times(delta, 1 / size);
        if (self.first == null) {
            self.first = direction;
            self.first_position = a;
        }
        if (self.previous) |before| try edges.join(a, before, direction, stroke);
        const normal: Point = .{ .x = -direction.y * stroke.width / 2, .y = direction.x * stroke.width / 2 };
        try edges.polygon(&.{ plus(a, normal), minus(a, normal), minus(b, normal), plus(b, normal) });
        self.previous = direction;
        self.last_position = b;
    }
};

/// One forward scan shared by all monotonically ordered cut ranges. Each
/// original segment and each emitted fragment consumes an explicit work step.
const CutCursor = struct {
    points: []const Point,
    count: usize,
    index: usize = 0,
    start: f64 = 0,
    size: f64 = 0,
    ready: bool = false,
    fn load(self: *CutCursor, work: *intervals.Work) !void {
        if (self.ready or self.index >= self.count) return;
        try work.step();
        self.size = length(minus(self.points[(self.index + 1) % self.points.len], self.points[self.index]));
        self.ready = true;
    }
    fn advance(self: *CutCursor) void {
        self.start += self.size;
        self.index += 1;
        self.ready = false;
    }
    fn point(self: CutCursor, distance: f64) Point {
        if (self.index >= self.count) return self.points[if (self.count == self.points.len) 0 else self.points.len - 1];
        if (self.size == 0) return self.points[self.index];
        const a = self.points[self.index];
        const b = self.points[(self.index + 1) % self.points.len];
        if (distance <= self.start) return a;
        if (distance >= self.start + self.size) return b;
        return plus(a, times(minus(b, a), (distance - self.start) / self.size));
    }
    fn tangent(self: CutCursor) Point {
        if (self.index >= self.count or self.size == 0) return .{ .x = 1 };
        return times(minus(self.points[(self.index + 1) % self.points.len], self.points[self.index]), 1 / self.size);
    }
    fn emit(self: *CutCursor, edges: *Edges, stroke: api.Stroke, range: intervals.Range, work: *intervals.Work) !StrokeRun {
        try work.step();
        try self.load(work);
        while (self.index < self.count and (self.size == 0 or range.start >= self.start + self.size)) {
            // Retain the last real segment's tangent for a dot at the end.
            if (self.index + 1 == self.count and self.size != 0) break;
            self.advance();
            try self.load(work);
        }
        const begin = self.point(range.start);
        var run: StrokeRun = .{ .first_position = begin, .last_position = begin };
        var position = range.start;
        while (position < range.end and self.index < self.count) {
            try work.step();
            const end = @min(range.end, self.start + self.size);
            if (end > position) try run.segment(edges, stroke, self.point(position), self.point(end));
            position = end;
            if (position == range.end) break;
            self.advance();
            try self.load(work);
        }
        return run;
    }
};
