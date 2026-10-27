//! A byte-at-a-time parser for the escape sequences terminals speak: the
//! DEC/ANSI state machine for C0 controls, ESC, CSI, OSC and DCS, with
//! UTF-8 decoding of printable text. It owns no allocation; OSC payloads
//! are collected into caller storage and dropped whole when they overflow.
//! APC strings, which carry Kitty graphics, stream to the handler in
//! pieces, as they can be large.
const std = @import("std");

pub const max_params = 32;
pub const max_intermediates = 2;

/// Parameters of a control sequence. A missing parameter reads as 0;
/// `colon[i]` tells that parameter `i` followed a ':' rather than a ';',
/// as the subparameters of `38:2::r:g:b`.
pub const Params = struct {
    values: [max_params]u16 = @splat(0),
    colon: [max_params]bool = @splat(false),
    len: usize = 0,

    pub fn slice(self: *const Params) []const u16 {
        return self.values[0..self.len];
    }
    /// Parameter `index`, or `default` when it is missing or zero.
    pub fn get(self: *const Params, index: usize, default: u16) u16 {
        if (index >= self.len or self.values[index] == 0) return default;
        return self.values[index];
    }
};

pub const Csi = struct {
    params: Params,
    /// A private marker before the parameters: '?', '>', '<' or '='; 0 when
    /// absent.
    private: u8 = 0,
    intermediates: []const u8,
    final: u8,
};

pub const Esc = struct {
    intermediates: []const u8,
    final: u8,
};

pub const Action = union(enum) {
    print: u21,
    /// A C0 control, or DEL.
    execute: u8,
    csi: Csi,
    esc: Esc,
    /// The payload between OSC and its terminator, borrowed until the
    /// next byte is fed.
    osc: []const u8,
    /// An APC string starts; its payload follows in `apc_data` pieces,
    /// borrowed until the next byte is fed, then `apc_end`: true when the
    /// string ended with ST, false when it was cancelled.
    apc_start,
    apc_data: []const u8,
    apc_end: bool,
};

const State = enum { ground, escape, escape_intermediate, csi_entry, csi_param, csi_intermediate, csi_ignore, osc_string, dcs_passthrough, apc_string, ignore_string };

pub const Parser = struct {
    state: State = .ground,
    params: Params = .{},
    param_started: bool = false,
    private: u8 = 0,
    intermediates: [max_intermediates]u8 = undefined,
    intermediate_len: usize = 0,
    intermediate_overflow: bool = false,
    osc: []u8,
    osc_len: usize = 0,
    osc_overflow: bool = false,
    /// An ESC seen inside a string, waiting for '\\' to end it.
    string_escape: bool = false,
    utf8: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,

    pub fn init(osc_storage: []u8) Parser {
        return .{ .osc = osc_storage };
    }

    /// Feed `bytes`, calling `handler.action(Action)` for each complete
    /// action in order.
    pub fn feed(self: *Parser, bytes: []const u8, handler: anytype) void {
        var i: usize = 0;
        while (i < bytes.len) {
            // An APC payload goes on in runs up to the next byte that could
            // end it.
            if (self.state == .apc_string and !self.string_escape) {
                const end = std.mem.indexOfAnyPos(u8, bytes, i, "\x18\x1a\x1b") orelse bytes.len;
                if (end > i) {
                    handler.action(.{ .apc_data = bytes[i..end] });
                    i = end;
                    continue;
                }
            }
            self.next(bytes[i], handler);
            i += 1;
        }
    }

    pub fn next(self: *Parser, byte: u8, handler: anytype) void {
        if (self.utf8_need > 0) {
            if (byte & 0xc0 == 0x80) {
                self.utf8[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    const cp = std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch 0xfffd;
                    self.utf8_need = 0;
                    self.utf8_len = 0;
                    handler.action(.{ .print = cp });
                }
                return;
            }
            // A sequence cut short prints a replacement and the byte starts over.
            self.utf8_need = 0;
            self.utf8_len = 0;
            handler.action(.{ .print = 0xfffd });
        }
        // These interrupt any sequence.
        switch (byte) {
            0x18, 0x1a => {
                if (self.state == .apc_string) handler.action(.{ .apc_end = false });
                if (self.inString()) {
                    self.state = .ground;
                    return;
                }
                self.state = .ground;
                handler.action(.{ .execute = byte });
                return;
            },
            0x1b => {
                if (self.inString()) {
                    self.string_escape = true;
                    return;
                }
                self.enterEscape();
                return;
            },
            else => {},
        }
        switch (self.state) {
            .ground => self.ground(byte, handler),
            .escape => switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.action(.{ .execute = byte }),
                0x20...0x2f => {
                    self.collect(byte);
                    self.state = .escape_intermediate;
                },
                '[' => self.enterCsi(),
                ']' => {
                    self.osc_len = 0;
                    self.osc_overflow = false;
                    self.string_escape = false;
                    self.state = .osc_string;
                },
                'P' => {
                    self.string_escape = false;
                    self.state = .dcs_passthrough;
                },
                '_' => {
                    self.string_escape = false;
                    self.state = .apc_string;
                    handler.action(.apc_start);
                },
                'X', '^' => {
                    self.string_escape = false;
                    self.state = .ignore_string;
                },
                0x7f => {},
                else => self.escDispatch(byte, handler),
            },
            .escape_intermediate => switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.action(.{ .execute = byte }),
                0x20...0x2f => self.collect(byte),
                0x7f => {},
                else => self.escDispatch(byte, handler),
            },
            .csi_entry, .csi_param => switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.action(.{ .execute = byte }),
                '0'...'9' => {
                    self.state = .csi_param;
                    self.digit(byte);
                },
                ';', ':' => {
                    self.state = .csi_param;
                    self.separator(byte == ':');
                },
                '<', '=', '>', '?' => if (self.state == .csi_entry) {
                    self.private = byte;
                    self.state = .csi_param;
                } else {
                    self.state = .csi_ignore;
                },
                0x20...0x2f => {
                    self.collect(byte);
                    self.state = .csi_intermediate;
                },
                0x40...0x7e => self.csiDispatch(byte, handler),
                else => {},
            },
            .csi_intermediate => switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.action(.{ .execute = byte }),
                0x20...0x2f => self.collect(byte),
                0x30...0x3f => self.state = .csi_ignore,
                0x40...0x7e => self.csiDispatch(byte, handler),
                else => {},
            },
            .csi_ignore => switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.action(.{ .execute = byte }),
                0x40...0x7e => self.state = .ground,
                else => {},
            },
            .osc_string => {
                if (self.string_escape) {
                    self.string_escape = false;
                    self.finishOsc(handler);
                    // ESC followed by anything but '\\' still ends the string
                    // and starts a new escape with that byte.
                    if (byte != '\\') {
                        self.enterEscape();
                        self.next(byte, handler);
                    }
                    return;
                }
                switch (byte) {
                    0x07 => self.finishOsc(handler),
                    0x00...0x06, 0x08...0x17, 0x19, 0x1c...0x1f => {},
                    else => {
                        if (self.osc_len == self.osc.len) {
                            self.osc_overflow = true;
                            return;
                        }
                        self.osc[self.osc_len] = byte;
                        self.osc_len += 1;
                    },
                }
            },
            .apc_string => {
                if (self.string_escape) {
                    self.string_escape = false;
                    self.state = .ground;
                    // ESC followed by anything but '\\' cancels the string.
                    handler.action(.{ .apc_end = byte == '\\' });
                    if (byte != '\\') {
                        self.enterEscape();
                        self.next(byte, handler);
                    }
                    return;
                }
                handler.action(.{ .apc_data = (&byte)[0..1] });
            },
            .dcs_passthrough, .ignore_string => {
                if (self.string_escape) {
                    self.string_escape = false;
                    self.state = .ground;
                    if (byte != '\\') {
                        self.enterEscape();
                        self.next(byte, handler);
                    }
                    return;
                }
                // DCS, SOS and PM strings are read to their end and dropped;
                // BEL does not end them.
            },
        }
    }

    fn inString(self: *const Parser) bool {
        return switch (self.state) {
            .osc_string, .dcs_passthrough, .apc_string, .ignore_string => true,
            else => false,
        };
    }

    fn ground(self: *Parser, byte: u8, handler: anytype) void {
        switch (byte) {
            0x00...0x1f, 0x7f => handler.action(.{ .execute = byte }),
            0x20...0x7e => handler.action(.{ .print = byte }),
            0xc2...0xdf => self.startUtf8(byte, 2),
            0xe0...0xef => self.startUtf8(byte, 3),
            0xf0...0xf4 => self.startUtf8(byte, 4),
            else => handler.action(.{ .print = 0xfffd }),
        }
    }

    fn startUtf8(self: *Parser, byte: u8, need: u3) void {
        self.utf8[0] = byte;
        self.utf8_len = 1;
        self.utf8_need = need;
    }

    fn enterEscape(self: *Parser) void {
        self.state = .escape;
        self.intermediate_len = 0;
        self.intermediate_overflow = false;
    }

    fn enterCsi(self: *Parser) void {
        self.state = .csi_entry;
        self.params = .{};
        self.param_started = false;
        self.private = 0;
        self.intermediate_len = 0;
        self.intermediate_overflow = false;
    }

    fn collect(self: *Parser, byte: u8) void {
        if (self.intermediate_len == max_intermediates) {
            self.intermediate_overflow = true;
            return;
        }
        self.intermediates[self.intermediate_len] = byte;
        self.intermediate_len += 1;
    }

    fn digit(self: *Parser, byte: u8) void {
        if (!self.param_started) {
            if (self.params.len == max_params) return;
            self.params.len += 1;
            self.param_started = true;
        }
        const value = &self.params.values[self.params.len - 1];
        value.* = std.math.mul(u16, value.*, 10) catch std.math.maxInt(u16);
        value.* = std.math.add(u16, value.*, byte - '0') catch std.math.maxInt(u16);
    }

    fn separator(self: *Parser, colon: bool) void {
        // A separator with nothing before it ends an empty parameter.
        if (!self.param_started) {
            if (self.params.len == max_params) return;
            self.params.len += 1;
        }
        // The parameter after it starts empty, so a trailing separator
        // still counts one.
        if (self.params.len == max_params) return;
        self.params.len += 1;
        self.params.colon[self.params.len - 1] = colon;
        self.param_started = true;
    }

    fn csiDispatch(self: *Parser, final: u8, handler: anytype) void {
        self.state = .ground;
        if (self.intermediate_overflow) return;
        handler.action(.{ .csi = .{ .params = self.params, .private = self.private, .intermediates = self.intermediates[0..self.intermediate_len], .final = final } });
    }

    fn escDispatch(self: *Parser, final: u8, handler: anytype) void {
        self.state = .ground;
        if (self.intermediate_overflow) return;
        handler.action(.{ .esc = .{ .intermediates = self.intermediates[0..self.intermediate_len], .final = final } });
    }

    fn finishOsc(self: *Parser, handler: anytype) void {
        self.state = .ground;
        if (self.osc_overflow) return;
        handler.action(.{ .osc = self.osc[0..self.osc_len] });
    }
};

const Recorder = struct {
    log: [32]Action = undefined,
    texts: [32][64]u8 = undefined,
    len: usize = 0,
    fn action(self: *Recorder, value: Action) void {
        var copy = value;
        switch (value) {
            .osc => |text| {
                @memcpy(self.texts[self.len][0..text.len], text);
                copy = .{ .osc = self.texts[self.len][0..text.len] };
            },
            .csi => |csi| {
                @memcpy(self.texts[self.len][0..csi.intermediates.len], csi.intermediates);
                copy.csi.intermediates = self.texts[self.len][0..csi.intermediates.len];
            },
            .esc => |esc| {
                @memcpy(self.texts[self.len][0..esc.intermediates.len], esc.intermediates);
                copy.esc.intermediates = self.texts[self.len][0..esc.intermediates.len];
            },
            else => {},
        }
        self.log[self.len] = copy;
        self.len += 1;
    }
};

test "text, controls and UTF-8 across feeds" {
    var storage: [16]u8 = undefined;
    var parser = Parser.init(&storage);
    var r: Recorder = .{};
    parser.feed("a\r\n\xe4\xb8", &r);
    parser.feed("\xad\xc3(", &r);
    try std.testing.expectEqual(@as(usize, 6), r.len);
    try std.testing.expectEqual(@as(u21, 'a'), r.log[0].print);
    try std.testing.expectEqual(@as(u8, '\r'), r.log[1].execute);
    try std.testing.expectEqual(@as(u8, '\n'), r.log[2].execute);
    try std.testing.expectEqual(@as(u21, 0x4e2d), r.log[3].print);
    // A lead byte followed by ASCII yields a replacement, then the ASCII.
    try std.testing.expectEqual(@as(u21, 0xfffd), r.log[4].print);
    try std.testing.expectEqual(@as(u21, '('), r.log[5].print);
}

test "control sequences carry parameters, markers and subparameters" {
    var storage: [16]u8 = undefined;
    var parser = Parser.init(&storage);
    var r: Recorder = .{};
    parser.feed("\x1b[1;31m\x1b[?1049h\x1b[38:2::10:20:30m\x1b[;5H\x1b[ q\x1b[>c", &r);
    try std.testing.expectEqual(@as(usize, 6), r.len);
    const sgr = r.log[0].csi;
    try std.testing.expectEqual(@as(u8, 'm'), sgr.final);
    try std.testing.expectEqualSlices(u16, &.{ 1, 31 }, sgr.params.slice());
    const private = r.log[1].csi;
    try std.testing.expectEqual(@as(u8, '?'), private.private);
    try std.testing.expectEqualSlices(u16, &.{1049}, private.params.slice());
    const colon = r.log[2].csi;
    try std.testing.expectEqualSlices(u16, &.{ 38, 2, 0, 10, 20, 30 }, colon.params.slice());
    try std.testing.expect(colon.params.colon[1] and colon.params.colon[2] and colon.params.colon[5]);
    try std.testing.expect(!colon.params.colon[0]);
    const cup = r.log[3].csi;
    try std.testing.expectEqual(@as(u16, 1), cup.params.get(0, 1));
    try std.testing.expectEqual(@as(u16, 5), cup.params.get(1, 1));
    try std.testing.expectEqualStrings(" ", r.log[4].csi.intermediates);
    try std.testing.expectEqual(@as(u8, '>'), r.log[5].csi.private);
}

test "OSC ends at BEL or ST and overflowing payloads are dropped" {
    var storage: [8]u8 = undefined;
    var parser = Parser.init(&storage);
    var r: Recorder = .{};
    parser.feed("\x1b]0;hi\x07\x1b]2;yo\x1b\\\x1b]0;far too long\x07x", &r);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("0;hi", r.log[0].osc);
    try std.testing.expectEqualStrings("2;yo", r.log[1].osc);
    try std.testing.expectEqual(@as(u21, 'x'), r.log[2].print);
}

test "escape sequences, DCS strings and cancellation" {
    var storage: [8]u8 = undefined;
    var parser = Parser.init(&storage);
    var r: Recorder = .{};
    parser.feed("\x1b(0\x1b7\x1bPq#0;1\x07x\x1b\\\x1b[12\x18y", &r);
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqualStrings("(", r.log[0].esc.intermediates);
    try std.testing.expectEqual(@as(u8, '0'), r.log[0].esc.final);
    try std.testing.expectEqual(@as(u8, '7'), r.log[1].esc.final);
    try std.testing.expectEqual(@as(u8, 0x18), r.log[2].execute);
    try std.testing.expectEqual(@as(u21, 'y'), r.log[3].print);
}

test "APC strings stream to the handler and end with ST" {
    var storage: [8]u8 = undefined;
    var parser = Parser.init(&storage);
    const Apc = struct {
        bytes: [64]u8 = undefined,
        len: usize = 0,
        starts: usize = 0,
        ends: [4]bool = undefined,
        end_count: usize = 0,
        printed: usize = 0,
        fn action(self: *@This(), value: Action) void {
            switch (value) {
                .apc_start => self.starts += 1,
                .apc_data => |data| {
                    @memcpy(self.bytes[self.len..][0..data.len], data);
                    self.len += data.len;
                },
                .apc_end => |ok| {
                    self.ends[self.end_count] = ok;
                    self.end_count += 1;
                },
                .print => self.printed += 1,
                else => {},
            }
        }
    };
    var r: Apc = .{};
    parser.feed("\x1b_Ga=T;AAAA", &r);
    parser.next('B', &r);
    parser.feed("\x07C\x1b\\x\x1b_Gq\x18y", &r);
    try std.testing.expectEqualStrings("Ga=T;AAAAB\x07CGq", r.bytes[0..r.len]);
    try std.testing.expectEqual(@as(usize, 2), r.starts);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, r.ends[0..r.end_count]);
    try std.testing.expectEqual(@as(usize, 2), r.printed);
}
