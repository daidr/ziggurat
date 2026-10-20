const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const i18n = @import("ziggurat_i18n");
const pickers = @import("pickers.zig");

const View = view.View;
const Harness = view.Harness;
const Date = pickers.Date;
const testing = std.testing;

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};
const Storage = view.Storage(256, 4096);

fn press(key: z.KeyCode) z.KeyInput {
    return .{ .key = key };
}
fn locale(comptime tag: []const u8) i18n.Locale {
    return i18n.Locale.parse(tag) catch unreachable;
}

test "dates step by days and months within the calendar" {
    const day: Date = .{ .year = 2024, .month = 1, .day = 31 };
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, day.addMonths(1));
    try testing.expectEqual(Date{ .year = 2023, .month = 2, .day = 28 }, day.addMonths(-11));
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 1 }, day.addDays(1));
    try testing.expectEqual(@as(u3, 3), day.weekday());
    try testing.expectEqual(Date.last, Date.last.addDays(5));
    try testing.expectEqual(Date.first, Date.first.addMonths(-3));
    try testing.expectEqual(Date{ .year = 1970, .month = 1, .day = 1 }, Date.fromDays(0));
    try testing.expect(!(Date{ .year = 2023, .month = 2, .day = 29 }).valid());
}

const CalendarApp = struct {
    state: pickers.Calendar = .{},
    date: Date = .{ .year = 2024, .month = 3, .day = 15 },
    options: pickers.CalendarOptions = .{ .region = .{ .locale = locale("en-US") } },
    changes: usize = 0,
    fn build(self: *CalendarApp, v: *View) anyerror!void {
        try v.column(.{});
        if (try pickers.calendar(v, &self.state, &self.date, self.options)) self.changes += 1;
        try v.end();
    }
};

fn gridOf(h: *const Harness) !*const view.Node {
    return h.find(.{ .kind = .embed, .nth = 0 });
}

test "calendar shows six weeks from the region's first day and moves by keys" {
    var storage: Storage = .{};
    var app: CalendarApp = .{};
    var h = Harness.init(&app, CalendarApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqualStrings("March 2024", (try h.find(.{ .kind = .text })).text);
    // US weeks start on Sunday: March 2024 begins on a Friday.
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 25 }, app.state.grid.start);
    try testing.expectEqualStrings("Sun", app.state.grid.weekdays[0]);

    try h.focus(.{ .kind = .embed });
    try testing.expect(try h.key(press(.right)));
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 16 }, app.date);
    try testing.expect(try h.key(press(.down)));
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 23 }, app.date);
    try testing.expect(try h.key(press(.end)));
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 31 }, app.date);
    try testing.expect(try h.key(press(.page_down)));
    try testing.expectEqual(Date{ .year = 2024, .month = 4, .day = 30 }, app.date);
    try testing.expectEqualStrings("April 2024", (try h.find(.{ .kind = .text })).text);
    try testing.expect(try h.key(press(.home)));
    try testing.expectEqual(Date{ .year = 2024, .month = 4, .day = 1 }, app.date);
    try testing.expect(try h.key(.{ .key = .page_up, .modifiers = .{ .shift = true } }));
    try testing.expectEqual(Date{ .year = 2023, .month = 4, .day = 1 }, app.date);
    // Focus stays on the grid.
    try testing.expectEqual((try gridOf(&h)).id, h.focused().?.id);
    try testing.expectEqualStrings("Saturday, April 1, 2023", h.announcement().?);

    // The month buttons move the month and choose the same day.
    try h.click(.{ .kind = .nav_button, .nth = 1 });
    try testing.expectEqual(Date{ .year = 2023, .month = 5, .day = 1 }, app.date);
}

test "calendar presses choose days and skip disabled ones" {
    var storage: Storage = .{};
    var app: CalendarApp = .{};
    const Weekends = struct {
        fn call(_: ?*const anyopaque, day: Date) bool {
            return day.weekday() == 0 or day.weekday() == 6;
        }
    };
    app.options.minimum = .{ .year = 2024, .month = 3, .day = 4 };
    app.options.maximum = .{ .year = 2024, .month = 3, .day = 28 };
    app.options.disabled = .{ .call = Weekends.call };
    var h = Harness.init(&app, CalendarApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const grid = try gridOf(&h);
    const at = struct {
        fn point(g: *const view.Node, index: usize) [2]f32 {
            const cell = (pickers.Calendar{}).grid.cell(index);
            return .{ g.bounds.x + cell.x + 4, g.bounds.y + cell.y + 4 };
        }
    }.point;
    // Row 2, Wednesday: March 13.
    var p = at(grid, 7 * 2 + 3);
    try h.clickAt(p[0], p[1]);
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 13 }, app.date);
    try testing.expectEqual(grid.id, h.focused().?.id);
    // Saturday March 16 and Friday March 1 cannot be chosen.
    p = at(grid, 7 * 2 + 6);
    try h.clickAt(p[0], p[1]);
    p = at(grid, 5);
    try h.clickAt(p[0], p[1]);
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 13 }, app.date);
    // Both month buttons are off at the range's only month.
    try testing.expect(!(try h.find(.{ .kind = .nav_button, .nth = 0 })).style.enabled);
    try testing.expect(!(try h.find(.{ .kind = .nav_button, .nth = 1 })).style.enabled);
    // Keys stop at the range's ends; Home lands on the minimum.
    try testing.expect(try h.key(press(.home)));
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 4 }, app.date);
    try testing.expect(try h.key(press(.up)));
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 4 }, app.date);
    // A day assistive technology invokes by its id.
    try h.send(.{ .action = pickers.partId(grid.id, @bitCast((Date{ .year = 2024, .month = 3, .day = 20 }).days())) });
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 20 }, app.date);
}

test "calendar weeks and titles follow the locale" {
    var storage: Storage = .{};
    var app: CalendarApp = .{ .options = .{ .region = .{ .locale = locale("de-DE") }, .week_numbers = true } };
    var h = Harness.init(&app, CalendarApp.build, storage.buffers(), .{});
    try h.render();
    try testing.expectEqualStrings("März 2024", (try h.find(.{ .kind = .text })).text);
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 26 }, app.state.grid.start);
    try testing.expectEqualStrings("9", app.state.grid.weeks[0]);
    app.options = .{ .region = .{ .locale = locale("ja-JP") } };
    try h.render();
    try testing.expectEqualStrings("2024年3月", (try h.find(.{ .kind = .text })).text);
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 25 }, app.state.grid.start);
    app.options = .{ .region = .{ .locale = locale("en-US"), .first_weekday = 1 } };
    try h.render();
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 26 }, app.state.grid.start);
}

const DateApp = struct {
    state: pickers.DateInput = .{},
    date: Date = .{ .year = 2024, .month = 3, .day = 15 },
    fn build(self: *DateApp, v: *View) anyerror!void {
        try v.column(.{ .padding = .{ .top = 20, .left = 20 } });
        _ = try pickers.dateInput(v, &self.state, &self.date, .{ .calendar = .{ .region = .{ .locale = locale("en-US") } }, .style = .{ .name = "Due" } });
        try v.end();
    }
};

test "date input opens a calendar that chooses and returns focus" {
    var storage: Storage = .{};
    var app: DateApp = .{};
    var h = Harness.init(&app, DateApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const field = try h.find(.{ .kind = .popup_button });
    try testing.expectEqualStrings("3/15/24", field.text);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .embed }));

    try h.click(.{ .kind = .popup_button });
    try testing.expect(app.state.open);
    try h.render();
    // Focus starts on the days.
    try testing.expectEqual(view.Kind.embed, h.focused().?.kind);
    const grid = try h.find(.{ .kind = .embed });
    try testing.expect(grid.bounds.y > field.bounds.y + field.bounds.height);
    // Keys move without choosing; Enter chooses and closes.
    try testing.expect(try h.key(press(.right)));
    try testing.expect(try h.key(press(.page_down)));
    try testing.expectEqual(Date{ .year = 2024, .month = 3, .day = 15 }, app.date);
    try testing.expect(try h.key(press(.enter)));
    try testing.expectEqual(Date{ .year = 2024, .month = 4, .day = 16 }, app.date);
    try testing.expect(!app.state.open);
    try testing.expectEqual(view.Kind.popup_button, h.focused().?.kind);
    try testing.expectEqualStrings("4/16/24", (try h.find(.{ .kind = .popup_button })).text);

    // Enter opens it again; Escape closes it unchanged with focus back.
    try testing.expect(try h.key(press(.enter)));
    try testing.expect(app.state.open);
    try h.render();
    try testing.expectEqual(view.Kind.embed, h.focused().?.kind);
    try testing.expect(try h.key(press(.left)));
    try testing.expect(try h.key(press(.escape)));
    try testing.expect(!app.state.open);
    try testing.expectEqual(Date{ .year = 2024, .month = 4, .day = 16 }, app.date);
    try testing.expectEqual(view.Kind.popup_button, h.focused().?.kind);

    // A press outside closes it.
    try h.click(.{ .kind = .popup_button });
    try testing.expect(app.state.open);
    try testing.expectError(error.NotFound, h.clickAt(600, 460));
    try testing.expect(!app.state.open);
}

const TimeApp = struct {
    state: pickers.TimeInput = .{},
    time: pickers.TimeOfDay = .{ .hour = 15, .minute = 4 },
    region: pickers.Region = .{ .locale = locale("en-US") },
    fn build(self: *TimeApp, v: *View) anyerror!void {
        try v.column(.{});
        _ = try pickers.timeInput(v, &self.state, &self.time, .{ .region = self.region, .style = .{ .name = "Start" } });
        try v.end();
    }
};

test "time input steps and types segments in 12 hours" {
    var storage: Storage = .{};
    var app: TimeApp = .{};
    var h = Harness.init(&app, TimeApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const leaf = &app.state.leaf;
    try testing.expectEqual(@as(usize, 3), leaf.count);
    try testing.expectEqualStrings("3", leaf.texts[0]);
    try testing.expectEqualStrings("04", leaf.texts[1]);
    try testing.expectEqualStrings("PM", leaf.texts[2]);
    try h.focus(.{ .kind = .embed });
    // Hours go round the same half of the day.
    try testing.expect(try h.key(press(.down)));
    try testing.expect(try h.key(press(.down)));
    try testing.expect(try h.key(press(.down)));
    try testing.expect(try h.key(press(.down)));
    try testing.expectEqual(@as(u5, 23), app.time.hour);
    try testing.expect(try h.key(press(.up)));
    try testing.expectEqual(@as(u5, 12), app.time.hour);
    // 1 then 1 types 11 and goes on to the minutes.
    try testing.expect(try h.key(press(.digit1)));
    try testing.expect(try h.key(press(.digit1)));
    try testing.expectEqual(@as(u5, 23), app.time.hour);
    try testing.expectEqual(@as(usize, 1), leaf.active);
    try testing.expect(try h.key(press(.digit5)));
    try testing.expect(try h.key(press(.digit9)));
    try testing.expectEqual(@as(u6, 59), app.time.minute);
    try testing.expect(try h.key(press(.up)));
    try testing.expectEqual(@as(u6, 0), app.time.minute);
    try testing.expectEqual(@as(u5, 23), app.time.hour);
    // The day period by letter; Right stops at the last segment.
    try testing.expect(try h.key(press(.right)));
    try testing.expect(!try h.key(press(.digit1)));
    try testing.expect(!try h.key(press(.x)));
    try testing.expect(try h.key(press(.a)));
    try testing.expectEqual(@as(u5, 11), app.time.hour);
    try testing.expect(try h.key(press(.up)));
    try testing.expectEqual(@as(u5, 23), app.time.hour);
    try testing.expect(!try h.key(press(.right)));
    // Assistive technology sets a segment by its own id.
    try h.send(.{ .value = .{ .id = pickers.partId(leaf.id, 1), .change = .{ .set = 30 } } });
    try testing.expectEqual(@as(u6, 30), app.time.minute);
}

test "time input follows the locale's 24 hours and separators" {
    var storage: Storage = .{};
    var app: TimeApp = .{ .region = .{ .locale = locale("de-DE") } };
    var h = Harness.init(&app, TimeApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const leaf = &app.state.leaf;
    try testing.expectEqual(@as(usize, 2), leaf.count);
    try testing.expectEqualStrings("15", leaf.texts[0]);
    try h.focus(.{ .kind = .embed });
    try testing.expect(try h.key(press(.up)));
    try testing.expect(try h.key(press(.up)));
    try testing.expect(try h.key(press(.up)));
    try testing.expect(try h.key(press(.up)));
    try testing.expect(try h.key(press(.up)));
    try testing.expect(try h.key(press(.up)));
    try testing.expect(try h.key(press(.up)));
    try testing.expect(try h.key(press(.up)));
    try h.render();
    try testing.expectEqual(@as(u5, 23), app.time.hour);
    try testing.expect(try h.key(press(.up)));
    try testing.expectEqual(@as(u5, 0), app.time.hour);
    // 2 can start two digits; 3 cannot, so it goes on to the minutes.
    try testing.expect(try h.key(press(.digit3)));
    try testing.expectEqual(@as(u5, 3), app.time.hour);
    try testing.expectEqual(@as(usize, 1), leaf.active);
    // Shift+Tab goes back to the hours.
    try testing.expect(try h.key(.{ .key = .tab, .modifiers = .{ .shift = true } }));
    try testing.expectEqual(@as(usize, 0), leaf.active);
    // A forced 12-hour cycle and the Korean period before the hours.
    app.region = .{ .locale = locale("ko-KR") };
    try h.render();
    try testing.expect(leaf.order[0] == .period);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings(" h ", pickers.timeLayout("H 'h' mm", &buffer).separator);
    try testing.expect(pickers.timeLayout("a h:mm", &buffer).period_first);
}

const NumberApp = struct {
    state: pickers.NumberInput = .{},
    value: f64 = 1.5,
    range: view.Range = .{ .minimum = -10, .maximum = 10, .step = 0.25 },
    region: pickers.Region = .{ .locale = locale("en-US") },
    fn build(self: *NumberApp, v: *View) anyerror!void {
        try v.column(.{});
        _ = try pickers.numberInput(v, &self.state, &self.value, self.range, .{ .region = self.region, .style = .{ .name = "Amount" } });
        _ = try v.button("Other", .{});
        try v.end();
    }
};

fn numberText(app: *const NumberApp) []const u8 {
    return app.state.leaf.edit.text();
}

test "number input steps, types and formats in the locale" {
    var storage: Storage = .{};
    var app: NumberApp = .{};
    var h = Harness.init(&app, NumberApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqualStrings("1.50", numberText(&app));
    try h.focus(.{ .kind = .embed });
    try testing.expect(try h.key(press(.up)));
    try testing.expectEqual(@as(f64, 1.75), app.value);
    try testing.expectEqualStrings("1.75", numberText(&app));
    // Typing replaces the text and applies once it is a number in range.
    try testing.expect(try h.key(press(.minus)));
    try testing.expectEqual(@as(f64, 1.75), app.value);
    try testing.expect(try h.key(press(.digit3)));
    try testing.expect(try h.key(press(.period)));
    try testing.expect(try h.key(press(.digit1)));
    try testing.expect(try h.key(press(.digit2)));
    try testing.expectEqualStrings("-3.12", numberText(&app));
    try testing.expectEqual(@as(f64, -3.12), app.value);
    // Out of range does not apply.
    try testing.expect(try h.key(press(.home)));
    try testing.expect(try h.key(press(.delete)));
    try testing.expectEqual(@as(f64, 3.12), app.value);
    try testing.expect(try h.key(press(.digit5)));
    try testing.expectEqualStrings("53.12", numberText(&app));
    try testing.expectEqual(@as(f64, 3.12), app.value);
    // Enter shows the value formatted again.
    try testing.expect(try h.key(press(.enter)));
    try testing.expectEqualStrings("3.12", numberText(&app));
    // The step buttons are the stepper's; a step clamps to the range.
    try h.send(.{ .value = .{ .id = app.state.leaf.id, .change = .{ .set = 99 } } });
    try testing.expectEqual(@as(f64, 10), app.value);
    try testing.expectEqualStrings("10.00", numberText(&app));
}

test "number input reads German separators and reverts on Escape" {
    var storage: Storage = .{};
    var app: NumberApp = .{ .region = .{ .locale = locale("de-DE") }, .range = .{ .minimum = 0, .maximum = 100000, .step = 0.5 } };
    var h = Harness.init(&app, NumberApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqualStrings("1,5", numberText(&app));
    try h.focus(.{ .kind = .embed });
    try testing.expect(try h.key(press(.digit2)));
    try testing.expect(try h.key(press(.comma)));
    try testing.expect(try h.key(press(.digit5)));
    try testing.expectEqual(@as(f64, 2.5), app.value);
    // Text that is no number keeps the last value; Escape shows it.
    try testing.expect(try h.key(press(.backspace)));
    try testing.expect(try h.key(press(.backspace)));
    try testing.expect(try h.key(press(.backspace)));
    try testing.expectEqualStrings("", numberText(&app));
    try testing.expectEqual(@as(f64, 2), app.value);
    try testing.expect(try h.key(press(.escape)));
    try testing.expectEqualStrings("2,0", numberText(&app));
    // Leaving the field shows the value formatted.
    try testing.expect(try h.key(press(.digit7)));
    try testing.expectEqual(@as(f64, 7), app.value);
    try h.focus(.{ .text = "Other" });
    try testing.expectEqualStrings("7,0", numberText(&app));
}

test "colors convert between hex, RGB and HSV" {
    try testing.expectEqual(pickers.Rgba{ .r = 0xef, .g = 0x44, .b = 0x44 }, pickers.Rgba.parseHex("#EF4444").?);
    try testing.expectEqual(pickers.Rgba{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 }, pickers.Rgba.parseHex("1234").?);
    try testing.expect(pickers.Rgba.parseHex("#12345") == null);
    try testing.expect(pickers.Rgba.parseHex("#gg0000") == null);
    var buffer: [9]u8 = undefined;
    try testing.expectEqualStrings("#3b82f6", pickers.Rgba.rgb(0x3b82f6).formatHex(&buffer));
    try testing.expectEqualStrings("#3b82f680", (pickers.Rgba{ .r = 0x3b, .g = 0x82, .b = 0xf6, .a = 0x80 }).formatHex(&buffer));
    for (pickers.default_swatches) |swatch| try testing.expectEqual(swatch.color, pickers.Hsva.from(swatch.color).rgba());
    const red = pickers.Hsva.from(pickers.Rgba.rgb(0xff0000));
    try testing.expectEqual(@as(f64, 0), red.h);
    try testing.expectEqual(@as(f64, 1), red.s);
    const blue = pickers.Hsva.from(pickers.Rgba.rgb(0x0000ff));
    try testing.expectEqual(@as(f64, 240), blue.h);
}

const ColorApp = struct {
    well: pickers.ColorWell = .{},
    color: pickers.Rgba = pickers.Rgba.rgb(0x3b82f6),
    fn build(self: *ColorApp, v: *View) anyerror!void {
        try v.column(.{ .padding = .{ .top = 10, .left = 10 } });
        _ = try pickers.colorWell(v, &self.well, &self.color, .{ .style = .{ .name = "Fill" } });
        try v.end();
    }
};

test "color well opens a picker whose controls set the color" {
    var storage: Storage = .{};
    var app: ColorApp = .{};
    var h = Harness.init(&app, ColorApp.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 640, .height = 600 } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const well = try h.find(.{ .kind = .embed });
    try h.send(.{ .action = well.id });
    try testing.expect(app.well.open);
    const picker = &app.well.picker;
    // Swatches.
    try h.send(.{ .action = (try h.find(.{ .kind = .embed, .nth = 7 })).id });
    try testing.expectEqual(pickers.Rgba.rgb(0xf97316), app.color);
    try testing.expect(picker.swatches[1].chosen);
    // The hue and opacity sliders.
    try h.send(.{ .value = .{ .id = picker.hue.id, .change = .{ .set = 240 } } });
    try testing.expectEqual(@as(f64, 240), picker.hsva.h);
    try testing.expectEqual(@as(u8, 0xf9), @max(app.color.b, @max(app.color.r, app.color.g)));
    try testing.expect(app.color.b > app.color.r);
    try h.send(.{ .value = .{ .id = picker.alpha.id, .change = .{ .set = 0.5 } } });
    try testing.expectEqual(@as(u8, 128), app.color.a);
    var buffer: [9]u8 = undefined;
    try testing.expectEqualStrings(app.color.formatHex(&buffer), picker.hex.edit.text());
    // The square by keys: right adds saturation, Shift+down takes a tenth
    // of the brightness.
    try h.focus(.{ .kind = .embed, .nth = 1 });
    try testing.expectEqual(picker.square.id, h.focused().?.id);
    const saturation = picker.hsva.s;
    try testing.expect(try h.key(press(.left)));
    try testing.expectApproxEqAbs(saturation - 0.01, picker.hsva.s, 1e-9);
    try testing.expect(try h.key(.{ .key = .down, .modifiers = .{ .shift = true } }));
    try testing.expectApproxEqAbs(@as(f64, 0.876), picker.hsva.v, 0.01);
    // A press in the square's corner makes white, keeping the hue.
    const square = try h.find(.{ .kind = .embed, .nth = 1 });
    try h.clickAt(square.bounds.x, square.bounds.y);
    try testing.expectEqual(pickers.Rgba{ .r = 255, .g = 255, .b = 255, .a = 128 }, app.color);
    try testing.expectEqual(@as(f64, 240), picker.hsva.h);
    // A drag from there follows the pointer past the square's far corner,
    // where it is fully saturated and black.
    try h.drag(square.bounds.x + 1, square.bounds.y + 1, square.bounds.x + square.bounds.width + 40, square.bounds.y + square.bounds.height + 40, 4);
    try testing.expectEqual(@as(f64, 1), picker.hsva.s);
    try testing.expectEqual(@as(f64, 0), picker.hsva.v);
    try testing.expectEqual(pickers.Rgba{ .r = 0, .g = 0, .b = 0, .a = 128 }, app.color);
    try h.clickAt(square.bounds.x, square.bounds.y);
    // Typed hex applies once it is a color.
    try h.focus(.{ .kind = .embed, .nth = 5 });
    try testing.expectEqual(picker.hex.id, h.focused().?.id);
    try testing.expect(try h.key(press(.end)));
    for (0..9) |_| _ = try h.key(press(.backspace));
    try testing.expect(try h.key(.{ .key = .digit3, .modifiers = .{ .shift = true } }));
    try testing.expect(try h.key(press(.digit0)));
    try testing.expect(try h.key(press(.digit0)));
    try testing.expect(try h.key(press(.f)));
    try testing.expectEqual(pickers.Rgba{ .r = 0, .g = 0, .b = 0xff }, app.color);
    try testing.expectEqualStrings("#00f", picker.hex.edit.text());
    // Escape closes the popover with focus back on the well.
    try testing.expect(try h.key(press(.escape)));
    try testing.expect(!app.well.open);
    try testing.expectEqual(well.id, h.focused().?.id);
    try testing.expectEqualStrings("#0000ff", app.well.leaf.hex[0..app.well.leaf.hex_len]);
}

test "popovers flip above an anchor without room below" {
    const window: view.Rect = .{ .x = 0, .y = 0, .width = 400, .height = 300 };
    const anchor: view.Rect = .{ .x = 350, .y = 250, .width = 40, .height = 30 };
    const placed = view.placePopover(window, anchor, .{ .width = 120, .height = 100 }, .{});
    try testing.expect(placed.y + placed.height <= anchor.y);
    try testing.expectEqual(@as(f32, 280), placed.x);
    const below = view.placePopover(window, .{ .x = 10, .y = 10, .width = 40, .height = 30 }, .{ .width = 120, .height = 100 }, .{});
    try testing.expect(below.y >= 40);
    try testing.expectEqual(@as(f32, 10), below.x);
}
