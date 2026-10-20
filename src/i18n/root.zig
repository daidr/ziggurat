//! Optional localization module: locales and fallback, message catalogs,
//! plural rules, number and date formatting, number parsing, week
//! conventions and pseudolocalization. Pure Zig with explicit allocation;
//! it owns no App, window, thread or global state. Only `locale.system`
//! reads the operating system.

const std = @import("std");

pub const locale = @import("locale.zig");
pub const plural = @import("plural.zig");
pub const number = @import("number.zig");
pub const date = @import("date.zig");
pub const week = @import("week.zig");
pub const message = @import("message.zig");
pub const pseudo = @import("pseudo.zig");
pub const catalog = @import("catalog.zig");

pub const Locale = locale.Locale;
pub const Direction = locale.Direction;
pub const Catalog = catalog.Catalog;
pub const Entry = catalog.Entry;
pub const Localizer = catalog.Localizer;
pub const Instant = date.Instant;
pub const Arg = message.Arg;
pub const Value = message.Value;
pub const args = message.args;

test {
    std.testing.refAllDecls(@This());
    _ = locale;
    _ = plural;
    _ = number;
    _ = date;
    _ = week;
    _ = message;
    _ = pseudo;
    _ = catalog;
}
