const std = @import("std");
const v = @import("ziggurat_vector");
const pre = @import("prepare.zig");
const d = @import("document.zig");
const n = @import("numbers.zig");
const styles = @import("style.zig");
const topology_stream = @import("marker_topology.zig");

pub fn enabled(style: styles.Style) bool {
    return style.marker_start != null or style.marker_end != null or style.marker_mid != null;
}
fn absolute(node: d.Node, key: []const u8, fallback: f64) !f64 {
    const value = try n.length(node.attribute(key) orelse return fallback);
    if (value.percent) return error.UnsupportedMarkerPercentage;
    return value.value;
}
const Orientation = union(enum) { auto, reverse, angle: f64 };
fn orientation(node: d.Node) !Orientation {
    const value = std.mem.trim(u8, node.attribute("orient") orelse "0", " \t\r\n");
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "auto-start-reverse")) return .reverse;
    var scan: n.Scanner = .{ .input = value };
    const amount = try scan.number();
    const unit = value[scan.at..];
    const period: f64 = if (unit.len == 0 or std.mem.eql(u8, unit, "deg")) 360 else if (std.mem.eql(u8, unit, "rad")) 2 * std.math.pi else if (std.mem.eql(u8, unit, "grad")) 400 else if (std.mem.eql(u8, unit, "turn")) 1 else return error.UnsupportedMarkerOrientation;
    return .{ .angle = @mod(amount, period) * (2 * std.math.pi / period) };
}
fn strokeUnits(node: d.Node) !bool {
    const value = node.attribute("markerUnits") orelse "strokeWidth";
    if (std.mem.eql(u8, value, "userSpaceOnUse")) return false;
    if (std.mem.eql(u8, value, "strokeWidth")) return true;
    return error.UnsupportedMarkerUnits;
}
pub fn validateNode(node: d.Node) !void {
    _ = try strokeUnits(node);
    if (node.attribute("transform") != null) return error.UnsupportedMarkerTransform;
    if (try absolute(node, "markerWidth", 3) < 0 or try absolute(node, "markerHeight", 3) < 0) return error.InvalidMarkerSize;
    _ = try absolute(node, "refX", 0);
    _ = try absolute(node, "refY", 0);
    _ = try orientation(node);
}
fn validateChildren(work: *pre.Work, index: usize, parent: styles.Style) anyerror!void {
    var child = work.document.nodes[index].first_child;
    while (child) |at| {
        try work.visit();
        const node = work.document.nodes[at];
        child = node.next_sibling;
        if (node.kind == .text) {
            if (std.mem.trim(u8, node.text, " \t\r\n").len != 0) return error.UnsupportedMarkerContent;
            continue;
        }
        const name = try pre.localName(work.document.nodes, at);
        if (pre.oneOf(name, &.{ "title", "desc", "metadata" })) continue;
        if (!pre.oneOf(name, &.{ "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon" })) return error.UnsupportedMarkerContent;
        try work.parse_work.node(node);
        const style = try work.sheet.?.derive(parent, node, name, &work.style_work);
        if (enabled(style) or style.fill == .reference or style.stroke == .reference or style.clip_path != null or style.mask != null or style.vector_effect != .none) return error.UnsupportedMarkerContent;
        try validateChildren(work, at, style);
    }
}
pub fn resolve(work: *pre.Work, id: ?[]const u8) !?usize {
    const key = id orelse return null;
    try work.style_work.charge(key.len * (1 + std.math.log2_int_ceil(usize, @max(@as(usize, 1), work.document.nodes.len))));
    const index = work.references.?.find(key) orelse return null;
    if (!std.mem.eql(u8, try pre.localName(work.document.nodes, index), "marker")) return null;
    return index;
}
// Borrowed preparation-only role stream. The common single-segment route
// retains its original arithmetic and work. Complex arity/subpaths use one
// shared authority in both compositing backends, before any marker instance.
pub const StreamInspection = topology_stream.Inspection;
pub const RoleCursor = topology_stream.Cursor;
pub fn streamInspection(work: *pre.Work, path: *const v.Path, name: []const u8) !?StreamInspection {
    if (!pre.oneOf(name, &.{ "path", "line", "polyline", "polygon" })) return null;
    const commands = path.commands;
    if (commands.len == 2 and commands[0] == .move) switch (commands[1]) {
        .line, .quadratic, .cubic => return null,
        .arc => |arc| if (!omittedArc(commands[0].move, arc)) return null,
        else => {},
    };
    const inspection = try topology_stream.inspect(work, commands);
    return if (inspection.legacy) null else inspection;
}
pub fn validateStream(work: *pre.Work, path: *const v.Path) !void {
    try topology_stream.validate(work, path.commands);
}
pub const Endpoints = struct { start: v.Point, end: v.Point, start_angle: f64, end_angle: f64 };
pub const MidStrategy = enum { ordinary, zero_lines, zero_polynomials, omitted };
pub const OpenTopology = struct { ends: Endpoints, mids: MidStrategy = .ordinary };
fn vector(from: v.Point, to: v.Point) ?v.Point {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    if (dx == 0 and dy == 0) return null;
    return .{ .x = dx, .y = dy };
}
fn endPoint(command: v.Command) !v.Point {
    return switch (command) {
        .line => |point| point,
        .quadratic => |q| q.end,
        .cubic => |q| q.end,
        .arc => |arc| arc.end,
        else => error.UnsupportedMarkerGeometry,
    };
}
inline fn polynomialOutgoing(start: v.Point, command: v.Command) !?v.Point {
    return topology_stream.polynomialOutgoing(start, command);
}
inline fn polynomialIncoming(start: v.Point, command: v.Command) !?v.Point {
    return topology_stream.polynomialIncoming(start, command);
}
fn outgoing(start: v.Point, command: v.Command) !v.Point {
    return (try polynomialOutgoing(start, command)) orelse error.UnsupportedMarkerGeometry;
}
fn incoming(start: v.Point, command: v.Command) !v.Point {
    return (try polynomialIncoming(start, command)) orelse error.UnsupportedMarkerGeometry;
}
fn directedPolynomial(start: v.Point, command: v.Command, first: v.Point) !Endpoints {
    const last = if (command == .line) first else try incoming(start, command);
    const angle = std.math.atan2(first.y, first.x);
    return .{ .start = start, .end = try endPoint(command), .start_angle = angle, .end_angle = if (command == .line) angle else std.math.atan2(last.y, last.x) };
}
fn singleBezier(work: *pre.Work, start: v.Point, command: v.Command) !OpenTopology {
    try work.visit();
    const first = (try polynomialOutgoing(start, command)) orelse return .{ .ends = .{ .start = start, .end = try endPoint(command), .start_angle = 0, .end_angle = 0 }, .mids = .zero_polynomials };
    return .{ .ends = try directedPolynomial(start, command, first) };
}
fn singleArc(work: *pre.Work, start: v.Point, arc: v.Arc) !Endpoints {
    try work.visit();
    return arcEndpoints(start, arc);
}
fn arcDirections(start: v.Point, arc: v.Arc) !v.Arc.Directions {
    return (try arc.endpointDirections(start)) orelse error.UnsupportedMarkerGeometry;
}
fn arcEndpoints(start: v.Point, arc: v.Arc) !Endpoints {
    const directions = try arcDirections(start, arc);
    return .{
        .start = start,
        .end = arc.end,
        .start_angle = std.math.atan2(directions.outgoing.y, directions.outgoing.x),
        .end_angle = std.math.atan2(directions.incoming.y, directions.incoming.x),
    };
}
fn mixedEndpoints(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, prefix_first: f64, prefix_last: f64) !OpenTopology {
    var pen = prefix_pen;
    var first = prefix_first;
    var last = prefix_last;
    var arc_seen = false;
    for (path.commands[at..], 0..) |command, offset| {
        // The first curve visit was charged by the original M/L scan. Its
        // validated prefix is not rescanned or charged again.
        if (offset != 0) try work.visit();
        const value = if (command == .arc) blk: {
            if (omittedArc(pen, command.arc)) return omittedEndpoints(work, path, at + offset, pen, first, last, at + offset > 1);
            arc_seen = true;
            break :blk try arcEndpoints(pen, command.arc);
        } else blk: {
            const first_vector = (try polynomialOutgoing(pen, command)) orelse {
                if (arc_seen) return zeroArcEndpoints(work, path, at + offset, pen, first, last, true);
                return zeroPolynomialEndpoints(work, path, at + offset, pen, first, last, at + offset > 1);
            };
            break :blk try directedPolynomial(pen, command, first_vector);
        };
        if (at == 1 and offset == 0) first = value.start_angle;
        last = value.end_angle;
        pen = value.end;
    }
    return .{ .ends = .{ .start = path.commands[0].move, .end = pen, .start_angle = first, .end_angle = last } };
}
const PolynomialLimits = struct { outgoing: v.Point, incoming: v.Point };
fn polynomialLimits(start: v.Point, command: v.Command) !?PolynomialLimits {
    const first = (try polynomialOutgoing(start, command)) orelse return null;
    return .{ .outgoing = first, .incoming = if (command == .line) first else (try polynomialIncoming(start, command)).? };
}
fn retainedLimits(start: v.Point, command: v.Command) !?PolynomialLimits {
    if (command == .arc) {
        // An omitted A is not a retained zero segment or marker vertex.
        const directions = try arcDirections(start, command.arc);
        return .{ .outgoing = directions.outgoing, .incoming = directions.incoming };
    }
    return polynomialLimits(start, command);
}
inline fn omittedArc(start: v.Point, arc: v.Arc) bool {
    // Only routes into the cold path. That path still validates this first A
    // through endpointDirections before accepting or rejecting its topology.
    return start.x == arc.end.x and start.y == arc.end.y;
}
fn omissionLimits(start: v.Point, command: v.Command) !?PolynomialLimits {
    if (command == .arc) {
        const directions = (try command.arc.endpointDirections(start)) orelse return null;
        return .{ .outgoing = directions.outgoing, .incoming = directions.incoming };
    }
    return polynomialLimits(start, command);
}
noinline fn omittedEndpoints(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, prefix_first: f64, prefix_last: f64, prefix_nonzero: bool) !OpenTopology {
    var pen = prefix_pen;
    var first = prefix_first;
    var last = prefix_last;
    var nonzero = prefix_nonzero;
    var retained = at - 1;
    for (path.commands[at..], 0..) |command, offset| {
        // No prior omission exists. The complete prefix and first visit were
        // already paid; even the first omitted A receives its public validation.
        if (offset != 0) try work.visit();
        const limits = try omissionLimits(pen, command);
        if (command != .arc or limits != null) retained += 1;
        if (limits) |value| {
            last = std.math.atan2(value.incoming.y, value.incoming.x);
            if (!nonzero) first = std.math.atan2(value.outgoing.y, value.outgoing.x);
            nonzero = true;
        }
        pen = try endPoint(command);
    }
    // K>=2 preserves the existing actual-mid lookup contract. One-retained,
    // all-omitted and M-only topology need their own arity/lookup design.
    if (retained < 2) return error.UnsupportedMarkerGeometry;
    return .{ .ends = .{ .start = path.commands[0].move, .end = pen, .start_angle = first, .end_angle = last }, .mids = .omitted };
}
noinline fn zeroArcEndpoints(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, prefix_first: f64, prefix_last: f64, prefix_nonzero: bool) !OpenTopology {
    var pen = prefix_pen;
    var first = prefix_first;
    var last = prefix_last;
    var nonzero = prefix_nonzero;
    for (path.commands[at..], 0..) |command, offset| {
        // Both handoffs preserve the validated prefix and already paid this
        // first command. Each remaining A is queried once in this preflight.
        if (offset != 0) try work.visit();
        if (command == .arc and omittedArc(pen, command.arc)) return omittedEndpoints(work, path, at + offset, pen, first, last, nonzero);
        if (try retainedLimits(pen, command)) |limits| {
            last = std.math.atan2(limits.incoming.y, limits.incoming.x);
            if (!nonzero) first = std.math.atan2(limits.outgoing.y, limits.outgoing.x);
            nonzero = true;
        }
        pen = try endPoint(command);
    }
    return .{ .ends = .{ .start = path.commands[0].move, .end = pen, .start_angle = first, .end_angle = last }, .mids = .zero_polynomials };
}
fn zeroPolynomialEndpoints(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, prefix_first: f64, prefix_last: f64, prefix_nonzero: bool) !OpenTopology {
    var pen = prefix_pen;
    var first = prefix_first;
    var last = prefix_last;
    var nonzero = prefix_nonzero;
    for (path.commands[at..], 0..) |command, offset| {
        // The transition command was already visited;resume,not restart.
        if (offset != 0) try work.visit();
        if (command == .arc) return zeroArcEndpoints(work, path, at + offset, pen, first, last, nonzero);
        if (try polynomialLimits(pen, command)) |limits| {
            last = std.math.atan2(limits.incoming.y, limits.incoming.x);
            if (!nonzero) first = std.math.atan2(limits.outgoing.y, limits.outgoing.x);
            nonzero = true;
        }
        pen = try endPoint(command);
    }
    return .{ .ends = .{ .start = path.commands[0].move, .end = pen, .start_angle = first, .end_angle = last }, .mids = .zero_polynomials };
}
fn zeroLineEndpoints(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, prefix_first: f64, prefix_last: f64) !OpenTopology {
    var pen = prefix_pen;
    var first = prefix_first;
    var last = prefix_last;
    var nonzero = at > 1;
    for (path.commands[at..], 0..) |command, offset| {
        // The first zero was already visited by the unchanged M/L scan.
        // Keep the old pure-line route until its first polynomial.
        if (offset != 0) try work.visit();
        if (command != .line) return zeroPolynomialEndpoints(work, path, at + offset, pen, first, last, nonzero);
        const point = command.line;
        if (vector(pen, point)) |direction| {
            last = std.math.atan2(direction.y, direction.x);
            if (!nonzero) first = last;
            nonzero = true;
        }
        pen = point;
    }
    // Leading/trailing zeros inherit the first/last real line. Entirely zero
    // paths retain both endpoints with the specified local positive-x limit.
    return .{ .ends = .{ .start = path.commands[0].move, .end = pen, .start_angle = first, .end_angle = last }, .mids = .zero_lines };
}
pub fn endpoints(work: *pre.Work, path: *const v.Path, name: []const u8) !?OpenTopology {
    if (!pre.oneOf(name, &.{ "path", "line", "polyline" })) return error.UnsupportedMarkerTarget;
    if (path.commands.len == 0) return null;
    if (path.commands.len < 2 or path.commands[0] != .move) return error.UnsupportedMarkerGeometry;
    const start = path.commands[0].move;
    if (path.commands.len == 2) switch (path.commands[1]) {
        .quadratic, .cubic => return try singleBezier(work, start, path.commands[1]),
        .arc => |arc| return .{ .ends = try singleArc(work, start, arc) },
        else => {},
    };
    var pen = start;
    var first: f64 = 0;
    var last: f64 = 0;
    for (path.commands[1..], 0..) |command, at| {
        // Derived command visits share the preparation's finite traversal work.
        try work.visit();
        if (command != .line) return switch (command) {
            .quadratic, .cubic, .arc => try mixedEndpoints(work, path, at + 1, pen, first, last),
            else => error.UnsupportedMarkerGeometry,
        };
        const point = command.line;
        const dx = point.x - pen.x;
        const dy = point.y - pen.y;
        if (dx == 0 and dy == 0) return try zeroLineEndpoints(work, path, at + 1, pen, first, last);
        last = std.math.atan2(dy, dx);
        if (at == 0) first = last;
        pen = point;
    }
    return .{ .ends = .{ .start = start, .end = pen, .start_angle = first, .end_angle = last } };
}
pub const Plan = struct { frame: pre.Frame, clip_matrix: v.Transform, clip_box: pre.Box };
pub const Middle = struct { point: v.Point, direction: ?f64 };
pub const ClosedTopology = struct { seam: Middle, mids: MidStrategy = .ordinary };
pub fn closedTarget(path: *const v.Path, name: []const u8) bool {
    return pre.oneOf(name, &.{ "path", "polygon" }) and path.commands.len != 0 and path.commands[path.commands.len - 1] == .close;
}
fn closedCurves(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, need_seam: bool) !ClosedTopology {
    const first = path.commands[0].move;
    var pen = prefix_pen;
    for (path.commands[at .. path.commands.len - 1], 0..) |command, offset| {
        // Resume after the already validated M/L prefix;the first curve's
        // visit was charged there. A nonzero outgoing limit proves that this
        // polynomial is not constant,even when its endpoints coincide.
        if (offset != 0) try work.visit();
        if (command == .arc) return closedArcs(work, path, at + offset, pen, need_seam);
        _ = (try polynomialOutgoing(pen, command)) orelse {
            const index = at + offset;
            var first_direction: v.Point = .{ .x = 1, .y = 0 };
            var last_direction = first_direction;
            if (index > 1) {
                // This prefix contains only nonconstant L/Q/C. Recover its
                // two anchors at fixed original indices,never rescan it.
                first_direction = (try polynomialOutgoing(first, path.commands[1])).?;
                const previous = if (index == 2) first else try endPoint(path.commands[index - 2]);
                last_direction = (try polynomialIncoming(previous, path.commands[index - 1])).?;
            }
            return closedZeroPolynomials(work, path, index, pen, first_direction, last_direction, index > 1, need_seam);
        };
        pen = try endPoint(command);
    }
    try work.visit();
    const closing = vector(pen, first);
    if (!need_seam) return .{ .seam = .{ .point = first, .direction = null } };
    try work.visit();
    const next = try outgoing(first, path.commands[1]);
    // A zero terminal Z has no later segment in the linear source sequence;
    // both its limits inherit the last real incoming. Closed marker adjacency
    // then combines that limit with the first outgoing at the shared seam.
    const left = closing orelse blk: {
        const last = path.commands.len - 2;
        const previous = if (last == 1) first else try endPoint(path.commands[last - 1]);
        break :blk try incoming(previous, path.commands[last]);
    };
    return .{ .seam = .{ .point = first, .direction = bisector(left.x, left.y, next.x, next.y) } };
}
fn closedArcs(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, need_seam: bool) !ClosedTopology {
    const first = path.commands[0].move;
    var pen = prefix_pen;
    var first_outgoing: v.Point = undefined;
    var last_incoming: v.Point = undefined;
    for (path.commands[at .. path.commands.len - 1], 0..) |command, offset| {
        // The caller already visited the first A. Previously validated L/Q/C
        // commands are never rescanned. Preserve a first A's seam input from
        // this same query rather than resolving it again after the scan.
        if (offset != 0) try work.visit();
        if (command == .arc) {
            const directions = try arcDirections(pen, command.arc);
            if (at == 1 and offset == 0) first_outgoing = directions.outgoing;
            // A following constant may need this incoming as its prefix
            // anchor. Retain the same query also for the terminal zero Z.
            last_incoming = directions.incoming;
        } else _ = (try polynomialOutgoing(pen, command)) orelse {
            const index = at + offset;
            // The prefix is fully validated and nonconstant. Recover only
            // polynomial neighbors;every prior A uses its saved query.
            const next = if (at == 1) first_outgoing else (try polynomialOutgoing(first, path.commands[1])).?;
            const left = if (path.commands[index - 1] == .arc) last_incoming else blk: {
                const previous = if (index == 2) first else try endPoint(path.commands[index - 2]);
                break :blk (try polynomialIncoming(previous, path.commands[index - 1])).?;
            };
            return closedZeroArcs(work, path, index, pen, next, left, true, need_seam);
        };
        pen = try endPoint(command);
    }
    try work.visit();
    const closing = vector(pen, first);
    if (!need_seam) return .{ .seam = .{ .point = first, .direction = null } };
    try work.visit();
    const next = if (at == 1) first_outgoing else try outgoing(first, path.commands[1]);
    const left = closing orelse blk: {
        const last = path.commands.len - 2;
        if (path.commands[last] == .arc) break :blk last_incoming;
        const previous = if (last == 1) first else try endPoint(path.commands[last - 1]);
        break :blk try incoming(previous, path.commands[last]);
    };
    return .{ .seam = .{ .point = first, .direction = bisector(left.x, left.y, next.x, next.y) } };
}
fn closedZeroLines(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, need_seam: bool) !ClosedTopology {
    const first = path.commands[0].move;
    var pen = prefix_pen;
    var first_direction: v.Point = .{ .x = 1, .y = 0 };
    var last_direction = first_direction;
    var has_nonzero = at > 1;
    if (has_nonzero) {
        // The first zero ended a fully validated nonzero M/L prefix. Read
        // its two anchors by fixed source indices,never rescan that prefix.
        first_direction = vector(first, path.commands[1].line).?;
        const previous = if (at == 2) first else path.commands[at - 2].line;
        last_direction = vector(previous, prefix_pen).?;
    }
    for (path.commands[at .. path.commands.len - 1], 0..) |command, offset| {
        if (offset != 0) try work.visit();
        if (command != .line) return closedZeroPolynomials(work, path, at + offset, pen, first_direction, last_direction, has_nonzero, need_seam);
        if (vector(pen, command.line)) |direction| {
            if (!has_nonzero) first_direction = direction;
            last_direction = direction;
            has_nonzero = true;
        }
        pen = command.line;
    }
    try work.visit();
    // Z is the last segment in the linear sequence,not a cyclic lookup.
    // A nonzero Z supplies a later anchor for trailing zero Ls. A zero Z
    // inherits the last real direction,or+x when the entire path is zero.
    if (vector(pen, first)) |closing| {
        if (!has_nonzero) first_direction = closing;
        last_direction = closing;
    }
    if (!need_seam) return .{ .seam = .{ .point = first, .direction = null }, .mids = .zero_lines };
    try work.visit();
    return .{ .seam = .{ .point = first, .direction = bisector(last_direction.x, last_direction.y, first_direction.x, first_direction.y) }, .mids = .zero_lines };
}
fn closedZeroPolynomials(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, prefix_first: v.Point, prefix_last: v.Point, prefix_nonzero: bool, need_seam: bool) !ClosedTopology {
    const first = path.commands[0].move;
    var pen = prefix_pen;
    var first_direction = prefix_first;
    var last_direction = prefix_last;
    var has_nonzero = prefix_nonzero;
    for (path.commands[at .. path.commands.len - 1], 0..) |command, offset| {
        // The transition command was already visited by the nonzero or
        // pure-line route. Preserve this no-A route until its first A.
        if (offset != 0) try work.visit();
        if (command == .arc) return closedZeroArcs(work, path, at + offset, pen, first_direction, last_direction, has_nonzero, need_seam);
        if (try polynomialLimits(pen, command)) |limits| {
            if (!has_nonzero) first_direction = limits.outgoing;
            last_direction = limits.incoming;
            has_nonzero = true;
        }
        pen = try endPoint(command);
    }
    try work.visit();
    // Include the real terminal Z in the linear sequence before applying
    // closed adjacency. Its nonzero chord anchors preceding constant runs;
    // a zero Z inherits the last incoming,or+x for an entirely zero path.
    if (vector(pen, first)) |closing| {
        if (!has_nonzero) first_direction = closing;
        last_direction = closing;
    }
    if (!need_seam) return .{ .seam = .{ .point = first, .direction = null }, .mids = .zero_polynomials };
    try work.visit();
    return .{ .seam = .{ .point = first, .direction = bisector(last_direction.x, last_direction.y, first_direction.x, first_direction.y) }, .mids = .zero_polynomials };
}
noinline fn closedZeroArcs(work: *pre.Work, path: *const v.Path, at: usize, prefix_pen: v.Point, prefix_first: v.Point, prefix_last: v.Point, prefix_nonzero: bool, need_seam: bool) !ClosedTopology {
    const first = path.commands[0].move;
    var pen = prefix_pen;
    var first_direction = prefix_first;
    var last_direction = prefix_last;
    var has_nonzero = prefix_nonzero;
    for (path.commands[at .. path.commands.len - 1], 0..) |command, offset| {
        // Both callers paid this first visit and transfer their complete
        // prefix anchors. Every remaining A is queried only once here.
        if (offset != 0) try work.visit();
        if (try retainedLimits(pen, command)) |limits| {
            if (!has_nonzero) first_direction = limits.outgoing;
            last_direction = limits.incoming;
            has_nonzero = true;
        }
        pen = try endPoint(command);
    }
    try work.visit();
    // Z remains the last linear segment. Its real chord anchors trailing
    // constants;zero Z inherits last incoming before closed adjacency.
    if (vector(pen, first)) |closing| {
        if (!has_nonzero) first_direction = closing;
        last_direction = closing;
    }
    if (!need_seam) return .{ .seam = .{ .point = first, .direction = null }, .mids = .zero_polynomials };
    try work.visit();
    return .{ .seam = .{ .point = first, .direction = bisector(last_direction.x, last_direction.y, first_direction.x, first_direction.y) }, .mids = .zero_polynomials };
}
/// One terminal Z. Nullable L/Q/C/A limits use a separate cold topology;the
/// old nonzero line/curve route retains its direction equations/work.
pub fn closed(work: *pre.Work, path: *const v.Path, need_seam: bool) !ClosedTopology {
    if (path.commands.len < 3 or path.commands[0] != .move or path.commands[path.commands.len - 1] != .close) return error.UnsupportedMarkerGeometry;
    const first = path.commands[0].move;
    var pen = first;
    for (path.commands[1 .. path.commands.len - 1], 1..) |command, at| {
        try work.visit();
        if (command != .line) return switch (command) {
            .quadratic, .cubic => try closedCurves(work, path, at, pen, need_seam),
            .arc => try closedArcs(work, path, at, pen, need_seam),
            else => error.UnsupportedMarkerGeometry,
        };
        const point = command.line;
        if (point.x == pen.x and point.y == pen.y) return closedZeroLines(work, path, at, pen, need_seam);
        pen = point;
    }
    try work.visit();
    if (!need_seam) return .{ .seam = .{ .point = first, .direction = null } };
    // The one seam calculation is shared by start/end. Do not calculate an
    // unused seam, nor reject its direction when only interior markers exist.
    try work.visit();
    if (pen.x == first.x and pen.y == first.y) {
        // Every L was validated nonzero,so zero Z implies at least two Ls.
        const left = vector(path.commands[path.commands.len - 3].line, pen).?;
        const right = vector(first, path.commands[1].line).?;
        return .{ .seam = .{ .point = first, .direction = bisector(left.x, left.y, right.x, right.y) } };
    }
    return .{ .seam = between(pen, first, path.commands[1].line) };
}
pub fn closedMiddle(work: *pre.Work, path: *const v.Path, at: usize) !Middle {
    std.debug.assert(at > 0 and at + 1 < path.commands.len);
    try work.visit();
    const terminal = at + 2 == path.commands.len;
    if (path.commands[at] != .line or (at != 1 and path.commands[at - 1] != .line) or (!terminal and path.commands[at + 1] != .line)) {
        const previous = if (at == 1) path.commands[0].move else try endPoint(path.commands[at - 1]);
        const point = try endPoint(path.commands[at]);
        const left = try incoming(previous, path.commands[at]);
        const right = if (terminal) vector(point, path.commands[0].move) orelse left else try outgoing(point, path.commands[at + 1]);
        return .{ .point = point, .direction = bisector(left.x, left.y, right.x, right.y) };
    }
    const previous = if (at == 1) path.commands[0].move else path.commands[at - 1].line;
    const next = if (at + 2 == path.commands.len) path.commands[0].move else path.commands[at + 1].line;
    if (terminal and path.commands[at].line.x == next.x and path.commands[at].line.y == next.y) {
        const left = vector(previous, next).?;
        return .{ .point = next, .direction = std.math.atan2(left.y, left.x) };
    }
    return between(previous, path.commands[at].line, next);
}
/// Only call after endpoints has validated the complete original open path.
/// No vertex array is allocated and no flattened/stroked edge is inspected.
pub fn middle(work: *pre.Work, path: *const v.Path, at: usize) !Middle {
    std.debug.assert(at > 0 and at + 1 < path.commands.len);
    try work.visit();
    if (path.commands[at] != .line or path.commands[at + 1] != .line or (at != 1 and path.commands[at - 1] != .line)) {
        const previous = if (at == 1) path.commands[0].move else try endPoint(path.commands[at - 1]);
        const point = try endPoint(path.commands[at]);
        const left = try incoming(previous, path.commands[at]);
        const right = try outgoing(point, path.commands[at + 1]);
        return .{ .point = point, .direction = bisector(left.x, left.y, right.x, right.y) };
    }
    const previous = if (at == 1) path.commands[0].move else path.commands[at - 1].line;
    const point = path.commands[at].line;
    const next = path.commands[at + 1].line;
    return between(previous, point, next);
}
/// Forward-only open mids, after complete endpoints validation. The right
/// arc's incoming limit is reused at the following boundary; no vertex or
/// direction array is retained. Path is borrowed only for each next call.
pub const MidCursor = struct {
    at: usize = 1,
    arc_incoming: ?v.Point = null,
    pub fn next(self: *MidCursor, work: *pre.Work, path: *const v.Path) !?Middle {
        if (self.at + 1 >= path.commands.len) return null;
        const at = self.at;
        self.at += 1;
        const current = path.commands[at];
        const following = path.commands[at + 1];
        if (current != .arc and following != .arc) {
            self.arc_incoming = null;
            // The unchanged legacy helper owns this mid's one visit.
            return try middle(work, path, at);
        }
        try work.visit();
        const previous = if (at == 1) path.commands[0].move else try endPoint(path.commands[at - 1]);
        const point = try endPoint(current);
        const left = if (current == .arc)
            self.arc_incoming orelse (try arcDirections(previous, current.arc)).incoming
        else
            try incoming(previous, current);
        const right = if (following == .arc) blk: {
            const directions = try arcDirections(point, following.arc);
            self.arc_incoming = directions.incoming;
            break :blk directions.outgoing;
        } else blk: {
            self.arc_incoming = null;
            break :blk try outgoing(point, following);
        };
        return .{ .point = point, .direction = bisector(left.x, left.y, right.x, right.y) };
    }
    /// Closed preflight validated every non-Z segment as nonzero. At the last
    /// listed vertex,Z is its own closing line,or inherits this incoming when
    /// zero;never use the first segment's outgoing as the terminal mid limit.
    pub fn nextClosed(self: *MidCursor, work: *pre.Work, path: *const v.Path) !?Middle {
        if (self.at + 1 >= path.commands.len) return null;
        const at = self.at;
        self.at += 1;
        const current = path.commands[at];
        const following = path.commands[at + 1];
        const terminal = at + 2 == path.commands.len;
        if (current != .arc and (terminal or following != .arc)) {
            self.arc_incoming = null;
            // This unchanged helper already charges the mid's one visit.
            return try closedMiddle(work, path, at);
        }
        try work.visit();
        const previous = if (at == 1) path.commands[0].move else try endPoint(path.commands[at - 1]);
        const point = try endPoint(current);
        const left = if (current == .arc)
            self.arc_incoming orelse (try arcDirections(previous, current.arc)).incoming
        else
            try incoming(previous, current);
        const right = if (terminal) blk: {
            self.arc_incoming = null;
            break :blk vector(point, path.commands[0].move) orelse left;
        } else if (following == .arc) blk: {
            const directions = try arcDirections(point, following.arc);
            self.arc_incoming = directions.incoming;
            break :blk directions.outgoing;
        } else blk: {
            self.arc_incoming = null;
            break :blk try outgoing(point, following);
        };
        return .{ .point = point, .direction = bisector(left.x, left.y, right.x, right.y) };
    }
};
/// Shared rolling anchors for fully validated pure-line topologies.
/// The closed specialization includes the real Z in the linear sequence.
fn LineCursor(comptime closed_path: bool) type {
    return struct {
        const Self = @This();
        const Anchor = struct { segment: usize, direction: v.Point };
        at: usize = 1,
        scanned: usize = 0,
        previous: ?Anchor = null,
        following: ?Anchor = null,
        fn scanNext(self: *Self, work: *pre.Work, path: *const v.Path) !?Anchor {
            while (self.scanned + 1 < path.commands.len) {
                // Classification is additional,cumulative work on this cold path.
                // Charge/check before reading each newly inspected original line.
                try work.visit();
                self.scanned += 1;
                const from = if (self.scanned == 1) path.commands[0].move else path.commands[self.scanned - 1].line;
                const to = if (closed_path and self.scanned + 1 == path.commands.len) path.commands[0].move else path.commands[self.scanned].line;
                if (vector(from, to)) |direction| return .{ .segment = self.scanned, .direction = direction };
            }
            return null;
        }
        pub fn next(self: *Self, work: *pre.Work, path: *const v.Path) !?Middle {
            if (self.at + 1 >= path.commands.len) return null;
            try work.visit();
            if (self.scanned == 0) {
                self.following = try self.scanNext(work, path);
                if (self.following) |anchor| if (anchor.segment == 1) {
                    self.previous = anchor;
                    self.following = try self.scanNext(work, path);
                };
            } else if (self.following) |anchor| if (anchor.segment == self.at) {
                self.previous = anchor;
                self.following = try self.scanNext(work, path);
            };
            const positive_x: v.Point = .{ .x = 1, .y = 0 };
            const before: ?v.Point = if (self.previous) |anchor| anchor.direction else null;
            const after: ?v.Point = if (self.following) |anchor| anchor.direction else null;
            const left = if (self.previous != null and self.previous.?.segment == self.at)
                self.previous.?.direction
            else
                after orelse before orelse positive_x;
            const right = if (self.following != null and self.following.?.segment == self.at + 1)
                self.following.?.direction
            else
                before orelse after orelse positive_x;
            const point = path.commands[self.at].line;
            self.at += 1;
            return .{ .point = point, .direction = bisector(left.x, left.y, right.x, right.y) };
        }
    };
}
pub const ZeroLineCursor = LineCursor(false);
pub const ClosedZeroLineCursor = LineCursor(true);
/// Only after complete nullable preflight. Both accept non-omitted A;the closed
/// specialization includes its original terminal Z separately. The future anchor
/// needs both limits;its outgoing serves the zero run,its incoming promotes
/// once. Closed specialization includes Z in the same linear scan.
fn PolynomialCursor(comptime closed_path: bool, comptime omission: bool) type {
    comptime std.debug.assert(!closed_path or !omission);
    return struct {
        const Self = @This();
        const Previous = struct { segment: usize, incoming: v.Point };
        const Following = struct { segment: usize, limits: PolynomialLimits };
        at: usize = if (omission) 0 else 1,
        scanned: usize = 0,
        previous: ?Previous = null,
        following: ?Following = null,
        fn scanNext(self: *Self, work: *pre.Work, path: *const v.Path) !?Following {
            while (self.scanned + 1 < path.commands.len) {
                try work.visit();
                self.scanned += 1;
                const start = if (self.scanned == 1) path.commands[0].move else try endPoint(path.commands[self.scanned - 1]);
                const limits = if (closed_path and self.scanned + 1 == path.commands.len) blk: {
                    const direction = vector(start, path.commands[0].move) orelse continue;
                    break :blk PolynomialLimits{ .outgoing = direction, .incoming = direction };
                } else (if (omission) try omissionLimits(start, path.commands[self.scanned]) else try retainedLimits(start, path.commands[self.scanned])) orelse continue;
                return .{ .segment = self.scanned, .limits = limits };
            }
            return null;
        }
        fn promote(self: *Self, anchor: Following) void {
            self.previous = .{ .segment = anchor.segment, .incoming = anchor.limits.incoming };
        }
        inline fn midDirection(self: *const Self, left_segment: usize, right_segment: usize) ?f64 {
            const positive_x: v.Point = .{ .x = 1, .y = 0 };
            const before: ?v.Point = if (self.previous) |anchor| anchor.incoming else null;
            const after: ?v.Point = if (self.following) |anchor| anchor.limits.outgoing else null;
            const left = if (self.previous != null and self.previous.?.segment == left_segment)
                self.previous.?.incoming
            else
                after orelse before orelse positive_x;
            const right = if (self.following != null and self.following.?.segment == right_segment)
                self.following.?.limits.outgoing
            else
                before orelse after orelse positive_x;
            return bisector(left.x, left.y, right.x, right.y);
        }
        fn nextRetained(work: *pre.Work, path: *const v.Path, after: usize) !?usize {
            var index = after;
            while (index + 1 < path.commands.len) {
                try work.visit();
                index += 1;
                const start = if (index == 1) path.commands[0].move else try endPoint(path.commands[index - 1]);
                const command = path.commands[index];
                // This role-only scan borrows the immutable fully validated
                // Path. Only the anchor pass queries arc directions again.
                if (command == .arc and omittedArc(start, command.arc)) continue;
                return index;
            }
            return null;
        }
        fn nextOmitted(self: *Self, work: *pre.Work, path: *const v.Path) !?Middle {
            if (self.at == path.commands.len) return null;
            if (self.at == 0) self.at = (try nextRetained(work, path, 0)) orelse unreachable;
            const left_segment = self.at;
            const right_segment = (try nextRetained(work, path, left_segment)) orelse {
                self.at = path.commands.len;
                return null;
            };
            try work.visit();
            if (self.scanned == 0) {
                self.following = try self.scanNext(work, path);
                if (self.following) |anchor| if (anchor.segment == left_segment) {
                    self.promote(anchor);
                    self.following = try self.scanNext(work, path);
                };
            } else if (self.following) |anchor| if (anchor.segment == left_segment) {
                self.promote(anchor);
                self.following = try self.scanNext(work, path);
            };
            const point = try endPoint(path.commands[left_segment]);
            const angle = self.midDirection(left_segment, right_segment);
            self.at = right_segment;
            return .{ .point = point, .direction = angle };
        }
        pub fn next(self: *Self, work: *pre.Work, path: *const v.Path) !?Middle {
            if (omission) return self.nextOmitted(work, path);
            if (self.at + 1 >= path.commands.len) return null;
            try work.visit();
            if (self.scanned == 0) {
                self.following = try self.scanNext(work, path);
                if (self.following) |anchor| if (anchor.segment == 1) {
                    self.promote(anchor);
                    self.following = try self.scanNext(work, path);
                };
            } else if (self.following) |anchor| if (anchor.segment == self.at) {
                self.promote(anchor);
                self.following = try self.scanNext(work, path);
            };
            const point = try endPoint(path.commands[self.at]);
            const angle = self.midDirection(self.at, self.at + 1);
            self.at += 1;
            return .{ .point = point, .direction = angle };
        }
    };
}
pub const ZeroPolynomialCursor = PolynomialCursor(false, false);
pub const ClosedZeroPolynomialCursor = PolynomialCursor(true, false);
pub const OmittedPolynomialCursor = PolynomialCursor(false, true);
fn between(previous: v.Point, point: v.Point, next: v.Point) Middle {
    const ax = point.x - previous.x;
    const ay = point.y - previous.y;
    const bx = next.x - point.x;
    const by = next.y - point.y;
    return .{ .point = point, .direction = bisector(ax, ay, bx, by) };
}
fn bisector(ax: f64, ay: f64, bx: f64, by: f64) ?f64 {
    return topology_stream.bisector(.{ .x = ax, .y = ay }, .{ .x = bx, .y = by });
}
pub fn plan(work: *pre.Work, index: usize, parent: pre.Frame, point: v.Point, direction: ?f64, start: bool) !?Plan {
    const node = work.document.nodes[index];
    try work.parse_work.node(node);
    try validateNode(node);
    const stroke_units = try strokeUnits(node);
    const scale: f64 = if (stroke_units) scaled: {
        const diagonal = std.math.hypot(parent.viewport.width, parent.viewport.height) / @sqrt(@as(f64, 2));
        break :scaled try parent.style.stroke_width.resolve(diagonal);
    } else 1;
    const style = try work.computed(index);
    if (!style.overflow_hidden or style.overflow_scrollable) return error.UnsupportedMarkerOverflow;
    if (style.opacity != 1 or style.clip_path != null or style.mask != null) return error.UnsupportedMarkerStyle;
    try validateChildren(work, index, style);
    const width = try absolute(node, "markerWidth", 3);
    const height = try absolute(node, "markerHeight", 3);
    if (width == 0 or height == 0 or scale == 0) return null;
    const box = try pre.viewport(node, width, height);
    if (box.width == 0 or box.height == 0) return null;
    const view = try pre.viewTransform(box, node, width, height);
    const reference = view.apply(.{ .x = try absolute(node, "refX", 0), .y = try absolute(node, "refY", 0) });
    const angle = switch (try orientation(node)) {
        .auto => direction orelse return error.UnsupportedMarkerDirection,
        .reverse => (direction orelse return error.UnsupportedMarkerDirection) + @as(f64, if (start) std.math.pi else 0),
        .angle => |angle| angle,
    };
    var result = parent;
    result.style = style;
    result.viewport = .{ .width = box.width, .height = box.height };
    if (stroke_units and parent.style.vector_effect != .none) {
        const host_pose = try @import("marker_space.zig").pose(parent.host_matrix orelse parent.matrix, point, angle, scale, reference);
        result.matrix = if (parent.host_matrix != null) host_pose.then(work.host_output) else host_pose;
        result.host_matrix = if (parent.host_matrix != null) host_pose else null;
    } else {
        const cosine = @cos(angle);
        const sine = @sin(angle);
        var offset: v.Transform = .{ .x0 = -reference.x, .y0 = -reference.y };
        if (scale != 1) offset = offset.then(.{ .xx = scale, .yy = scale });
        const pose = offset.then(.{ .xx = cosine, .yx = sine, .xy = -sine, .yy = cosine }).then(.{ .x0 = point.x, .y0 = point.y });
        result.prepend(pose);
    }
    const clip_matrix = result.matrix;
    try clip_matrix.validate();
    result.prepend(view);
    try result.matrix.validate();
    return .{ .frame = result, .clip_matrix = clip_matrix, .clip_box = .{ .width = width, .height = height } };
}
