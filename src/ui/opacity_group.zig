//! Whether an opacity scope paints as one group.
//!
//! `Frame.pushOpacity` fades a subtree as one group, as CSS's group
//! opacity: what it holds composes first and the result fades once, so
//! that children overlapping one another, or their container's own
//! background, show as one, not each through the others. A group layer
//! costs a pass of the renderer, so a scope records flat, its opacity
//! applied to each drawing (`Command.push_opacity`), and `decide` looks at
//! what it recorded when it closes: when two of its drawings overlap within
//! the clips, the scope becomes a group (`begin_group` at the opacity over
//! the area they cover). Drawings that overlap nothing look the same either
//! way. Backdrops keep a scope flat, as no layer shows what lies behind it.

const std = @import("std");
const commands = @import("commands.zig");
const layout = @import("layout.zig");
const layers = @import("layers.zig");
const Rect = layout.Rect;
const Command = commands.Command;

/// Drawings checked pairwise; more of them count as overlapping.
pub const max_drawings = 32;
/// Clips a scope follows inside it; deeper ones cut nothing more.
const max_clips = 8;
/// DIP a group's area grows past what it holds, for antialiased edges and
/// glyphs reaching out of their boxes.
pub const margin: f32 = 4;

/// The area the scope opened at `start` (a `push_opacity`) should compose
/// in, within `clip`, when what it recorded since overlaps; null when it
/// paints the same flat, holds a backdrop, or would nest groups deeper than
/// a renderer layers them.
pub fn decide(buffer: *const commands.Buffer, start: usize, clip: ?Rect) ?Rect {
    const list = buffer.storage[start + 1 .. buffer.len];
    var boxes: [max_drawings]Rect = undefined;
    var count: usize = 0;
    var over = false;
    var clips: [max_clips]?Rect = undefined;
    var current = clip;
    var depth: usize = 0;
    // Groups, effects and transforms inside: each is one drawing.
    var nesting: usize = 0;
    var deepest: usize = 0;
    var area: ?Rect = null;
    for (list) |command| {
        var box: ?Rect = null;
        switch (command) {
            .backdrop, .backdrop_shader => return null,
            .push_clip, .push_mask_clip => {
                const rect = if (command == .push_clip) command.push_clip else command.push_mask_clip.bounds;
                if (depth < max_clips) {
                    clips[depth] = current;
                    if (nesting == 0) current = if (current) |c| layout.intersect(c, rect) else rect;
                }
                depth += 1;
                continue;
            },
            .push_opacity => {
                if (depth < max_clips) clips[depth] = current;
                depth += 1;
                continue;
            },
            .pop_clip => {
                if (depth == 0) continue;
                depth -= 1;
                if (depth < max_clips) current = clips[depth];
                continue;
            },
            .begin_group => |value| {
                nesting += 1;
                deepest = @max(deepest, nesting);
                if (nesting == 1) box = value.bounds;
            },
            .effect => |slot| {
                nesting += 1;
                deepest = @max(deepest, nesting);
                if (nesting == 1) box = if (slot < buffer.shader_storage.len) buffer.shader_storage.entries[slot].captureBounds() else current;
            },
            .begin_transform => |slot| {
                nesting += 1;
                deepest = @max(deepest, nesting);
                if (nesting == 1) {
                    const resources = buffer.transformResources();
                    box = if (slot < resources.len) transformed(resources[slot]) else current;
                }
            },
            .end_group, .end_effect, .end_transform => {
                nesting -|= 1;
                continue;
            },
            else => {
                if (nesting != 0) continue;
                box = drawingRect(buffer, command) orelse current;
            },
        }
        // Unknown bounds reach as far as the clip.
        const unclipped = box orelse current orelse return null;
        const shown = if (current) |c| layout.intersect(unclipped, c) else unclipped;
        if (!(shown.width > 0 and shown.height > 0)) continue;
        area = if (area) |a| unite(a, shown) else shown;
        if (over) continue;
        if (count == max_drawings) {
            over = true;
            continue;
        }
        for (boxes[0..count]) |other| if (overlaps(other, shown)) {
            over = true;
            break;
        };
        boxes[count] = shown;
        count += 1;
    }
    if (!over) return null;
    if (buffer.group_depth + 1 + deepest > layers.max_depth) return null;
    const held = area orelse return null;
    const grown: Rect = .{ .x = held.x - margin, .y = held.y - margin, .width = held.width + 2 * margin, .height = held.height + 2 * margin };
    const result = if (clip) |c| layout.intersect(grown, c) else grown;
    if (!(result.width > 0 and result.height > 0)) return null;
    return result;
}

/// True when `a` and `b` share some area, not only an edge.
pub fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height;
}

fn unite(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.width, b.x + b.width);
    const y1 = @max(a.y + a.height, b.y + b.height);
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

/// Where a transform scope's source lands around it.
fn transformed(t: layers.NativeTransform) Rect {
    const corners = [4][2]f64{ .{ 0, 0 }, .{ t.source_width, 0 }, .{ 0, t.source_height }, .{ t.source_width, t.source_height } };
    var x0: f64 = std.math.inf(f64);
    var y0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    var y1: f64 = -std.math.inf(f64);
    for (corners) |p| {
        const x = t.xx * p[0] + t.xy * p[1] + t.x0;
        const y = t.yx * p[0] + t.yy * p[1] + t.y0;
        x0 = @min(x0, x);
        y0 = @min(y0, y);
        x1 = @max(x1, x);
        y1 = @max(y1, y);
    }
    return .{ .x = @floatCast(x0), .y = @floatCast(y0), .width = @floatCast(x1 - x0), .height = @floatCast(y1 - y0) };
}

/// The box a plain drawing covers, or null when unknown.
fn drawingRect(buffer: *const commands.Buffer, command: Command) ?Rect {
    return switch (command) {
        .fill => |value| value.bounds,
        .shape => |value| value.bounds,
        .gradient => |value| value.bounds,
        .text => |value| value.bounds,
        .image => |value| value.destination,
        .texture => |value| value.destination,
        .prepared_text => |value| rect: {
            const resources = buffer.preparedTextResources();
            if (value.resource >= resources.len) break :rect null;
            const c = resources[value.resource].coverage;
            if (!(c.scale > 0)) break :rect null;
            break :rect coverageRect(value.origin, c.origin_x, c.origin_y, c.width, c.height, c.scale);
        },
        .coverage => |value| rect: {
            const resources = buffer.coverageResources();
            if (value.resource >= resources.len) break :rect null;
            const c = resources[value.resource].coverage;
            if (!(c.scale > 0)) break :rect null;
            break :rect coverageRect(value.origin, c.origin_x, c.origin_y, c.width, c.height, c.scale);
        },
        .indicator => |slot| if (slot < buffer.indicator_len) buffer.indicator_storage[slot].bounds else null,
        else => null,
    };
}

fn coverageRect(origin: anytype, ox: i32, oy: i32, width: u32, height: u32, scale: f32) Rect {
    return .{ .x = origin.x + @as(f32, @floatFromInt(ox)) / scale, .y = origin.y + @as(f32, @floatFromInt(oy)) / scale, .width = @as(f32, @floatFromInt(width)) / scale, .height = @as(f32, @floatFromInt(height)) / scale };
}

test "overlapping drawings group, apart ones stay flat" {
    var buffer: commands.Buffer = .{};
    try buffer.pushOpacity(128);
    try buffer.fill(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, 0xff0000ff);
    try buffer.fill(.{ .x = 10, .y = 0, .width = 10, .height = 10 }, 0xff00ff00);
    try std.testing.expect(decide(&buffer, 0, null) == null);
    try buffer.fill(.{ .x = 5, .y = 5, .width = 10, .height = 10 }, 0xffff0000);
    const area = decide(&buffer, 0, .{ .x = 0, .y = 0, .width = 100, .height = 100 }).?;
    try std.testing.expectEqual(@as(f32, 0), area.x);
    try std.testing.expectEqual(@as(f32, 24), area.width);
    // Clipped apart, they no longer overlap.
    var clipped: commands.Buffer = .{};
    try clipped.pushOpacity(128);
    try clipped.fill(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, 0xff0000ff);
    try clipped.pushClip(.{ .x = 12, .y = 0, .width = 10, .height = 10 });
    try clipped.fill(.{ .x = 5, .y = 0, .width = 10, .height = 10 }, 0xff00ff00);
    try clipped.popClip();
    try std.testing.expect(decide(&clipped, 0, null) == null);
}

test "an overlapping scope closes as a group at its opacity" {
    var buffer: commands.Buffer = .{};
    try buffer.pushOpacity(100);
    try buffer.fill(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, 0xff0000ff);
    try buffer.fill(.{ .x = 4, .y = 4, .width = 8, .height = 8 }, 0xff00ff00);
    const area = decide(&buffer, 0, null).?;
    try buffer.closeOpacityAsGroup(0, area);
    try std.testing.expectEqual(@as(u8, 100), buffer.storage[0].begin_group.opacity);
    try std.testing.expect(buffer.storage[buffer.len - 1] == .end_group);
    try std.testing.expectEqual(@as(usize, 0), buffer.depth);
    try std.testing.expectEqual(@as(usize, 0), buffer.group_depth);
}
