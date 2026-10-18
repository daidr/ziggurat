const d = @import("document.zig");
/// Attribute input bytes per explicit element/definition processing pass.
/// Independent of draw-node, geometry, CSS and pixel work limits.
pub const Work = struct {
    used: u64 = 0,
    limit: u64,
    pub fn node(self: *Work, value: d.Node) !void {
        for (value.attributes) |attribute| {
            const amount = attribute.name.len + attribute.value.len + 2;
            if (amount > self.limit -| self.used) return error.ParseWorkExceeded;
            self.used += amount;
        }
    }
};
