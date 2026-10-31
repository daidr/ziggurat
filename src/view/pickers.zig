//! Pickers for declarative views: a month calendar, date, time and number
//! inputs, and a color picker with the color well that opens it in a
//! popover. Each control binds to an application value and keeps its own
//! state in a value the application owns at a stable address, such as
//! `Calendar`, which must stay valid while any pass that builds it runs and
//! until the window stops routing input to it. Text is formatted and read in
//! the locale of `Region` through `ziggurat_i18n`; accessible names come
//! from `Texts`, which the application localizes. A control returns true in
//! the pass that applies a change to its value. Nothing here allocates.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const i18n = @import("ziggurat_i18n");

const View = view.View;
const Rect = view.Rect;
const Point = view.Point;
const Size = view.Size;
const Theme = view.Theme;
const Error = view.Error;
pub const HourCycle = i18n.date.HourCycle;

/// The regional formats a picker follows: the locale writes dates, times
/// and numbers, and its region decides the week and the hour cycle unless
/// they are given here.
pub const Region = struct {
    locale: i18n.Locale = .root,
    /// First day of the week, 0 for Sunday.
    first_weekday: ?u3 = null,
    /// Fewest days of a year in its first week, from 1 to 7.
    min_days: ?u3 = null,
    hour_cycle: ?HourCycle = null,

    pub fn week(self: *const Region) i18n.week.Week {
        var value = i18n.week.weekFor(&self.locale);
        if (self.first_weekday) |day| value.first_day = @intCast(day % 7);
        if (self.min_days) |days| value.min_days = std.math.clamp(days, 1, 7);
        return value;
    }
    pub fn hours(self: *const Region) HourCycle {
        return self.hour_cycle orelse i18n.date.hourCycle(&self.locale);
    }
};

/// Names that assistive technology reads for the parts of pickers that
/// show no text of their own. Copied each pass, so they need not outlive it.
pub const Texts = struct {
    previous_month: []const u8 = "Previous month",
    next_month: []const u8 = "Next month",
    hours: []const u8 = "Hours",
    minutes: []const u8 = "Minutes",
    day_period: []const u8 = "AM/PM",
    saturation: []const u8 = "Saturation and brightness",
    hue: []const u8 = "Hue",
    opacity: []const u8 = "Opacity",
    hex: []const u8 = "Hex",
};

/// A day of the proleptic Gregorian calendar from 0001-01-01 to 9999-12-31.
pub const Date = struct {
    year: u16,
    month: u4,
    day: u5,

    pub const first: Date = .{ .year = 1, .month = 1, .day = 1 };
    pub const last: Date = .{ .year = 9999, .month = 12, .day = 31 };

    pub fn valid(self: Date) bool {
        return self.year >= 1 and self.year <= 9999 and self.month >= 1 and self.month <= 12 and self.day >= 1 and self.day <= daysIn(self.year, self.month);
    }
    pub fn daysIn(year: u16, month: u4) u5 {
        return switch (month) {
            2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        };
    }
    /// Days since 1970-01-01.
    pub fn days(self: Date) i64 {
        return i18n.date.daysFromCivil(self.year, self.month, self.day);
    }
    /// The date `value` days after 1970-01-01, kept within the calendar.
    pub fn fromDays(value: i64) Date {
        const bounded = std.math.clamp(value, first.days(), last.days());
        const fields = i18n.date.civil(.{ .unix_seconds = bounded * 86400 }) catch unreachable;
        return .{ .year = fields.year, .month = fields.month, .day = fields.day };
    }
    pub fn addDays(self: Date, count: i64) Date {
        return fromDays(self.days() +| count);
    }
    /// The same day `count` months later, or the month's last day when it
    /// is shorter, kept within the calendar.
    pub fn addMonths(self: Date, count: i32) Date {
        const index = std.math.clamp(@as(i64, self.year) * 12 + self.month - 1 + count, 12, 9999 * 12 + 11);
        const year: u16 = @intCast(@divFloor(index, 12));
        const month: u4 = @intCast(@mod(index, 12) + 1);
        return .{ .year = year, .month = month, .day = @min(self.day, daysIn(year, month)) };
    }
    /// 0 is Sunday.
    pub fn weekday(self: Date) u3 {
        return @intCast(@mod(self.days() + 4, 7));
    }
    pub fn order(a: Date, b: Date) std.math.Order {
        return std.math.order(a.days(), b.days());
    }
    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
    fn clamp(self: Date, low: Date, high: Date) Date {
        if (self.order(low) == .lt) return low;
        if (self.order(high) == .gt) return high;
        return self;
    }
    fn firstOfMonth(self: Date) Date {
        return .{ .year = self.year, .month = self.month, .day = 1 };
    }
    fn civil(self: Date) i18n.date.Civil {
        return .{ .year = self.year, .month = self.month, .day = self.day, .hour = 0, .minute = 0, .second = 0, .weekday = self.weekday() };
    }
};

/// A time of day; a time input changes the hour and the minute and keeps
/// the second.
pub const TimeOfDay = struct {
    hour: u5 = 0,
    minute: u6 = 0,
    second: u6 = 0,
    pub fn valid(self: TimeOfDay) bool {
        return self.hour < 24 and self.minute < 60 and self.second < 60;
    }
};

/// A color with straight alpha, 255 being opaque.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(value: u32) Rgba {
        return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
    }
    pub fn color(self: Rgba) ui.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
    pub fn eql(a: Rgba, b: Rgba) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
    /// Reads `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`, the `#` optional,
    /// in either case; null for anything else.
    pub fn parseHex(text: []const u8) ?Rgba {
        const digits = if (std.mem.startsWith(u8, text, "#")) text[1..] else text;
        var values: [8]u8 = undefined;
        for (digits, 0..) |c, i| {
            if (i == values.len) return null;
            values[i] = std.fmt.charToDigit(c, 16) catch return null;
        }
        return switch (digits.len) {
            3, 4 => .{ .r = values[0] * 17, .g = values[1] * 17, .b = values[2] * 17, .a = if (digits.len == 4) values[3] * 17 else 255 },
            6, 8 => .{ .r = values[0] * 16 + values[1], .g = values[2] * 16 + values[3], .b = values[4] * 16 + values[5], .a = if (digits.len == 8) values[6] * 16 + values[7] else 255 },
            else => null,
        };
    }
    /// `#rrggbb`, or `#rrggbbaa` when it is not opaque, in lowercase.
    pub fn formatHex(self: Rgba, buffer: *[9]u8) []const u8 {
        return if (self.a == 255)
            std.fmt.bufPrint(buffer, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b }) catch unreachable
        else
            std.fmt.bufPrint(buffer, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b, self.a }) catch unreachable;
    }
};

/// A color as its hue from 0 to 360 and its saturation, value and alpha
/// from 0 to 1, which a color picker keeps so that grays and black keep
/// the hue the person chose.
pub const Hsva = struct {
    h: f64 = 0,
    s: f64 = 0,
    v: f64 = 0,
    a: f64 = 1,

    pub fn from(c: Rgba) Hsva {
        const r = @as(f64, @floatFromInt(c.r)) / 255;
        const g = @as(f64, @floatFromInt(c.g)) / 255;
        const b = @as(f64, @floatFromInt(c.b)) / 255;
        const high = @max(r, @max(g, b));
        const low = @min(r, @min(g, b));
        const delta = high - low;
        var h: f64 = 0;
        if (delta > 0) {
            if (high == r) h = 60 * @mod((g - b) / delta, 6) else if (high == g) h = 60 * ((b - r) / delta + 2) else h = 60 * ((r - g) / delta + 4);
        }
        if (h < 0) h += 360;
        return .{ .h = h, .s = if (high > 0) delta / high else 0, .v = high, .a = @as(f64, @floatFromInt(c.a)) / 255 };
    }
    pub fn rgba(self: Hsva) Rgba {
        const chroma = self.v * self.s;
        const sector = @mod(self.h, 360) / 60;
        const x = chroma * (1 - @abs(@mod(sector, 2) - 1));
        var r: f64 = 0;
        var g: f64 = 0;
        var b: f64 = 0;
        if (sector < 1) {
            r = chroma;
            g = x;
        } else if (sector < 2) {
            r = x;
            g = chroma;
        } else if (sector < 3) {
            g = chroma;
            b = x;
        } else if (sector < 4) {
            g = x;
            b = chroma;
        } else if (sector < 5) {
            r = x;
            b = chroma;
        } else {
            r = chroma;
            b = x;
        }
        const m = self.v - chroma;
        return .{ .r = channel(r + m), .g = channel(g + m), .b = channel(b + m), .a = channel(self.a) };
    }
    fn clamped(self: Hsva) Hsva {
        return .{ .h = std.math.clamp(self.h, 0, 360), .s = std.math.clamp(self.s, 0, 1), .v = std.math.clamp(self.v, 0, 1), .a = std.math.clamp(self.a, 0, 1) };
    }
};
fn channel(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

// ---------------------------------------------------------------- helpers

/// Fixed text storage that a picker refills each pass for its leaves to
/// paint; a full buffer is `TextFull`.
fn Strings(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        fn reset(self: *Self) void {
            self.len = 0;
        }
        fn add(self: *Self, value: []const u8) Error![]const u8 {
            if (capacity - self.len < value.len) return error.TextFull;
            const out = self.bytes[self.len..][0..value.len];
            @memcpy(out, value);
            self.len += value.len;
            return out;
        }
        fn writer(self: *Self) std.Io.Writer {
            return .fixed(self.bytes[self.len..]);
        }
        fn commit(self: *Self, out: *std.Io.Writer) []const u8 {
            const text = out.buffered();
            self.len += text.len;
            return text;
        }
        fn print(self: *Self, comptime format: []const u8, args: anytype) Error![]const u8 {
            const out = std.fmt.bufPrint(self.bytes[self.len..], format, args) catch return error.TextFull;
            self.len += out.len;
            return out;
        }
        /// A whole number in the locale's digits, at least `width` long.
        fn number(self: *Self, locale: *const i18n.Locale, value: i64, width: usize) Error![]const u8 {
            var out = self.writer();
            if (value >= 0 and width > 1) {
                var count: usize = 1;
                var rest = @divTrunc(value, 10);
                while (rest > 0) : (rest = @divTrunc(rest, 10)) count += 1;
                while (count < width) : (count += 1) i18n.number.formatInt(&out, locale, 0, .integer) catch return error.TextFull;
            }
            i18n.number.formatInt(&out, locale, value, .{ .max_fraction = 0, .grouping = false }) catch return error.TextFull;
            return self.commit(&out);
        }
        fn date(self: *Self, locale: *const i18n.Locale, value: Date, style: i18n.date.Style) Error![]const u8 {
            const data = i18n.date.dataFor(locale);
            var out = self.writer();
            i18n.date.formatPattern(&out, data, data.datePattern(style), value.civil()) catch return error.TextFull;
            return self.commit(&out);
        }
    };
}

/// The id of a part of the control `id`, such as a day of a calendar.
pub fn partId(id: u64, part: u64) u64 {
    const value = std.hash.Wyhash.hash(id, std.mem.asBytes(&part));
    return if (value == 0) 1 else value;
}
fn lastNode(v: *const View) *const view.Node {
    const all = v.nodes();
    return &all[all.len - 1];
}
fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}
fn inset(rect: Rect, amount: f32) Rect {
    return .{ .x = rect.x + amount, .y = rect.y + amount, .width = @max(0, rect.width - 2 * amount), .height = @max(0, rect.height - 2 * amount) };
}
fn offset(rect: Rect, origin: Rect) Rect {
    return .{ .x = rect.x + origin.x, .y = rect.y + origin.y, .width = rect.width, .height = rect.height };
}
/// Estimated extent of `text` at `size` DIP, as the view's default measurer.
fn textWidth(text: []const u8, size: f32) f32 {
    return view.Measurer.estimate(null, text).width * size / 16;
}
/// `text` centered in `rect` by its estimated width.
fn centered(frame: *ui.Frame, rect: Rect, text: []const u8, rgb: u32, font: ui.Font) void {
    const width = @min(rect.width, textWidth(text, font.size));
    frame.labelFont(.{ .x = rect.x + (rect.width - width) / 2, .y = rect.y, .width = width + 2, .height = rect.height }, text, rgb, font);
}
fn focusedOn(frame: *ui.Frame, id: u64) bool {
    return frame.context.input_state.focused == id;
}
fn plain(input: z.KeyInput) bool {
    const mods = input.modifiers;
    return !mods.control and !mods.alt and !mods.super;
}
fn digitOf(input: z.KeyInput) ?u8 {
    if (input.modifiers.shift or !plain(input)) return null;
    const code = @backingInt(input.key);
    if (code >= @backingInt(z.KeyCode.digit0) and code <= @backingInt(z.KeyCode.digit9)) return @intCast(code - @backingInt(z.KeyCode.digit0));
    if (code >= @backingInt(z.KeyCode.numpad0) and code <= @backingInt(z.KeyCode.numpad9)) return @intCast(code - @backingInt(z.KeyCode.numpad0));
    return null;
}
/// A field's frame: its border, in the focus color while it has focus,
/// and its fill.
fn paintField(frame: *ui.Frame, bounds: Rect, focused: bool, enabled: bool) void {
    const theme = frame.currentTheme();
    const palette = theme.palette;
    frame.roundedRect(bounds, 3, ui.Color.rgb(if (!enabled) palette.disabled_border else if (focused) palette.focus else palette.border));
    frame.roundedRect(inset(bounds, theme.metrics.border), 2, ui.Color.rgb(palette.field));
}
/// Gray squares that show transparency under a color.
fn checkers(frame: *ui.Frame, rect: Rect, side: f32) void {
    frame.roundedRect(rect, 0, ui.Color.rgb(0xffffff));
    var y = rect.y;
    var row: usize = 0;
    while (y < rect.y + rect.height) : ({
        y += side;
        row += 1;
    }) {
        var x = rect.x;
        var column: usize = 0;
        while (x < rect.x + rect.width) : ({
            x += side;
            column += 1;
        }) {
            if ((row + column) % 2 == 0) frame.roundedRect(.{ .x = x, .y = y, .width = @min(side, rect.x + rect.width - x), .height = @min(side, rect.y + rect.height - y) }, 0, ui.Color.rgb(0xcccccc));
        }
    }
}

/// A single line of text a picker edits from keys, with a caret.
const max_edit = 32;
const Edit = struct {
    bytes: [max_edit]u8 = undefined,
    len: usize = 0,
    caret: usize = 0,

    pub fn text(self: *const Edit) []const u8 {
        return self.bytes[0..self.len];
    }
    fn set(self: *Edit, value: []const u8) void {
        var length = @min(value.len, max_edit);
        while (length > 0 and length < value.len and value[length] & 0xc0 == 0x80) length -= 1;
        @memcpy(self.bytes[0..length], value[0..length]);
        self.len = length;
        self.caret = length;
    }
    fn insert(self: *Edit, value: []const u8) bool {
        if (self.len + value.len > max_edit) return false;
        std.mem.copyBackwards(u8, self.bytes[self.caret + value.len .. self.len + value.len], self.bytes[self.caret..self.len]);
        @memcpy(self.bytes[self.caret..][0..value.len], value);
        self.len += value.len;
        self.caret += value.len;
        return true;
    }
    fn previous(self: *const Edit, at: usize) usize {
        var index = at;
        while (index > 0) {
            index -= 1;
            if (self.bytes[index] & 0xc0 != 0x80) break;
        }
        return index;
    }
    fn next(self: *const Edit, at: usize) usize {
        var index = @min(at + 1, self.len);
        while (index < self.len and self.bytes[index] & 0xc0 == 0x80) index += 1;
        return index;
    }
    fn remove(self: *Edit, from: usize, to: usize) void {
        std.mem.copyForwards(u8, self.bytes[from .. self.len - (to - from)], self.bytes[to..self.len]);
        self.len -= to - from;
        self.caret = from;
    }
    /// Caret movement and deletion keys: null when `input` is none, true
    /// when the text changed.
    fn key(self: *Edit, input: z.KeyInput) ?bool {
        if (!plain(input)) return null;
        switch (input.key) {
            .left => self.caret = self.previous(self.caret),
            .right => self.caret = self.next(self.caret),
            .home => self.caret = 0,
            .end => self.caret = self.len,
            .backspace => {
                if (self.caret == 0) return false;
                self.remove(self.previous(self.caret), self.caret);
                return true;
            },
            .delete => {
                if (self.caret == self.len) return false;
                self.remove(self.caret, self.next(self.caret));
                return true;
            },
            else => return null,
        }
        return false;
    }
    /// Characters before the caret.
    fn column(self: *const Edit) usize {
        return std.unicode.utf8CountCodepoints(self.bytes[0..self.caret]) catch self.caret;
    }
};
/// Monospace text of an edited field, so the caret lands between
/// characters, and the caret while the field has focus.
const edit_font: ui.Font = .{ .size = 15, .monospace = true };
fn paintEdit(frame: *ui.Frame, rect: Rect, edit: *const Edit, focused: bool, enabled: bool) void {
    const palette = frame.currentTheme().palette;
    frame.labelFont(rect, edit.text(), if (enabled) palette.text else palette.disabled_text, edit_font);
    if (!focused) return;
    const advance = edit_font.size * 0.6;
    const x = @min(rect.x + rect.width - 1, rect.x + advance * @as(f32, @floatFromInt(edit.column())));
    const height = @min(rect.height, edit_font.size * 1.25);
    frame.roundedRect(.{ .x = x, .y = rect.y + (rect.height - height) / 2, .width = 1.5, .height = height }, 0, ui.Color.rgb(palette.text));
}

// --------------------------------------------------------------- calendar

/// Days that cannot be chosen, besides those outside a calendar's range.
/// The context stays valid while the calendar is built and takes input.
pub const Disabled = struct {
    context: ?*const anyopaque = null,
    call: *const fn (?*const anyopaque, Date) bool,
};

pub const CalendarOptions = struct {
    region: Region = .{},
    texts: Texts = .{},
    /// The first and last days that can be chosen; the keys and the month
    /// buttons stay within them.
    minimum: Date = Date.first,
    maximum: Date = Date.last,
    disabled: ?Disabled = null,
    /// Show the week of the year beside each week, counted in the
    /// region's way.
    week_numbers: bool = false,
    /// The day marked as today; the application knows its time zone.
    today: ?Date = null,
    /// Style of the calendar's column; `Style.name` names its grid,
    /// which is otherwise named by the month shown.
    style: view.Style = .{},
};

/// A calendar's state, owned by the application at a stable address.
pub const Calendar = struct {
    /// The day the keys are on and whose month is shown. It starts at the
    /// bound date and follows it when the application changes it.
    cursor: ?Date = null,
    /// The date bound in the last pass.
    seen: ?Date = null,
    grid: Grid = .{},
};

const cell_width: f32 = 34;
const cell_height: f32 = 30;
const header_height: f32 = 22;
const week_width: f32 = 30;
const cell_gap: f32 = 2;
const cells = 42;

const Grid = struct {
    id: u64 = 0,
    enabled: bool = true,
    /// What this pass shows.
    month: Date = Date.first,
    start: Date = Date.first,
    chosen: Date = Date.first,
    cursor: Date = Date.first,
    today: ?Date = null,
    minimum: Date = Date.first,
    maximum: Date = Date.last,
    disabled: ?Disabled = null,
    week_numbers: bool = false,
    moves_choose: bool = true,
    name: []const u8 = "",
    weekdays: [7][]const u8 = undefined,
    numbers: [cells][]const u8 = undefined,
    labels: [cells][]const u8 = undefined,
    weeks: [6][]const u8 = undefined,
    allowed: [cells]bool = undefined,
    strings: Strings(4096) = .{},
    hover: ?usize = null,
    /// What input asked for since the last pass.
    pending: ?Date = null,
    moved: bool = false,

    fn owner(self: *Grid) *Calendar {
        return @fieldParentPtr("grid", self);
    }
    fn size(week_numbers: bool) Size {
        return .{ .width = (if (week_numbers) week_width + cell_gap else 0) + 7 * cell_width + 6 * cell_gap, .height = header_height + cell_gap + 6 * cell_height + 5 * cell_gap };
    }
    fn originX(self: *const Grid) f32 {
        return if (self.week_numbers) week_width + cell_gap else 0;
    }
    /// The cell `index` relative to the grid's origin.
    pub fn cell(self: *const Grid, index: usize) Rect {
        const column: f32 = @floatFromInt(index % 7);
        const row: f32 = @floatFromInt(index / 7);
        return .{ .x = self.originX() + column * (cell_width + cell_gap), .y = header_height + cell_gap + row * (cell_height + cell_gap), .width = cell_width, .height = cell_height };
    }
    fn cellAt(self: *const Grid, point: Point) ?usize {
        for (0..cells) |index| if (contains(self.cell(index), point)) return index;
        return null;
    }
    fn dayOf(self: *const Grid, index: usize) Date {
        return self.start.addDays(@intCast(index));
    }
    fn indexOf(self: *const Grid, day: Date) ?usize {
        const delta = day.days() - self.start.days();
        return if (delta >= 0 and delta < cells) @intCast(delta) else null;
    }
    fn choosable(self: *const Grid, day: Date) bool {
        if (day.order(self.minimum) == .lt or day.order(self.maximum) == .gt) return false;
        const rule = self.disabled orelse return true;
        return !rule.call(rule.context, day);
    }
    /// Move the keys to `day` within the range; a standalone calendar
    /// chooses it too.
    fn moveTo(self: *Grid, day: Date) void {
        const target = day.clamp(self.minimum, self.maximum);
        self.owner().cursor = target;
        self.cursor = target;
        self.moved = true;
        if (self.moves_choose and self.choosable(target)) self.pending = target;
    }

    fn embed(self: *Grid) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .focusable = true, .input = input };
    }
    fn measure(ptr: *anyopaque, _: Theme) view.layout.Measurement {
        const self: *Grid = @ptrCast(@alignCast(ptr));
        const extent = size(self.week_numbers);
        return .{ .minimum = extent, .preferred = extent };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *Grid = @ptrCast(@alignCast(ptr));
        const palette = frame.currentTheme().palette;
        const focused = focusedOn(frame, id);
        const cursor_index = self.indexOf(self.cursor);
        try frame.semantic(.{ .id = id, .role = .calendar, .name = self.name, .value = if (cursor_index) |at| self.labels[at] else "", .bounds = bounds, .enabled = self.enabled, .focused = focused });
        const header_font: ui.Font = .{ .size = 12 };
        for (self.weekdays, 0..) |name, column| {
            const rect = self.cell(column);
            centered(frame, .{ .x = bounds.x + rect.x, .y = bounds.y, .width = rect.width, .height = header_height }, name, palette.disabled_text, header_font);
        }
        if (self.week_numbers) for (self.weeks, 0..) |label, row| {
            const rect = self.cell(row * 7);
            centered(frame, .{ .x = bounds.x, .y = bounds.y + rect.y, .width = week_width, .height = rect.height }, label, palette.disabled_text, header_font);
        };
        const day_font: ui.Font = .{ .size = 14 };
        for (0..cells) |index| {
            const rect = offset(self.cell(index), bounds);
            const day = self.dayOf(index);
            const chosen = day.eql(self.chosen);
            const at_cursor = if (cursor_index) |at| at == index else false;
            const allowed = self.allowed[index] and self.enabled;
            if (chosen) {
                frame.roundedRect(rect, 4, ui.Color.rgb(if (allowed) palette.accent else palette.disabled_accent));
            } else if (at_cursor or (allowed and if (self.hover) |at| at == index else false)) {
                frame.roundedRect(rect, 4, ui.Color.rgb(palette.control));
            }
            if (!chosen) if (self.today) |today| if (day.eql(today)) frame.strokeRect(rect, 4, 1, ui.Color.rgb(palette.accent));
            if (at_cursor and focused) frame.strokeRect(inset(rect, -1), 5, 2, ui.Color.rgb(palette.focus));
            const outside = day.month != self.month.month;
            const color = if (chosen) palette.on_accent else if (!allowed or outside) palette.disabled_text else palette.text;
            centered(frame, rect, self.numbers[index], color, day_font);
            try frame.semantic(.{ .id = partId(id, @bitCast(day.days())), .parent = id, .role = .button, .name = self.labels[index], .bounds = rect, .enabled = allowed, .checked = chosen });
        }
    }
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Grid = @ptrCast(@alignCast(ptr));
        switch (event) {
            .pointer_move => |point| {
                const hit = self.cellAt(point);
                if (std.meta.eql(hit, self.hover)) return false;
                self.hover = hit;
                return true;
            },
            .pointer_leave => {
                if (self.hover == null) return false;
                self.hover = null;
                return true;
            },
            .pointer_down => |press| {
                const index = self.cellAt(press.position) orelse return true;
                const day = self.dayOf(index);
                self.owner().cursor = day.clamp(self.minimum, self.maximum);
                if (self.choosable(day)) self.pending = day;
                return true;
            },
            .key => |press| {
                if (!plain(press)) return false;
                const cursor = self.cursor;
                const shift = press.modifiers.shift;
                switch (press.key) {
                    .left => self.moveTo(cursor.addDays(-1)),
                    .right => self.moveTo(cursor.addDays(1)),
                    .up => self.moveTo(cursor.addDays(-7)),
                    .down => self.moveTo(cursor.addDays(7)),
                    .page_up => self.moveTo(cursor.addMonths(if (shift) -12 else -1)),
                    .page_down => self.moveTo(cursor.addMonths(if (shift) 12 else 1)),
                    .home => self.moveTo(cursor.firstOfMonth()),
                    .end => self.moveTo(.{ .year = cursor.year, .month = cursor.month, .day = Date.daysIn(cursor.year, cursor.month) }),
                    .enter, .space => {
                        if (press.repeat) return true;
                        if (self.choosable(cursor)) self.pending = cursor;
                    },
                    else => return false,
                }
                return true;
            },
            else => return false,
        }
    }
};

const CalendarResult = struct { changed: bool, picked: bool, grid: u64 };

fn buildCalendar(v: *View, state: *Calendar, date: *Date, options: CalendarOptions, moves_choose: bool) Error!CalendarResult {
    if (!date.valid() or !options.minimum.valid() or !options.maximum.valid()) return error.InvalidValue;
    if (options.minimum.order(options.maximum) == .gt) return error.InvalidRange;
    const grid = &state.grid;
    grid.minimum = options.minimum;
    grid.maximum = options.maximum;
    grid.disabled = options.disabled;
    grid.moves_choose = moves_choose;
    var result: CalendarResult = .{ .changed = false, .picked = false, .grid = 0 };
    const choose = struct {
        fn apply(target: *Date, day: Date, out: *CalendarResult) void {
            out.picked = true;
            if (day.eql(target.*)) return;
            target.* = day;
            out.changed = true;
        }
    }.apply;
    if (grid.pending) |day| {
        grid.pending = null;
        if (grid.choosable(day)) choose(date, day, &result);
    }
    // The application moved the date: the calendar shows it.
    if (state.seen == null or !state.seen.?.eql(date.*)) state.cursor = date.*;
    state.seen = date.*;
    var cursor = (state.cursor orelse date.*).clamp(options.minimum, options.maximum);

    const locale = &options.region.locale;
    const week = options.region.week();
    var column = options.style;
    if (column.gap == 0) column.gap = 4;
    try v.column(column);
    try v.row(.{ .alignment = .center, .gap = 4 });
    const earliest = options.minimum.firstOfMonth();
    const latest = options.maximum.firstOfMonth();
    if (try v.navButton(.back, .{ .name = options.texts.previous_month, .enabled = cursor.firstOfMonth().order(earliest) == .gt })) {
        cursor = cursor.addMonths(-1).clamp(options.minimum, options.maximum);
        if (moves_choose and grid.choosable(cursor)) choose(date, cursor, &result);
    }
    try v.spacer(.{});
    grid.strings.reset();
    const title_text = blk: {
        var out = grid.strings.writer();
        i18n.date.formatMonthYear(&out, locale, cursor.civil()) catch return error.TextFull;
        break :blk grid.strings.commit(&out);
    };
    try v.text(title_text, .{ .font = .{ .size = 16, .weight = .semibold } });
    try v.spacer(.{});
    if (try v.navButton(.forward, .{ .name = options.texts.next_month, .enabled = cursor.firstOfMonth().order(latest) == .lt })) {
        cursor = cursor.addMonths(1).clamp(options.minimum, options.maximum);
        if (moves_choose and grid.choosable(cursor)) choose(date, cursor, &result);
    }
    try v.end();
    if (moves_choose and result.picked) cursor = date.*;
    state.cursor = cursor;
    state.seen = date.*;

    // Six weeks from the first day of the week on or before the first.
    const month = cursor.firstOfMonth();
    const back = @mod(@as(i64, month.weekday()) - week.first_day, 7);
    grid.month = month;
    grid.start = month.addDays(-back);
    grid.chosen = date.*;
    grid.cursor = cursor;
    grid.today = options.today;
    grid.week_numbers = options.week_numbers;
    grid.name = try grid.strings.add(if (options.style.name.len > 0) options.style.name else title_text);
    const data = i18n.date.dataFor(locale);
    for (&grid.weekdays, 0..) |*name, column_index| name.* = try grid.strings.add(data.weekdays_abbr[(week.first_day + column_index) % 7]);
    for (0..cells) |index| {
        const day = grid.dayOf(index);
        grid.numbers[index] = try grid.strings.number(locale, day.day, 1);
        grid.labels[index] = try grid.strings.date(locale, day, .full);
        grid.allowed[index] = grid.choosable(day);
    }
    if (options.week_numbers) for (&grid.weeks, 0..) |*label, row| {
        const day = grid.dayOf(row * 7);
        label.* = try grid.strings.number(locale, i18n.week.weekOfYear(day.year, day.month, day.day, week).week, 1);
    };
    try v.embed(grid.embed(), .{});
    const leaf = lastNode(v);
    grid.id = leaf.id;
    grid.enabled = leaf.style.enabled;
    result.grid = leaf.id;
    // Assistive technology invokes days by their own ids.
    if (grid.enabled) for (0..cells) |index| {
        const day = grid.dayOf(index);
        if (v.takeEvent(partId(leaf.id, @bitCast(day.days()))) != null and grid.allowed[index]) {
            choose(date, day, &result);
            state.cursor = day;
            grid.cursor = day;
        }
    };
    grid.chosen = date.*;
    state.seen = date.*;
    if (grid.moved) {
        grid.moved = false;
        if (grid.indexOf(grid.cursor)) |at| v.announce(grid.labels[at]);
    }
    try v.end();
    return result;
}

/// A month's calendar choosing `date`, its weeks starting on the region's
/// first day: a press chooses a day, as the arrows do while the grid has
/// focus; Page Up and Page Down or the buttons move by months (with Shift,
/// by years), and Home and End go to the first and the last day of the
/// month. Days outside `options.minimum`..`options.maximum` or marked by
/// `options.disabled` are dimmed and cannot be chosen. Assistive technology
/// reads the day the keys reach. True when `date` changed.
pub fn calendar(v: *View, state: *Calendar, date: *Date, options: CalendarOptions) Error!bool {
    return (try buildCalendar(v, state, date, options, true)).changed;
}

pub const DateInputOptions = struct {
    calendar: CalendarOptions = .{},
    /// How the field writes the date, short by default, as 3/5/24.
    format: i18n.date.Style = .short,
    /// Style of the field; `Style.name` names it.
    style: view.Style = .{},
};
pub const DateInput = struct {
    /// Whether the calendar is open.
    open: bool = false,
    calendar: Calendar = .{},
    strings: Strings(96) = .{},
};

/// A field showing `date` in the region's format that opens a calendar
/// below it: a press, Enter or Space opens it with focus on the date.
/// There the arrows, Page Up and Page Down, Home and End move between days
/// without choosing them, and a press, Enter or Space chooses one, which
/// closes the calendar with focus back on the field; Escape or a press
/// outside closes it unchanged. True when `date` changed.
pub fn dateInput(v: *View, state: *DateInput, date: *Date, options: DateInputOptions) Error!bool {
    if (!date.valid()) return error.InvalidValue;
    state.strings.reset();
    const text = try state.strings.date(&options.calendar.region.locale, date.*, options.format);
    var style = options.style;
    if (style.min_width == 0) style.min_width = 140;
    if (try v.popupButton(text, state.open, style)) {
        state.open = !state.open;
        state.calendar.cursor = date.*;
        state.calendar.seen = date.*;
    }
    const anchor = lastNode(v).id;
    var changed = false;
    if (try v.popover(&state.open, .{}, .{ .name = options.style.name })) {
        const opened = v.popover_opened != null;
        const result = try buildCalendar(v, &state.calendar, date, options.calendar, false);
        changed = result.changed;
        // Focus starts on the days, not on the month buttons.
        if (opened) v.restore = result.grid;
        if (result.picked) {
            state.open = false;
            v.restore = anchor;
        }
    }
    try v.end();
    return changed;
}

// ------------------------------------------------------------- time input

pub const TimeOptions = struct {
    region: Region = .{},
    texts: Texts = .{},
    /// Style of the field; `Style.name` names its group of segments.
    style: view.Style = .{},
};
pub const TimeInput = struct {
    leaf: TimeLeaf = .{},
};

const Segment = enum(u2) { hour, minute, period };
const segment_pad: f32 = 4;
const field_pad: f32 = 10;
const field_height: f32 = 40;
const TimeLeaf = struct {
    id: u64 = 0,
    enabled: bool = true,
    value: TimeOfDay = .{},
    twelve: bool = false,
    order: [3]Segment = .{ .hour, .minute, .period },
    count: usize = 2,
    /// The segment the keys change, as an index into `order`.
    active: usize = 0,
    typed: [2]u8 = undefined,
    typed_len: usize = 0,
    pending: ?TimeOfDay = null,
    texts: [3][]const u8 = undefined,
    names: [3][]const u8 = undefined,
    separator: []const u8 = ":",
    name: []const u8 = "",
    period_names: [2][]const u8 = .{ "AM", "PM" },
    period_initials: [2]u8 = .{ 'a', 'p' },
    widths: [3]f32 = .{ 0, 0, 0 },
    separator_width: f32 = 0,
    extent: Size = .{},
    annotation: view.Annotation = .{},
    strings: Strings(256) = .{},

    fn embed(self: *TimeLeaf) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .annotate = annotate, .focusable = true, .input = input };
    }
    fn measure(ptr: *anyopaque, _: Theme) view.layout.Measurement {
        const self: *TimeLeaf = @ptrCast(@alignCast(ptr));
        return .{ .minimum = self.extent, .preferred = self.extent };
    }
    fn annotate(ptr: *anyopaque, annotation: view.Annotation) void {
        const self: *TimeLeaf = @ptrCast(@alignCast(ptr));
        self.annotation = annotation;
    }
    /// The segments' rects, in display order, relative to the field.
    fn segmentRect(self: *const TimeLeaf, index: usize) Rect {
        var x: f32 = field_pad;
        for (0..index) |at| {
            x += self.widths[@backingInt(self.order[at])] + 2 * segment_pad;
            x += if (self.order[at + 1] == .minute) self.separator_width else segment_pad;
        }
        return .{ .x = x, .y = 8, .width = self.widths[@backingInt(self.order[index])] + 2 * segment_pad, .height = field_height - 16 };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *TimeLeaf = @ptrCast(@alignCast(ptr));
        const palette = frame.currentTheme().palette;
        const focused = focusedOn(frame, id);
        paintField(frame, bounds, focused, self.enabled);
        const name = if (self.name.len > 0) self.name else self.annotation.name;
        try frame.semantic(.{ .id = id, .role = .group, .name = name, .description = self.annotation.description, .invalid = self.annotation.invalid, .required = self.annotation.required, .bounds = bounds, .enabled = self.enabled });
        const font: ui.Font = .{ .size = 16 };
        for (self.order[0..self.count], 0..) |segment, index| {
            const rect = offset(self.segmentRect(index), bounds);
            const active = focused and index == self.active;
            if (active) frame.roundedRect(rect, 4, ui.Color.rgb(palette.accent));
            const color = if (!self.enabled) palette.disabled_text else if (active) palette.on_accent else palette.text;
            centered(frame, rect, self.texts[@backingInt(segment)], color, font);
            if (index + 1 < self.count and self.order[index + 1] == .minute) {
                centered(frame, .{ .x = rect.x + rect.width, .y = rect.y, .width = self.separator_width, .height = rect.height }, self.separator, palette.disabled_text, font);
            }
            const value: f64, const low: f64, const high: f64 = switch (segment) {
                .hour => if (self.twelve) .{ @floatFromInt((@as(u32, self.value.hour) + 11) % 12 + 1), 1, 12 } else .{ @floatFromInt(self.value.hour), 0, 23 },
                .minute => .{ @floatFromInt(self.value.minute), 0, 59 },
                .period => .{ if (self.value.hour >= 12) 1 else 0, 0, 1 },
            };
            try frame.semantic(.{ .id = partId(id, @backingInt(segment)), .parent = id, .role = .stepper, .name = self.names[@backingInt(segment)], .value = self.texts[@backingInt(segment)], .bounds = rect, .enabled = self.enabled, .focused = active, .range_value = value, .range_minimum = low, .range_maximum = high, .range_small_change = 1, .range_large_change = 1 });
        }
    }
    fn current(self: *const TimeLeaf) TimeOfDay {
        return self.pending orelse self.value;
    }
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *TimeLeaf = @ptrCast(@alignCast(ptr));
        switch (event) {
            .pointer_down => |press| {
                for (0..self.count) |index| if (contains(self.segmentRect(index), press.position)) {
                    self.active = index;
                    self.typed_len = 0;
                };
                return true;
            },
            .key => |press| return self.key(press),
            else => return false,
        }
    }
    fn key(self: *TimeLeaf, press: z.KeyInput) bool {
        if (!plain(press)) return false;
        const segment = self.order[self.active];
        switch (press.key) {
            .up, .down => {
                if (press.modifiers.shift) return false;
                self.typed_len = 0;
                self.pending = step(self.current(), segment, if (press.key == .up) 1 else -1, self.twelve);
                return true;
            },
            .left, .right => {
                if (press.modifiers.shift) return false;
                return self.moveSegment(press.key == .right);
            },
            .tab => return self.moveSegment(!press.modifiers.shift),
            else => {},
        }
        if (segment == .period) {
            const name = @tagName(press.key);
            if (name.len != 1 or press.modifiers.shift) return false;
            const letter = std.ascii.toLower(name[0]);
            const now = self.current();
            const want_pm = if (letter == self.period_initials[1]) true else if (letter == self.period_initials[0]) false else return false;
            if (want_pm != (now.hour >= 12)) self.pending = .{ .hour = if (want_pm) now.hour + 12 else now.hour - 12, .minute = now.minute, .second = now.second };
            return true;
        }
        const digit = digitOf(press) orelse return false;
        self.typeDigit(segment, digit);
        return true;
    }
    fn moveSegment(self: *TimeLeaf, forward: bool) bool {
        self.typed_len = 0;
        if (forward and self.active + 1 < self.count) {
            self.active += 1;
            return true;
        }
        if (!forward and self.active > 0) {
            self.active -= 1;
            return true;
        }
        return false;
    }
    /// The first digit typed sets the segment, a second makes two digits of
    /// them or starts again past the top; once the hours have two digits,
    /// or one that cannot start two, the keys go on to the minutes.
    fn typeDigit(self: *TimeLeaf, segment: Segment, digit: u8) void {
        const top: u32 = switch (segment) {
            .hour => if (self.twelve) 13 else 24,
            .minute => 60,
            .period => unreachable,
        };
        if (self.typed_len == 2) self.typed_len = 0;
        self.typed[self.typed_len] = digit;
        self.typed_len += 1;
        var number: u32 = 0;
        for (self.typed[0..self.typed_len]) |d| number = number * 10 + d;
        if (number >= top) {
            self.typed[0] = digit;
            self.typed_len = 1;
            number = digit;
        }
        const now = self.current();
        var next = now;
        switch (segment) {
            .hour => if (self.twelve) {
                // 0 starts 01 to 09 and sets nothing yet.
                if (number != 0) next.hour = @intCast(@as(u32, now.hour) / 12 * 12 + number % 12);
            } else {
                next.hour = @intCast(number);
            },
            .minute => next.minute = @intCast(number),
            .period => unreachable,
        }
        if (!std.meta.eql(next, now)) self.pending = next;
        if (segment == .hour and (self.typed_len == 2 or number * 10 >= top)) {
            self.typed_len = 0;
            for (self.order[0..self.count], 0..) |entry, index| if (entry == .minute) {
                self.active = index;
            };
        }
    }
};

/// `value` with `segment` stepped by `delta` round the clock; in 12 hours
/// the hours go round the same half of the day.
fn step(value: TimeOfDay, segment: Segment, delta: i32, twelve: bool) TimeOfDay {
    var next = value;
    switch (segment) {
        .hour => if (twelve) {
            const half = @as(i32, value.hour) - @mod(@as(i32, value.hour), 12);
            next.hour = @intCast(half + @mod(@mod(@as(i32, value.hour), 12) + delta, 12));
        } else {
            next.hour = @intCast(@mod(@as(i32, value.hour) + delta, 24));
        },
        .minute => next.minute = @intCast(@mod(@as(i32, value.minute) + delta, 60)),
        .period => next.hour = @intCast(@mod(@as(i32, value.hour) + 12, 24)),
    }
    return next;
}

/// The text between the hours and the minutes of a CLDR time pattern such
/// as `h:mm a` or `H 'h' mm`, its quotes removed, and whether the day period
/// comes before the hours.
pub const TimeLayout = struct { separator: []const u8, period_first: bool };
pub fn timeLayout(pattern: []const u8, buffer: []u8) TimeLayout {
    var hour_seen = false;
    var period_seen = false;
    var period_first = false;
    var separator_len: usize = 0;
    var collecting = false;
    var done = false;
    var quoted = false;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const c = pattern[index];
        if (c == '\'') {
            if (index + 1 < pattern.len and pattern[index + 1] == '\'') {
                if (collecting and separator_len < buffer.len) {
                    buffer[separator_len] = '\'';
                    separator_len += 1;
                }
                index += 1;
            } else quoted = !quoted;
            continue;
        }
        if (!quoted and std.ascii.isAlphabetic(c)) {
            while (index + 1 < pattern.len and pattern[index + 1] == c) index += 1;
            switch (c) {
                'h', 'H', 'k', 'K' => if (!hour_seen) {
                    hour_seen = true;
                    if (period_seen) period_first = true;
                    collecting = true;
                    separator_len = 0;
                },
                'm' => if (collecting) {
                    collecting = false;
                    done = true;
                },
                'a', 'b', 'B' => period_seen = true,
                else => {},
            }
            continue;
        }
        if (collecting and separator_len < buffer.len) {
            buffer[separator_len] = c;
            separator_len += 1;
        }
    }
    return .{ .separator = if (done) buffer[0..separator_len] else ":", .period_first = period_first };
}

/// A field of the time of day of `time` in the region's hour cycle: 15:04,
/// or 3:04 PM with the locale's names of the halves of the day, before the
/// hours where the locale writes them so. Its hours, minutes and half of
/// the day are segments: Up and Down step the active one round the clock,
/// digits typed set it and go on to the minutes once the hours are typed,
/// A or P (or the first letter of the locale's names) chooses the half of
/// the day, and Left and Right, or Tab and Shift+Tab, move between them.
/// Assistive technology sees spin buttons named by `Texts`. The seconds
/// stay as they are. True when `time` changed.
pub fn timeInput(v: *View, state: *TimeInput, time: *TimeOfDay, options: TimeOptions) Error!bool {
    if (!time.valid()) return error.InvalidValue;
    const leaf = &state.leaf;
    var changed = false;
    if (leaf.pending) |next| {
        leaf.pending = null;
        if (!std.meta.eql(next, time.*)) {
            time.* = next;
            changed = true;
        }
    }
    const locale = &options.region.locale;
    const data = i18n.date.dataFor(locale);
    const twelve = options.region.hours() == .h12;
    leaf.strings.reset();
    var separator_buffer: [16]u8 = undefined;
    const layout = timeLayout(data.timePattern(.short), &separator_buffer);
    leaf.twelve = twelve;
    leaf.count = if (twelve) 3 else 2;
    leaf.order = if (twelve and layout.period_first) .{ .period, .hour, .minute } else .{ .hour, .minute, .period };
    if (leaf.active >= leaf.count) leaf.active = 0;
    leaf.separator = try leaf.strings.add(layout.separator);
    leaf.name = try leaf.strings.add(options.style.name);
    leaf.names = .{ try leaf.strings.add(options.texts.hours), try leaf.strings.add(options.texts.minutes), try leaf.strings.add(options.texts.day_period) };
    for (data.am_pm, 0..) |period, index| {
        leaf.period_names[index] = try leaf.strings.add(period);
        const first = if (period.len > 0) std.ascii.toLower(period[0]) else 0;
        leaf.period_initials[index] = if (std.ascii.isAlphabetic(first)) first else if (index == 0) 'a' else 'p';
    }

    try v.embed(leaf.embed(), options.style);
    const node = lastNode(v);
    leaf.id = node.id;
    leaf.enabled = node.style.enabled;
    // Assistive technology sets a segment's value by its own id.
    inline for (.{ Segment.hour, Segment.minute, Segment.period }) |segment| {
        if (v.takeEvent(partId(node.id, @backingInt(segment)))) |event| if (event == .value and leaf.enabled and (segment != .period or twelve)) {
            const next = setSegment(time.*, segment, event.value.change, twelve);
            if (!std.meta.eql(next, time.*)) {
                time.* = next;
                changed = true;
            }
        };
    }
    leaf.value = time.*;
    const hour_shown: i64 = if (twelve) @mod(@as(i64, time.hour) + 11, 12) + 1 else time.hour;
    leaf.texts = .{
        try leaf.strings.number(locale, hour_shown, if (twelve) 1 else 2),
        try leaf.strings.number(locale, time.minute, 2),
        leaf.period_names[if (time.hour >= 12) 1 else 0],
    };
    const digits = @max(textWidth(try leaf.strings.number(locale, 88, 2), 16), textWidth("88", 16));
    leaf.widths = .{ digits, digits, @max(textWidth(leaf.period_names[0], 16), textWidth(leaf.period_names[1], 16)) };
    leaf.separator_width = textWidth(leaf.separator, 16) + 2;
    var width: f32 = 2 * field_pad;
    for (leaf.order[0..leaf.count], 0..) |segment, index| {
        width += leaf.widths[@backingInt(segment)] + 2 * segment_pad;
        if (index + 1 < leaf.count) width += if (leaf.order[index + 1] == .minute) leaf.separator_width else segment_pad;
    }
    leaf.extent = .{ .width = width, .height = field_height };
    // Typing restarts when the field loses focus.
    if (v.focus == null or v.focus.? != node.id) leaf.typed_len = 0;
    return changed;
}

fn setSegment(value: TimeOfDay, segment: Segment, change: view.ValueChange, twelve: bool) TimeOfDay {
    var next = value;
    switch (segment) {
        .hour => {
            const range: view.Range = if (twelve) .{ .minimum = 1, .maximum = 12, .step = 1 } else .{ .minimum = 0, .maximum = 23, .step = 1 };
            const shown: f64 = if (twelve) @floatFromInt((@as(u32, value.hour) + 11) % 12 + 1) else @floatFromInt(value.hour);
            const target: u32 = @intFromFloat(range.apply(shown, change) catch shown);
            next.hour = @intCast(if (twelve) @as(u32, value.hour) / 12 * 12 + target % 12 else target);
        },
        .minute => {
            const range: view.Range = .{ .minimum = 0, .maximum = 59, .step = 1 };
            next.minute = @intFromFloat((range.apply(@floatFromInt(value.minute), change) catch @as(f64, @floatFromInt(value.minute))));
        },
        .period => {
            const range: view.Range = .{ .minimum = 0, .maximum = 1, .step = 1 };
            const pm = (range.apply(if (value.hour >= 12) 1 else 0, change) catch 0) >= 0.5;
            if (pm != (value.hour >= 12)) next.hour = @intCast(@mod(@as(u32, value.hour) + 12, 24));
        },
    }
    return next;
}

// ----------------------------------------------------------- number input

pub const NumberOptions = struct {
    region: Region = .{},
    /// Style of the field; `Style.name` names it.
    style: view.Style = .{},
    /// Preferred width before the parent's layout applies.
    width: f32 = 140,
};
pub const NumberInput = struct {
    leaf: NumberLeaf = .{},
};

const NumberLeaf = struct {
    id: u64 = 0,
    enabled: bool = true,
    edit: Edit = .{},
    /// The text was typed since the field took focus, so it is not
    /// rewritten from the value until the field loses focus.
    editing: bool = false,
    typed: bool = false,
    revert: bool = false,
    value: f64 = 0,
    range: view.Range = .{ .minimum = 0, .maximum = 1 },
    decimal: [8]u8 = undefined,
    decimal_len: usize = 0,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    width: f32 = 140,
    annotation: view.Annotation = .{},

    fn embed(self: *NumberLeaf) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .annotate = annotate, .input = input };
    }
    fn measure(ptr: *anyopaque, _: Theme) view.layout.Measurement {
        const self: *NumberLeaf = @ptrCast(@alignCast(ptr));
        return .{ .minimum = .{ .width = 3 * field_height, .height = field_height }, .preferred = .{ .width = self.width, .height = field_height } };
    }
    fn annotate(ptr: *anyopaque, annotation: view.Annotation) void {
        const self: *NumberLeaf = @ptrCast(@alignCast(ptr));
        self.annotation = annotation;
    }
    const Steps = struct { decrement: Rect, increment: Rect };
    fn buttons(bounds: Rect) Steps {
        const width = @min(bounds.width / 4, bounds.height);
        return .{ .decrement = .{ .x = bounds.x, .y = bounds.y, .width = width, .height = bounds.height }, .increment = .{ .x = bounds.x + bounds.width - width, .y = bounds.y, .width = width, .height = bounds.height } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *NumberLeaf = @ptrCast(@alignCast(ptr));
        const palette = frame.currentTheme().palette;
        const focused = focusedOn(frame, id);
        const steps = buttons(bounds);
        try frame.addControl(id, bounds, .{ .enabled = self.enabled, .focus_rect = bounds, .range = .{ .spec = self.range, .track = bounds, .kind = .stepper, .step_buttons = .{ .decrement = steps.decrement, .increment = steps.increment } } });
        const name = if (self.name_len > 0) self.name[0..self.name_len] else self.annotation.name;
        try frame.semantic(.{ .id = id, .role = .stepper, .name = name, .value = self.edit.text(), .description = self.annotation.description, .invalid = self.annotation.invalid, .required = self.annotation.required, .bounds = bounds, .enabled = self.enabled, .focused = focused and self.enabled, .range_value = self.value, .range_minimum = self.range.minimum, .range_maximum = self.range.maximum, .range_small_change = self.range.smallChange(), .range_large_change = self.range.largeChange() });
        paintField(frame, bounds, focused, self.enabled);
        const text_color = if (self.enabled) palette.text else palette.disabled_text;
        centered(frame, steps.decrement, "−", if (!self.enabled or self.value <= self.range.minimum) palette.disabled_accent else text_color, .{});
        centered(frame, steps.increment, "+", if (!self.enabled or self.value >= self.range.maximum) palette.disabled_accent else text_color, .{});
        const left = steps.decrement.x + steps.decrement.width;
        paintEdit(frame, .{ .x = left, .y = bounds.y, .width = @max(0, steps.increment.x - left), .height = bounds.height }, &self.edit, focused and self.enabled, self.enabled);
    }
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *NumberLeaf = @ptrCast(@alignCast(ptr));
        const press = switch (event) {
            .key => |value| value,
            // A press focuses the field or steps it in the Context.
            else => return false,
        };
        if (self.edit.key(press)) |changed| {
            if (changed) self.typed = true;
            self.editing = true;
            return true;
        }
        if (!plain(press)) return false;
        switch (press.key) {
            .enter => {
                // The value as typed shows formatted again.
                self.editing = false;
                return true;
            },
            .escape => {
                self.editing = false;
                self.revert = true;
                return true;
            },
            else => {},
        }
        const text: []const u8 = if (digitOf(press)) |digit| (&[_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" })[digit] else switch (press.key) {
            .minus, .subtract => if (press.modifiers.shift) return false else "-",
            .period => if (press.modifiers.shift) return false else ".",
            .comma => if (press.modifiers.shift) return false else ",",
            .decimal => self.decimal[0..self.decimal_len],
            else => return false,
        };
        if (!self.editing) {
            // Typing into a field showing a value replaces it.
            self.edit.set("");
            self.editing = true;
        }
        if (self.edit.insert(text)) self.typed = true;
        return true;
    }
};

/// Decimals of `step`, as 2 for 0.25; null for a step of zero.
fn decimalsOf(value: f64) ?u8 {
    if (value == 0) return null;
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return null;
    if (std.mem.indexOfScalar(u8, text, 'e') != null) return i18n.number.max_fraction_digits;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return 0;
    return @intCast(@min(text.len - dot - 1, i18n.number.max_fraction_digits));
}
fn roundTo(value: f64, decimals: ?u8) f64 {
    const places = decimals orelse return value;
    const scale = std.math.pow(f64, 10, @floatFromInt(places));
    const rounded = @round(value * scale) / scale;
    return if (std.math.isFinite(rounded)) rounded else value;
}

/// A text field editing `value` as a number between `range.minimum` and
/// `range.maximum` in the region's digits and separators, with buttons
/// that step it by `range.step`, as Up and Down do (Page Up and Page Down
/// by `range.page_step`). Digits, the minus sign and the decimal separator
/// typed apply as soon as the text is a number in range, rounded to the
/// decimals of the step; the text shows formatted again on Enter or once
/// the field loses focus, and Escape restores it. Announced as a spin
/// button. True when `value` changed.
pub fn numberInput(v: *View, state: *NumberInput, value: *f64, range: view.Range, options: NumberOptions) Error!bool {
    range.validate() catch return error.InvalidRange;
    if (!std.math.isFinite(value.*)) return error.InvalidValue;
    const leaf = &state.leaf;
    const locale = &options.region.locale;
    const decimals = decimalsOf(range.step);
    var changed = false;
    const set = struct {
        fn apply(target: *f64, next: f64, spec: view.Range, places: ?u8, out: *bool) void {
            const bounded = roundTo(std.math.clamp(next, spec.minimum, spec.maximum), places);
            if (bounded == target.*) return;
            target.* = bounded;
            out.* = true;
        }
    }.apply;
    leaf.range = range;
    leaf.width = options.width;
    const symbols = i18n.number.symbolsFor(locale);
    leaf.decimal_len = @min(symbols.decimal.len, leaf.decimal.len);
    @memcpy(leaf.decimal[0..leaf.decimal_len], symbols.decimal[0..leaf.decimal_len]);
    leaf.name_len = @min(options.style.name.len, leaf.name.len);
    @memcpy(leaf.name[0..leaf.name_len], options.style.name[0..leaf.name_len]);
    if (leaf.typed) {
        leaf.typed = false;
        if (i18n.number.parseFloat(locale, leaf.edit.text())) |typed| {
            if (typed >= range.minimum and typed <= range.maximum) set(value, typed, range, decimals, &changed);
        } else |_| {}
    }
    if (leaf.revert) {
        leaf.revert = false;
        leaf.editing = false;
    }

    try v.embed(leaf.embed(), options.style);
    const node = lastNode(v);
    leaf.id = node.id;
    leaf.enabled = node.style.enabled;
    if (v.takeEvent(node.id)) |event| if (event == .value and leaf.enabled) {
        const next = range.apply(value.*, event.value.change) catch return error.InvalidValue;
        set(value, next, range, decimals, &changed);
        leaf.editing = false;
    };
    if (v.focus == null or v.focus.? != node.id) leaf.editing = false;
    value.* = std.math.clamp(value.*, range.minimum, range.maximum);
    leaf.value = value.*;
    if (!leaf.editing) {
        var buffer: [max_edit]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        const places = decimals orelse 6;
        i18n.number.formatFloat(&out, locale, value.*, .{ .min_fraction = if (decimals) |d| d else 0, .max_fraction = places, .grouping = false }) catch {};
        leaf.edit.set(out.buffered());
    }
    return changed;
}

// ----------------------------------------------------------- color picker

/// A color offered by a picker, named for assistive technology and its
/// tooltip.
pub const Swatch = struct { name: []const u8, color: Rgba };
pub const default_swatches = [_]Swatch{
    .{ .name = "Red", .color = Rgba.rgb(0xef4444) },    .{ .name = "Orange", .color = Rgba.rgb(0xf97316) },
    .{ .name = "Yellow", .color = Rgba.rgb(0xeab308) }, .{ .name = "Green", .color = Rgba.rgb(0x22c55e) },
    .{ .name = "Teal", .color = Rgba.rgb(0x14b8a6) },   .{ .name = "Blue", .color = Rgba.rgb(0x3b82f6) },
    .{ .name = "Indigo", .color = Rgba.rgb(0x6366f1) }, .{ .name = "Purple", .color = Rgba.rgb(0xa855f7) },
    .{ .name = "Pink", .color = Rgba.rgb(0xec4899) },   .{ .name = "Brown", .color = Rgba.rgb(0x92400e) },
    .{ .name = "Gray", .color = Rgba.rgb(0x71717a) },   .{ .name = "Black", .color = Rgba.rgb(0x000000) },
};
/// Swatches one picker shows at most.
pub const max_swatches = 24;

pub const ColorOptions = struct {
    texts: Texts = .{},
    swatches: []const Swatch = &default_swatches,
    /// Width of the picker's column.
    width: f32 = 240,
    style: view.Style = .{},
};
pub const ColorPicker = struct {
    /// The color as the picker keeps it, and the color it last set or saw.
    hsva: Hsva = .{},
    last: ?Rgba = null,
    square: Square = .{},
    hue: Channel = .{ .kind = .hue },
    alpha: Channel = .{ .kind = .alpha },
    preview: Preview = .{},
    hex: HexLeaf = .{},
    swatches: [max_swatches]SwatchLeaf = @splat(.{}),
    strings: Strings(1024) = .{},
};

const square_height: f32 = 160;
const channel_height: f32 = 18;
const ring: f32 = 14;

const Square = struct {
    id: u64 = 0,
    enabled: bool = true,
    hsva: Hsva = .{},
    name: []const u8 = "",
    value: []const u8 = "",
    pending: ?Hsva = null,
    /// The square's arranged size, which presses are measured against.
    width: f32 = 0,
    height: f32 = 0,

    fn embed(self: *Square) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .focusable = true, .input = input };
    }
    fn measure(_: *anyopaque, _: Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 80, .height = square_height }, .preferred = .{ .width = 240, .height = square_height } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *Square = @ptrCast(@alignCast(ptr));
        const focused = focusedOn(frame, id);
        const hue = (Hsva{ .h = self.hsva.h, .s = 1, .v = 1 }).rgba().color();
        const white: ui.Color = .{ .r = 255, .g = 255, .b = 255 };
        frame.gradientRect(bounds, 4, .{ .linear = .{ .start = .{ .x = bounds.x, .y = bounds.y }, .end = .{ .x = bounds.x + bounds.width, .y = bounds.y }, .stops = &.{ .{ .offset = 0, .color = white }, .{ .offset = 1, .color = hue } } } });
        frame.gradientRect(bounds, 4, .{ .linear = .{ .start = .{ .x = bounds.x, .y = bounds.y }, .end = .{ .x = bounds.x, .y = bounds.y + bounds.height }, .stops = &.{ .{ .offset = 0, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 0 } } } } });
        const cx = bounds.x + bounds.width * @as(f32, @floatCast(self.hsva.s));
        const cy = bounds.y + bounds.height * @as(f32, @floatCast(1 - self.hsva.v));
        const mark: Rect = .{ .x = cx - ring / 2, .y = cy - ring / 2, .width = ring, .height = ring };
        frame.strokeRect(inset(mark, -1), ring / 2 + 1, 1, .{ .r = 0, .g = 0, .b = 0, .a = 80 });
        frame.strokeRect(mark, ring / 2, 2, white);
        if (focused) frame.strokeRect(inset(bounds, -2), 6, 2, ui.Color.rgb(frame.currentTheme().palette.focus));
        try frame.semantic(.{ .id = id, .role = .slider, .name = self.name, .value = self.value, .bounds = bounds, .enabled = self.enabled, .focused = focused, .range_value = @round(self.hsva.s * 100), .range_minimum = 0, .range_maximum = 100, .range_small_change = 1, .range_large_change = 10 });
    }
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Square = @ptrCast(@alignCast(ptr));
        var next = self.pending orelse self.hsva;
        switch (event) {
            // A press picks the point under it, and the captured drag
            // follows the pointer, held to the square's edges.
            .pointer_down, .pointer_drag => {
                const point = if (event == .pointer_down) event.pointer_down.position else event.pointer_drag.position;
                // The square's size is the leaf's; input points are local.
                if (self.width <= 0 or self.height <= 0) return true;
                next.s = std.math.clamp(point.x / self.width, 0, 1);
                next.v = std.math.clamp(1 - point.y / self.height, 0, 1);
            },
            .key => |press| {
                if (!plain(press)) return false;
                const amount: f64 = if (press.modifiers.shift) 0.1 else 0.01;
                switch (press.key) {
                    .right => next.s += amount,
                    .left => next.s -= amount,
                    .up => next.v += amount,
                    .down => next.v -= amount,
                    else => return false,
                }
            },
            else => return false,
        }
        self.pending = next.clamped();
        return true;
    }
    fn place(ptr: *anyopaque, _: u64, bounds: Rect) void {
        const self: *Square = @ptrCast(@alignCast(ptr));
        self.width = bounds.width;
        self.height = bounds.height;
    }
};

const Channel = struct {
    kind: enum { hue, alpha },
    id: u64 = 0,
    enabled: bool = true,
    hsva: Hsva = .{},
    name: []const u8 = "",

    fn spec(self: *const Channel) view.Range {
        return if (self.kind == .hue) .{ .minimum = 0, .maximum = 360, .step = 1, .page_step = 30 } else .{ .minimum = 0, .maximum = 1, .step = 0.01, .page_step = 0.1 };
    }
    fn value(self: *const Channel) f64 {
        return if (self.kind == .hue) @round(self.hsva.h) else @round(self.hsva.a * 100) / 100;
    }
    fn embed(self: *Channel) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint };
    }
    fn measure(_: *anyopaque, _: Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 80, .height = channel_height }, .preferred = .{ .width = 240, .height = channel_height } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        const theme = frame.currentTheme();
        const focused = focusedOn(frame, id);
        const thumb = bounds.height;
        const track: Rect = .{ .x = bounds.x + thumb / 2, .y = bounds.y + bounds.height / 2, .width = @max(0, bounds.width - thumb), .height = 0 };
        const spec_value = self.spec();
        try frame.addControl(id, bounds, .{ .enabled = self.enabled, .focus_rect = bounds, .range = .{ .spec = spec_value, .track = track, .kind = .slider } });
        try frame.semantic(.{ .id = id, .role = .slider, .name = self.name, .bounds = bounds, .enabled = self.enabled, .focused = focused and self.enabled, .range_value = self.value(), .range_minimum = spec_value.minimum, .range_maximum = spec_value.maximum, .range_small_change = spec_value.smallChange(), .range_large_change = spec_value.largeChange() });
        const bar: Rect = .{ .x = bounds.x, .y = bounds.y + 3, .width = bounds.width, .height = @max(0, bounds.height - 6) };
        const start: ui.layout.Point = .{ .x = bar.x, .y = bar.y };
        const end: ui.layout.Point = .{ .x = bar.x + bar.width, .y = bar.y };
        if (self.kind == .hue) {
            const hues = [_]u32{ 0xff0000, 0xffff00, 0x00ff00, 0x00ffff, 0x0000ff, 0xff00ff, 0xff0000 };
            var stops: [hues.len]ui.commands.brushes.Stop = undefined;
            for (&stops, hues, 0..) |*stop, hue, index| stop.* = .{ .offset = @as(f32, @floatFromInt(index)) / 6, .color = ui.Color.rgb(hue) };
            frame.gradientRect(bar, bar.height / 2, .{ .linear = .{ .start = start, .end = end, .stops = &stops } });
        } else {
            try frame.pushClip(bar);
            checkers(frame, bar, bar.height / 2);
            try frame.popClip();
            var opaque_color = (Hsva{ .h = self.hsva.h, .s = self.hsva.s, .v = self.hsva.v }).rgba().color();
            var clear = opaque_color;
            clear.a = 0;
            opaque_color.a = 255;
            frame.gradientRect(bar, 0, .{ .linear = .{ .start = start, .end = end, .stops = &.{ .{ .offset = 0, .color = clear }, .{ .offset = 1, .color = opaque_color } } } });
        }
        const range = spec_value.maximum - spec_value.minimum;
        const amount: f32 = @floatCast((self.value() - spec_value.minimum) / range);
        const x = track.x + track.width * amount;
        const knob: Rect = .{ .x = x - thumb / 2, .y = bounds.y, .width = thumb, .height = thumb };
        frame.roundedRect(inset(knob, -1), thumb / 2 + 1, .{ .r = 0, .g = 0, .b = 0, .a = 80 });
        frame.roundedRect(knob, thumb / 2, .{ .r = 255, .g = 255, .b = 255 });
        if (focused) frame.strokeRect(inset(knob, -2), thumb / 2 + 2, 2, ui.Color.rgb(theme.palette.focus));
    }
};

const Preview = struct {
    color: Rgba = .{ .r = 0, .g = 0, .b = 0 },
    fn embed(self: *Preview) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint };
    }
    fn measure(_: *anyopaque, _: Theme) view.layout.Measurement {
        const side: Size = .{ .width = 32, .height = 32 };
        return .{ .minimum = side, .preferred = side };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, bounds: Rect) anyerror!void {
        const self: *Preview = @ptrCast(@alignCast(ptr));
        try frame.pushClip(bounds);
        checkers(frame, bounds, 6);
        frame.roundedRect(bounds, 0, self.color.color());
        try frame.popClip();
        frame.strokeRect(bounds, 4, 1, ui.Color.rgb(frame.currentTheme().palette.border));
    }
};

const HexLeaf = struct {
    id: u64 = 0,
    enabled: bool = true,
    edit: Edit = .{},
    editing: bool = false,
    typed: bool = false,
    name: []const u8 = "",

    fn embed(self: *HexLeaf) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .focusable = true, .input = input };
    }
    fn measure(_: *anyopaque, _: Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 100, .height = field_height }, .preferred = .{ .width = 120, .height = field_height } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *HexLeaf = @ptrCast(@alignCast(ptr));
        const focused = focusedOn(frame, id);
        paintField(frame, bounds, focused, self.enabled);
        paintEdit(frame, .{ .x = bounds.x + field_pad, .y = bounds.y, .width = @max(0, bounds.width - 2 * field_pad), .height = bounds.height }, &self.edit, focused, self.enabled);
        // Typed from keys only, so assistive technology reads it but does
        // not set it.
        try frame.semantic(.{ .id = id, .role = .text_box, .name = self.name, .value = self.edit.text(), .bounds = bounds, .enabled = self.enabled, .focused = focused, .read_only = true });
    }
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *HexLeaf = @ptrCast(@alignCast(ptr));
        const press = switch (event) {
            .key => |value| value,
            .pointer_down => return true,
            else => return false,
        };
        if (self.edit.key(press)) |changed| {
            if (changed) self.typed = true;
            self.editing = true;
            return true;
        }
        if (!plain(press)) return false;
        if (press.key == .enter or press.key == .escape) {
            self.editing = false;
            return true;
        }
        const name = @tagName(press.key);
        const text: []const u8 = if (press.key == .digit3 and press.modifiers.shift)
            "#"
        else if (digitOf(press)) |digit|
            (&[_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" })[digit]
        else if (name.len == 1 and name[0] >= 'a' and name[0] <= 'f')
            name
        else
            return false;
        self.editing = true;
        if (self.edit.insert(text)) self.typed = true;
        return true;
    }
};

const SwatchLeaf = struct {
    color: Rgba = .{ .r = 0, .g = 0, .b = 0 },
    name: []const u8 = "",
    chosen: bool = false,
    enabled: bool = true,

    fn embed(self: *SwatchLeaf) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint };
    }
    fn measure(_: *anyopaque, _: Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 20, .height = 22 }, .preferred = .{ .width = 32, .height = 22 } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *SwatchLeaf = @ptrCast(@alignCast(ptr));
        const palette = frame.currentTheme().palette;
        try frame.addControl(id, bounds, .{ .enabled = self.enabled });
        const focused = focusedOn(frame, id);
        try frame.semantic(.{ .id = id, .role = .button, .name = self.name, .bounds = bounds, .enabled = self.enabled, .focused = focused and self.enabled, .checked = self.chosen });
        frame.roundedRect(bounds, 4, self.color.color());
        if (self.chosen) frame.strokeRect(bounds, 4, 2, ui.Color.rgb(palette.text));
        if (focused) frame.strokeRect(inset(bounds, -3), 6, 2, ui.Color.rgb(palette.focus));
    }
};

/// A picker of `color`: a square choosing the saturation, across, and the
/// brightness, up, of the hue its slider chooses below it, a slider of
/// opacity, the color in hex, which the person may type, and swatches of
/// common colors. The arrows move across the square while it has focus,
/// by tenths with Shift; the sliders follow pointer drags and the keys.
/// The picker keeps the hue of grays it set. True when `color` changed.
pub fn colorPicker(v: *View, state: *ColorPicker, color: *Rgba, options: ColorOptions) Error!bool {
    if (options.swatches.len > max_swatches) return error.TooManyItems;
    var changed = false;
    const set = struct {
        fn apply(picker: *ColorPicker, target: *Rgba, next: Hsva, out: *bool) void {
            const value = next.clamped();
            picker.hsva = value;
            const result = value.rgba();
            if (!result.eql(target.*)) {
                target.* = result;
                out.* = true;
            }
            picker.last = target.*;
        }
    }.apply;
    // The application set another color.
    if (state.last == null or !state.last.?.eql(color.*)) {
        state.hsva = Hsva.from(color.*);
        state.last = color.*;
    }
    if (state.square.pending) |next| {
        state.square.pending = null;
        set(state, color, .{ .h = state.hsva.h, .s = next.s, .v = next.v, .a = state.hsva.a }, &changed);
    }
    if (state.hex.typed) {
        state.hex.typed = false;
        if (Rgba.parseHex(state.hex.edit.text())) |typed| set(state, color, Hsva.from(typed), &changed);
    }
    state.strings.reset();

    var column = options.style;
    if (column.gap == 0) column.gap = 10;
    if (column.width == null) column.width = options.width;
    try v.column(column);
    // The square of saturation and brightness.
    try v.embed(state.square.embed(), .{});
    var node = lastNode(v);
    state.square.id = node.id;
    state.square.enabled = node.style.enabled;
    if (v.takeEvent(node.id)) |event| if (event == .value and node.style.enabled) {
        const range: view.Range = .{ .minimum = 0, .maximum = 100, .step = 1 };
        const next = range.apply(@round(state.hsva.s * 100), event.value.change) catch return error.InvalidValue;
        set(state, color, .{ .h = state.hsva.h, .s = next / 100, .v = state.hsva.v, .a = state.hsva.a }, &changed);
    };
    // The hue, and the opacity.
    inline for (.{ &state.hue, &state.alpha }) |slider| {
        try v.embed(slider.embed(), .{});
        node = lastNode(v);
        slider.id = node.id;
        slider.enabled = node.style.enabled;
        if (v.takeEvent(node.id)) |event| if (event == .value and node.style.enabled) {
            slider.hsva = state.hsva;
            const next = slider.spec().apply(slider.value(), event.value.change) catch return error.InvalidValue;
            var target = state.hsva;
            if (slider.kind == .hue) target.h = next else target.a = next;
            set(state, color, target, &changed);
        };
    }
    // The color, and its hex.
    try v.row(.{ .gap = 8, .alignment = .center });
    try v.embed(state.preview.embed(), .{});
    try v.embed(state.hex.embed(), .{ .grow = 1 });
    node = lastNode(v);
    state.hex.id = node.id;
    state.hex.enabled = node.style.enabled;
    try v.end();
    // Swatches.
    try v.grid(&swatch_tracks, .{ .gap = 6 });
    for (options.swatches, state.swatches[0..options.swatches.len]) |swatch, *leaf| {
        leaf.name = try state.strings.add(swatch.name);
        leaf.color = swatch.color;
        try v.embed(leaf.embed(), .{});
        try v.tooltip(swatch.name);
        node = lastNode(v);
        leaf.enabled = node.style.enabled;
        if (v.takeEvent(node.id) != null and leaf.enabled) set(state, color, Hsva.from(swatch.color), &changed);
    }
    try v.end();
    try v.end();

    // What the leaves paint, from the color as it now is.
    state.square.hsva = state.hsva;
    state.hue.hsva = state.hsva;
    state.alpha.hsva = state.hsva;
    state.preview.color = color.*;
    state.square.name = try state.strings.add(options.texts.saturation);
    state.square.value = try state.strings.print("{d}%, {d}%", .{ @as(i64, @intFromFloat(@round(state.hsva.s * 100))), @as(i64, @intFromFloat(@round(state.hsva.v * 100))) });
    state.hue.name = try state.strings.add(options.texts.hue);
    state.alpha.name = try state.strings.add(options.texts.opacity);
    state.hex.name = try state.strings.add(options.texts.hex);
    for (options.swatches, state.swatches[0..options.swatches.len]) |swatch, *leaf| leaf.chosen = swatch.color.eql(color.*);
    if (v.focus == null or v.focus.? != state.hex.id) state.hex.editing = false;
    if (!state.hex.editing) {
        var buffer: [9]u8 = undefined;
        state.hex.edit.set(color.formatHex(&buffer));
    }
    return changed;
}
const swatch_tracks = [_]view.Track{ view.Track.fraction(1), view.Track.fraction(1), view.Track.fraction(1), view.Track.fraction(1), view.Track.fraction(1), view.Track.fraction(1) };

pub const ColorWellOptions = struct {
    picker: ColorOptions = .{},
    /// Style of the well; `Style.name` names it.
    style: view.Style = .{},
};
pub const ColorWell = struct {
    /// Whether the picker is open.
    open: bool = false,
    picker: ColorPicker = .{},
    leaf: WellLeaf = .{},
};
const WellLeaf = struct {
    color: Rgba = .{ .r = 0, .g = 0, .b = 0 },
    open: bool = false,
    enabled: bool = true,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    hex: [9]u8 = undefined,
    hex_len: usize = 0,
    annotation: view.Annotation = .{},

    fn embed(self: *WellLeaf) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .annotate = annotate };
    }
    fn measure(_: *anyopaque, _: Theme) view.layout.Measurement {
        const extent: Size = .{ .width = 52, .height = 32 };
        return .{ .minimum = extent, .preferred = extent };
    }
    fn annotate(ptr: *anyopaque, annotation: view.Annotation) void {
        const self: *WellLeaf = @ptrCast(@alignCast(ptr));
        self.annotation = annotation;
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *WellLeaf = @ptrCast(@alignCast(ptr));
        const theme = frame.currentTheme();
        const palette = theme.palette;
        const focused = focusedOn(frame, id);
        try frame.addControl(id, bounds, .{ .enabled = self.enabled });
        const name = if (self.name_len > 0) self.name[0..self.name_len] else self.annotation.name;
        // Expanded while the picker is open, as a combo box with its list.
        try frame.semantic(.{ .id = id, .role = .color_well, .name = name, .value = self.hex[0..self.hex_len], .description = self.annotation.description, .bounds = bounds, .enabled = self.enabled, .focused = focused and self.enabled, .checked = self.open, .read_only = true });
        frame.roundedRect(bounds, 4, ui.Color.rgb(if (!self.enabled) palette.disabled_border else if (focused) palette.focus else palette.border));
        frame.roundedRect(inset(bounds, theme.metrics.border / 2), 3, ui.Color.rgb(if (self.open) palette.pressed else palette.control));
        const swatch = inset(bounds, 6);
        try frame.pushClip(swatch);
        checkers(frame, swatch, 5);
        frame.roundedRect(swatch, 0, self.color.color());
        try frame.popClip();
    }
};

/// A swatch of `color` that opens a color picker below it: a press, Enter
/// or Space opens it with focus in the picker, and Escape or a press
/// outside closes it. Assistive technology sees a color well whose value
/// is the color in hex, expanded while the picker is open. True when
/// `color` changed.
pub fn colorWell(v: *View, state: *ColorWell, color: *Rgba, options: ColorWellOptions) Error!bool {
    const leaf = &state.leaf;
    try v.embed(leaf.embed(), options.style);
    const node = lastNode(v);
    leaf.enabled = node.style.enabled;
    if (v.takeEvent(node.id) != null and leaf.enabled) state.open = !state.open;
    var changed = false;
    if (try v.popover(&state.open, .{}, .{ .name = options.style.name })) {
        changed = try colorPicker(v, &state.picker, color, options.picker);
    }
    try v.end();
    leaf.open = state.open;
    leaf.color = color.*;
    leaf.name_len = @min(options.style.name.len, leaf.name.len);
    @memcpy(leaf.name[0..leaf.name_len], options.style.name[0..leaf.name_len]);
    leaf.hex_len = color.formatHex(&leaf.hex).len;
    return changed;
}

test {
    _ = @import("pickers_tests.zig");
}
