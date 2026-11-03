//! Shared elements: a node whose `Style.match` names an identity that
//! another node showed in the frame before comes from there. It moves from
//! that one's box to its own, its content scaled on the way, and from that
//! one's look to its own: background, border and text colors, corners,
//! opacity and pose, each turn of the pose the short way round. With `fly`,
//! the other, still built as in a page going away, goes with it and fades
//! out over the second half while the one coming is opaque by half the
//! way, as a crossfade between the two.
//!
//! Matching runs once per frame, after layout and before paint, on the
//! arranged boxes: it moves what is drawn, not the layout, so hit testing,
//! focus and semantics keep the arranged box, as `Style.pose` does. Moving
//! the content needs `Host.prepareShaderEffects`; without it the element
//! appears in place.
const std = @import("std");
const ui = @import("ziggurat_ui");
const animation = @import("ziggurat_animation");

const Pose = ui.effects.Pose;
const Rect = ui.Rect;

pub const Match = struct {
    /// The identity the node shares with another, nonzero and the
    /// application's own, such as a photo's ID for its thumbnail and for
    /// the photo in its detail view. Give one node a key at a time, but the
    /// one going away while the other flies in.
    key: u64,
    motion: animation.Motion = .{ .tween = .{ .duration_ns = 300 * std.time.ns_per_ms, .easing = .cubic_out } },
    /// Crossfade with the other while it is still built.
    fly: bool = false,
};

/// The identities a View follows at once; more are shown in place.
pub const capacity = 32;

/// What a matched node looks like where it shows.
pub const Look = struct {
    bounds: Rect,
    pose: Pose = .{},
    opacity: f32 = 1,
    background: ?u32 = null,
    border: ?u32 = null,
    color: ?u32 = null,
    radius: f32 = 0,

    /// The look `t` of the way from `a` to `b`. Colors missing on one side
    /// take the other's, so a fill appears or goes at once.
    pub fn mix(a: Look, b: Look, t: f32) Look {
        return .{
            .bounds = .{ .x = lerp(a.bounds.x, b.bounds.x, t), .y = lerp(a.bounds.y, b.bounds.y, t), .width = lerp(a.bounds.width, b.bounds.width, t), .height = lerp(a.bounds.height, b.bounds.height, t) },
            .pose = mixPose(a.pose, b.pose, t),
            .opacity = lerp(a.opacity, b.opacity, t),
            .background = mixColor(a.background, b.background, t),
            .border = mixColor(a.border, b.border, t),
            .color = mixColor(a.color, b.color, t),
            .radius = lerp(a.radius, b.radius, t),
        };
    }
};

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
/// An angle `t` of the way from `a` to `b` degrees, turning the short way.
pub fn turn(a: f32, b: f32, t: f32) f32 {
    var delta = @mod(b - a, 360);
    if (delta > 180) delta -= 360;
    return b - delta * (1 - t);
}
/// `Pose.mix` with each rotation the short way round, so that a turn from
/// 350 to 10 degrees goes through 0 rather than back through 180.
pub fn mixPose(a: Pose, b: Pose, t: f32) Pose {
    var result = Pose.mix(a, b, t);
    result.rotate = turn(a.rotate, b.rotate, t);
    result.rotate_x = turn(a.rotate_x, b.rotate_x, t);
    result.rotate_y = turn(a.rotate_y, b.rotate_y, t);
    return result;
}
fn mixColor(a: ?u32, b: ?u32, t: f32) ?u32 {
    const from = a orelse return b;
    const to = b orelse return a;
    var result: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |shift| {
        const x: f32 = @floatFromInt((from >> shift) & 0xff);
        const y: f32 = @floatFromInt((to >> shift) & 0xff);
        const value: u32 = @intFromFloat(@round(std.math.clamp(lerp(x, y, t), 0, 255)));
        result |= value << shift;
    }
    return result;
}
/// The pose that draws a node arranged at `arranged` within `look.bounds`,
/// turned as `look.pose` turns it.
pub fn poseFor(arranged: Rect, look: Look) Pose {
    var pose = look.pose;
    const width = @max(arranged.width, 1e-3);
    const height = @max(arranged.height, 1e-3);
    // About the box's center: the pose's own origin is kept for its turns
    // only where the boxes agree, which is where flights end.
    pose.origin = .{ 0.5, 0.5 };
    pose.x += (look.bounds.x + look.bounds.width / 2) - (arranged.x + arranged.width / 2);
    pose.y += (look.bounds.y + look.bounds.height / 2) - (arranged.y + arranged.height / 2);
    pose.scale_x *= look.bounds.width / width;
    pose.scale_y *= look.bounds.height / height;
    return pose;
}

/// `left` is the node a flight to `id` came from, which, still built as a
/// page going away, never flies back.
const Shown = struct { key: u64, id: u64, look: Look, left: u64 = 0 };
const Flight = struct {
    key: u64,
    id: u64,
    /// The node it came from, while it is still built.
    other: u64,
    from: Look,
    fly: bool,
    channel: animation.Channel,
};

/// Kept by the View from frame to frame.
pub const State = struct {
    shown: [capacity]Shown = undefined,
    shown_len: usize = 0,
    flights: [capacity]Flight = undefined,
    flight_len: usize = 0,

    /// Whether a flight is on its way.
    pub fn moving(self: *const State) bool {
        return self.flight_len != 0;
    }
    fn previous(self: *const State, key: u64) ?Shown {
        for (self.shown[0..self.shown_len]) |entry| if (entry.key == key) return entry;
        return null;
    }
    fn flight(self: *State, key: u64) ?*Flight {
        for (self.flights[0..self.flight_len]) |*entry| if (entry.key == key) return entry;
        return null;
    }
    fn drop(self: *State, index: usize) void {
        self.flight_len -= 1;
        self.flights[index] = self.flights[self.flight_len];
    }

    /// Start, move and end the flights of the arranged `nodes` at `now`,
    /// rewriting the style of those on their way, and remember how each
    /// matched node shows for the next frame. Returns the next deadline a
    /// frame is due, if a flight is still on its way.
    pub fn apply(self: *State, nodes: anytype, now: u64, reduce_motion: bool) ?u64 {
        // Start a flight for each key a node newly shows: one another node
        // showed in the frame before.
        for (nodes) |*node| {
            const match = node.style.match orelse continue;
            if (match.key == 0 or node.style.hidden) continue;
            const before = self.previous(match.key) orelse continue;
            if (before.id == node.id or before.left == node.id) continue;
            // The one in flight, and the one it left, which goes with it.
            if (self.flight(match.key)) |current| if (current.id == node.id or current.other == node.id) continue;
            // The one that showed it in the frame before is going away;
            // under reduced motion the other is in place at once.
            if (reduce_motion) {
                if (self.flight(match.key)) |current| self.drop(current - &self.flights);
                continue;
            }
            var channel = animation.Channel.init(0) catch continue;
            channel.retarget(now, 1, .{ .motion = match.motion }) catch continue;
            const value: Flight = .{ .key = match.key, .id = node.id, .other = before.id, .from = before.look, .fly = match.fly, .channel = channel };
            if (self.flight(match.key)) |current| {
                current.* = value;
            } else if (self.flight_len < capacity) {
                self.flights[self.flight_len] = value;
                self.flight_len += 1;
            }
        }
        // Move each flight; one whose node is gone ends.
        var drawn: [2 * capacity]Shown = undefined;
        var drawn_len: usize = 0;
        var wake: ?u64 = null;
        var index: usize = 0;
        while (index < self.flight_len) {
            const current = &self.flights[index];
            const target = for (nodes) |*node| {
                if (node.id == current.id) if (node.style.match) |match| if (match.key == current.key) break node;
            } else null;
            const node = target orelse {
                self.drop(index);
                continue;
            };
            const sample = current.channel.advance(now) catch {
                self.drop(index);
                continue;
            };
            const t: f32 = @floatCast(sample.value);
            const to = lookOf(node);
            var look = Look.mix(current.from, to, t);
            const departing = if (current.fly) for (nodes) |*other| {
                if (other.id == current.other and !other.style.hidden) break other;
            } else null else null;
            if (departing) |other| {
                // The one coming is opaque by half the way; the other goes
                // with it and fades over the second half.
                look.opacity = to.opacity * @min(1, 2 * t);
                const fading = lookOf(other);
                var with = look;
                with.opacity = fading.opacity * (1 - std.math.clamp(2 * t - 1, 0, 1));
                with.background = fading.background;
                with.border = fading.border;
                with.color = fading.color;
                setLook(other, with);
                drawn[drawn_len] = .{ .key = current.key, .id = other.id, .look = with };
                drawn_len += 1;
            }
            setLook(node, look);
            drawn[drawn_len] = .{ .key = current.key, .id = node.id, .look = look };
            drawn_len += 1;
            if (current.channel.run == null) {
                self.drop(index);
                continue;
            }
            if (current.channel.nextWake(now, 16 * std.time.ns_per_ms) catch null) |deadline| wake = if (wake) |w| @min(w, deadline) else deadline;
            index += 1;
        }
        // Remember how each matched node shows, the one flying in over the
        // one it came from.
        const before = self.shown;
        const before_len = self.shown_len;
        var count: usize = 0;
        for (nodes) |*node| {
            const match = node.style.match orelse continue;
            if (match.key == 0 or node.style.hidden) continue;
            const look = for (drawn[0..drawn_len]) |entry| {
                if (entry.id == node.id) break entry.look;
            } else lookOf(node);
            // Forget the one a flight left once it is no longer built, so
            // that, built again, it comes back from here.
            const carried = if (self.flight(match.key)) |current| current.other else for (before[0..before_len]) |old| {
                if (old.key == match.key and old.id == node.id) break old.left;
            } else 0;
            const left = for (nodes) |*other| {
                if (carried != 0 and other.id == carried) break carried;
            } else 0;
            const shown: Shown = .{ .key = match.key, .id = node.id, .look = look, .left = left };
            const existing = for (self.shown[0..count]) |*entry| {
                if (entry.key == match.key) break entry;
            } else null;
            if (existing) |entry| {
                // A key two nodes share: keep the one a flight brings in, or
                // the one that held it, so the one going away never flies
                // back.
                const keep = if (self.flight(match.key)) |current| current.id else for (before[0..before_len]) |old| {
                    if (old.key == match.key) break old.id;
                } else entry.id;
                if (node.id == keep) entry.* = shown;
            } else if (count < capacity) {
                self.shown[count] = shown;
                count += 1;
            }
        }
        self.shown_len = count;
        return wake;
    }
};

/// How a node looks at rest, in its arranged box.
fn lookOf(node: anytype) Look {
    const style = node.style;
    return .{ .bounds = node.bounds, .pose = style.pose orelse .{}, .opacity = style.opacity, .background = style.background, .border = style.border, .color = style.color, .radius = style.radius };
}
fn setLook(node: anytype, look: Look) void {
    const pose = poseFor(node.bounds, look);
    node.style.pose = if (pose.isIdentity()) null else pose;
    node.style.opacity = std.math.clamp(look.opacity, 0, 1);
    node.style.background = look.background;
    node.style.border = look.border;
    node.style.color = look.color;
    node.style.radius = @max(0, look.radius);
}

test "turns go the short way round" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), @mod(turn(350, 10, 0.5), 360), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), turn(350, 10, 1), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 90), turn(0, 180, 0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 45), mixPose(.{ .rotate_y = 0 }, .{ .rotate_y = 90 }, 0.5).rotate_y, 1e-4);
}

test "a pose draws the arranged box where the look is" {
    const pose = poseFor(.{ .x = 100, .y = 100, .width = 200, .height = 100 }, .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 } });
    try std.testing.expectApproxEqAbs(@as(f32, -150), pose.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -125), pose.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pose.scale_x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pose.scale_y, 1e-4);
    try std.testing.expectEqual(@as(?u32, 0x808080), mixColor(0x000000, 0xffffff, 0.5));
    try std.testing.expectEqual(@as(?u32, 0xffffff), mixColor(null, 0xffffff, 0.5));
}
