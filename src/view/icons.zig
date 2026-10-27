//! The built-in icon set: outlines on a 24 by 24 grid, stroked 2 units wide
//! with round caps and joins, and tinted by the color they are drawn in.
//! This file holds only their names and path data; `View.icon` lays them
//! out and an `IconPainter` (such as `ziggurat_view_graphics.Icons`) draws
//! them from coverage prepared outside paint. The outlines are original to
//! this project.
const std = @import("std");

/// Side of the grid the path data is drawn on.
pub const grid: f32 = 24;
/// Stroke width on that grid.
pub const stroke: f32 = 2;

pub const Icon = enum {
    chevron_left,
    chevron_right,
    chevron_up,
    chevron_down,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    close,
    check,
    plus,
    minus,
    search,
    menu,
    more_horizontal,
    more_vertical,
    settings,
    home,
    info,
    warning,
    error_circle,
    help,
    star,
    heart,
    trash,
    edit,
    copy,
    refresh,
    download,
    upload,
    external_link,
    folder,
    file,
    calendar,
    user,
    bell,
    lock,
    eye,
    filter,
    play,
    pause,

    /// SVG path data on the 24-unit grid, for a stroke of `stroke` units.
    pub fn pathData(self: Icon) []const u8 {
        return switch (self) {
            .chevron_left => "M15 6 9 12 15 18",
            .chevron_right => "M9 6 15 12 9 18",
            .chevron_up => "M6 15 12 9 18 15",
            .chevron_down => "M6 9 12 15 18 9",
            .arrow_left => "M19 12H5M11 6 5 12 11 18",
            .arrow_right => "M5 12H19M13 6 19 12 13 18",
            .arrow_up => "M12 19V5M6 11 12 5 18 11",
            .arrow_down => "M12 5V19M6 13 12 19 18 13",
            .close => "M6 6 18 18M18 6 6 18",
            .check => "M5 12.5 10 17.5 19 7",
            .plus => "M12 5V19M5 12H19",
            .minus => "M5 12H19",
            .search => "M17 10.5A6.5 6.5 0 1 1 4 10.5A6.5 6.5 0 1 1 17 10.5ZM15.5 15.5 20 20",
            .menu => "M4 6H20M4 12H20M4 18H20",
            .more_horizontal => "M7 12A1 1 0 1 1 5 12A1 1 0 1 1 7 12ZM13 12A1 1 0 1 1 11 12A1 1 0 1 1 13 12ZM19 12A1 1 0 1 1 17 12A1 1 0 1 1 19 12Z",
            .more_vertical => "M13 6A1 1 0 1 1 11 6A1 1 0 1 1 13 6ZM13 12A1 1 0 1 1 11 12A1 1 0 1 1 13 12ZM13 18A1 1 0 1 1 11 18A1 1 0 1 1 13 18Z",
            .settings => "M9.93 5.31 10.39 2.64 13.61 2.64 14.07 5.31 15.27 5.81 17.48 4.24 19.76 6.52 18.19 8.73 18.69 9.93 21.36 10.39 21.36 13.61 18.69 14.07 18.19 15.27 19.76 17.48 17.48 19.76 15.27 18.19 14.07 18.69 13.61 21.36 10.39 21.36 9.93 18.69 8.73 18.19 6.52 19.76 4.24 17.48 5.81 15.27 5.31 14.07 2.64 13.61 2.64 10.39 5.31 9.93 5.81 8.73 4.24 6.52 6.52 4.24 8.73 5.81ZM15 12A3 3 0 1 1 9 12A3 3 0 1 1 15 12Z",
            .home => "M4 11 12 4 20 11M6 9.5V20H18V9.5M10 20V14H14V20",
            .info => "M21 12A9 9 0 1 1 3 12A9 9 0 1 1 21 12ZM12 11V17M12 7.5V7.5",
            .warning => "M12 3.5 21.5 20H2.5ZM12 10V14M12 17V17",
            .error_circle => "M21 12A9 9 0 1 1 3 12A9 9 0 1 1 21 12ZM9 9 15 15M15 9 9 15",
            .help => "M21 12A9 9 0 1 1 3 12A9 9 0 1 1 21 12ZM9.5 9.5A2.5 2.5 0 1 1 13 11.8C12.4 12.1 12 12.6 12 13.3V14M12 17V17",
            .star => "M12 3.6 14.29 9.44 20.56 9.82 15.71 13.81 17.29 19.88 12 16.5 6.71 19.88 8.29 13.81 3.44 9.82 9.71 9.44Z",
            .heart => "M12 20C7 16 3.5 12.8 3.5 9A4.25 4.25 0 0 1 12 7.2A4.25 4.25 0 0 1 20.5 9C20.5 12.8 17 16 12 20Z",
            .trash => "M4 7H20M9 7V4.5H15V7M6.5 7 7.5 20H16.5L17.5 7M10 11V16M14 11V16",
            .edit => "M4 20H8L19 9 15 5 4 16ZM13 7 17 11",
            .copy => "M9 9H20V20H9ZM15 9V4H4V15H9",
            .refresh => "M19 12A7 7 0 1 1 16.95 7.05M17.5 3V7.5H13",
            .download => "M12 4V15M7 10 12 15 17 10M5 20H19",
            .upload => "M12 15V4M7 9 12 4 17 9M5 20H19",
            .external_link => "M14 4H20V10M20 4 11 13M18 14V20H4V6H10",
            .folder => "M3 6H9.5L11.5 8.5H21V19H3Z",
            .file => "M6 3H14L19 8V21H6ZM14 3V8H19",
            .calendar => "M4 6H20V20H4ZM4 10H20M8 3V7M16 3V7",
            .user => "M16 8A4 4 0 1 1 8 8A4 4 0 1 1 16 8ZM4.5 20.5C5.5 16.5 8.5 14.5 12 14.5S18.5 16.5 19.5 20.5",
            .bell => "M6 16V11A6 6 0 0 1 18 11V16L19.5 18H4.5ZM10 20.5H14",
            .lock => "M5 11H19V20H5ZM8 11V8A4 4 0 0 1 16 8V11",
            .eye => "M2.5 12C5 7.5 8.5 5.5 12 5.5S19 7.5 21.5 12C19 16.5 15.5 18.5 12 18.5S5 16.5 2.5 12ZM15 12A3 3 0 1 1 9 12A3 3 0 1 1 15 12Z",
            .filter => "M4 5H20L14 12.5V19L10 17V12.5Z",
            .play => "M8 5 19 12 8 19Z",
            .pause => "M9 5V19M15 5V19",
        };
    }

    /// True for icons that point along the reading direction, which a
    /// right-to-left layout draws mirrored, so that "back" still points
    /// toward the start of the line.
    pub fn directional(self: Icon) bool {
        return switch (self) {
            .chevron_left, .chevron_right, .arrow_left, .arrow_right => true,
            else => false,
        };
    }
};

test "every icon has path data on the grid" {
    for (std.meta.tags(Icon)) |icon| {
        const data = icon.pathData();
        try std.testing.expect(data.len > 0 and data[0] == 'M');
        // Coordinates stay inside the 24-unit grid.
        var it = std.mem.tokenizeAny(u8, data, "MLHVCSAZ ");
        while (it.next()) |number| {
            const value = std.fmt.parseFloat(f32, number) catch continue;
            try std.testing.expect(value >= 0 and value <= grid);
        }
    }
    try std.testing.expect(Icon.chevron_left.directional());
    try std.testing.expect(!Icon.search.directional());
}
