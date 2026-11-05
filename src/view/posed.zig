//! Animated poses: a node whose `Style.pose_motion` is set moves to its
//! `Style.pose` and fades to its `Style.opacity` along that motion as
//! builds change them, from wherever it showed in the frame before.
//!
//! A pose starts where the node is first posed: a node the frame before
//! did not pose, as one built for the first time, shows at its pose at
//! once and moves only when a later build poses it elsewhere. To come in
//! from a pose, as a panel rising and fading in as it shows, pose it there
//! in one build, ask for another (`View.wakeAt`), and
//! pose it at its place in the next. A node appearing in a container the
//! frame before showed comes in with `View.presentColumn` too.
//!
//! While the desktop asks for less motion, a pose moves at once and only
//! the opacity fades smoothly. Like `Style.pose`, it moves what is drawn:
//! layout, focus and semantics keep the arranged box.
const std = @import("std");
const ui = @import("ziggurat_ui");
const animation = @import("ziggurat_animation");

const Pose = ui.effects.Pose;

/// The posed nodes a View follows at once; more show at their pose.
pub const capacity = 64;

/// Pose components and the opacity, in channel order.
const fields = [_][]const u8{ "x", "y", "z", "scale_x", "scale_y", "rotate", "rotate_x", "rotate_y" };
const count = fields.len + 1;

const Entry = struct {
    id: u64,
    channels: [count]animation.Channel,
    /// The last frame that posed it.
    frame: u64,
};

/// The frame step while the display's refresh is unknown.
pub const default_frame_interval: u64 = 16 * std.time.ns_per_ms;

pub const State = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    frame: u64 = 0,
    /// The time between frames of a moving pose: a refresh of the display.
    frame_interval: u64 = default_frame_interval,

    /// Move each posed node's pose and opacity toward what its build gave,
    /// and return when the next frame should come while any still moves.
    pub fn apply(self: *State, nodes: anytype, now: u64, reduce_motion: bool) ?u64 {
        self.frame += 1;
        var wake: ?u64 = null;
        for (nodes) |*node| {
            const motion = node.style.pose_motion orelse continue;
            const target = node.style.pose orelse Pose{};
            const to = values(target, node.style.opacity);
            const entry = self.find(node.id) orelse self.add(node.id, to, now) orelse continue;
            // Not posed in the frame before: it shows there at once.
            if (entry.frame + 1 < self.frame) entry.* = fresh(node.id, to, now) orelse continue;
            entry.frame = self.frame;
            var shown: [count]f32 = undefined;
            for (&entry.channels, to, 0..) |*channel, value, i| {
                const wanted: f64 = value;
                if (reduce_motion and i < fields.len) {
                    channel.jump(now, wanted) catch {};
                } else if (channel.target != wanted) {
                    channel.retarget(now, wanted, .{ .motion = motion }) catch channel.jump(now, wanted) catch {};
                }
                const sample = channel.advance(now) catch channel.sample();
                shown[i] = @floatCast(sample.value);
                if (channel.nextWake(now, self.frame_interval) catch null) |deadline| wake = if (wake) |w| @min(w, deadline) else deadline;
            }
            var pose = target;
            inline for (fields, 0..) |name, i| @field(pose, name) = shown[i];
            node.style.pose = if (pose.isIdentity()) null else pose;
            node.style.opacity = std.math.clamp(shown[fields.len], 0, 1);
        }
        // Nodes this frame did not pose are forgotten.
        var kept: usize = 0;
        for (self.entries[0..self.len]) |entry| if (entry.frame == self.frame) {
            self.entries[kept] = entry;
            kept += 1;
        };
        self.len = kept;
        return wake;
    }

    /// Whether any pose is still on its way.
    pub fn moving(self: *const State) bool {
        for (self.entries[0..self.len]) |*entry| for (&entry.channels) |*channel| if (channel.run != null) return true;
        return false;
    }

    fn find(self: *State, id: u64) ?*Entry {
        for (self.entries[0..self.len]) |*entry| if (entry.id == id) return entry;
        return null;
    }
    fn add(self: *State, id: u64, to: [count]f32, now: u64) ?*Entry {
        if (self.len == capacity) return null;
        self.entries[self.len] = fresh(id, to, now) orelse return null;
        // Older than any frame, so it starts in place.
        self.entries[self.len].frame = 0;
        self.len += 1;
        return &self.entries[self.len - 1];
    }
};

fn fresh(id: u64, to: [count]f32, now: u64) ?Entry {
    var entry: Entry = .{ .id = id, .channels = undefined, .frame = 0 };
    for (&entry.channels, to) |*channel, value| {
        channel.* = animation.Channel.init(value) catch return null;
        channel.jump(now, value) catch return null;
    }
    return entry;
}

fn values(pose: Pose, opacity: f32) [count]f32 {
    var result: [count]f32 = undefined;
    inline for (fields, 0..) |name, i| result[i] = @field(pose, name);
    result[fields.len] = opacity;
    return result;
}
