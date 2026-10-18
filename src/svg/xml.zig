const std = @import("std");

pub const Attribute = struct { name: []const u8, value: []const u8 };
pub const Start = struct { name: []const u8, attributes: []const Attribute, empty: bool };
pub const Text = struct { bytes: []const u8, cdata: bool = false };
pub const Token = union(enum) { start: Start, end: []const u8, text: Text };
pub const Limits = struct { depth: usize = 32, attributes: usize = 32, attribute_bytes: usize = 65536, nodes: usize = 4096 };

/// A bounded, borrowing XML reader for vector documents. The attribute view is
/// valid until the next call. No DTD, custom entity, external lookup or general
/// processing instruction is supported. Names use a deliberate ASCII subset.
pub const Reader = struct {
    input: []const u8,
    limits: Limits,
    position: usize = 0,
    stack: [64][]const u8 = undefined,
    depth: usize = 0,
    attributes: [64]Attribute = undefined,
    nodes: usize = 0,
    root_seen: bool = false,
    declaration_allowed: bool = true,
    pub fn init(input: []const u8, limits: Limits) !Reader {
        if (limits.depth == 0 or limits.depth > 64 or limits.attributes > 64 or limits.attribute_bytes == 0 or limits.attribute_bytes > 1024 * 1024 or limits.nodes == 0 or limits.nodes > 65536) return error.InvalidLimits;
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        var iterator = std.unicode.Utf8View.initUnchecked(input).iterator();
        while (iterator.nextCodepoint()) |cp| if (!validCharacter(cp)) return error.InvalidXmlCharacter;
        return .{ .input = input, .limits = limits, .position = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) 3 else 0 };
    }
    pub fn next(self: *Reader) !?Token {
        while (self.position < self.input.len) {
            if (self.input[self.position] != '<') {
                const start = self.position;
                while (self.position < self.input.len and self.input[self.position] != '<') self.position += 1;
                const bytes = self.input[start..self.position];
                if (self.depth == 0) {
                    if (!whitespace(bytes)) return error.TextOutsideRoot;
                    self.declaration_allowed = false;
                    continue;
                }
                if (std.mem.indexOf(u8, bytes, "]]>") != null) return error.InvalidXml;
                _ = try decode(null, bytes, false);
                return .{ .text = .{ .bytes = bytes } };
            }
            if (self.consume("<!--")) {
                self.declaration_allowed = false;
                const end = std.mem.indexOfPos(u8, self.input, self.position, "-->") orelse return error.InvalidXml;
                if (std.mem.indexOf(u8, self.input[self.position..end], "--") != null or (end > self.position and self.input[end - 1] == '-')) return error.InvalidXml;
                self.position = end + 3;
                continue;
            }
            if (self.consume("<![CDATA[")) {
                if (self.depth == 0) return error.TextOutsideRoot;
                const end = std.mem.indexOfPos(u8, self.input, self.position, "]]>") orelse return error.InvalidXml;
                const bytes = self.input[self.position..end];
                self.position = end + 3;
                return .{ .text = .{ .bytes = bytes, .cdata = true } };
            }
            if (self.consume("<?")) {
                if (!self.declaration_allowed or !self.consume("xml")) return error.UnsupportedProcessingInstruction;
                self.declaration_allowed = false;
                const attrs = try self.readAttributes(true);
                if (attrs.len == 0 or !std.mem.eql(u8, attrs[0].name, "version") or !std.mem.eql(u8, attrs[0].value, "1.0")) return error.UnsupportedXmlVersion;
                var expected: usize = 1;
                if (expected < attrs.len and std.mem.eql(u8, attrs[expected].name, "encoding")) {
                    if (!std.ascii.eqlIgnoreCase(attrs[expected].value, "utf-8")) return error.UnsupportedEncoding;
                    expected += 1;
                }
                if (expected < attrs.len and std.mem.eql(u8, attrs[expected].name, "standalone")) {
                    if (!std.mem.eql(u8, attrs[expected].value, "yes") and !std.mem.eql(u8, attrs[expected].value, "no")) return error.InvalidXml;
                    expected += 1;
                }
                if (expected != attrs.len or !self.consume("?>")) return error.InvalidXml;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.position..], "<!")) return error.UnsupportedDeclaration;
            self.declaration_allowed = false;
            if (self.consume("</")) {
                const name = try self.readName();
                self.space();
                if (!self.consume(">") or self.depth == 0 or !std.mem.eql(u8, name, self.stack[self.depth - 1])) return error.MismatchedElement;
                self.depth -= 1;
                return .{ .end = name };
            }
            if (!self.consume("<")) return error.InvalidXml;
            if (self.depth == 0 and self.root_seen) return error.MultipleRoots;
            const name = try self.readName();
            const attrs = try self.readAttributes(false);
            const empty = self.consume("/>");
            if (!empty and !self.consume(">")) return error.InvalidXml;
            if (self.nodes == self.limits.nodes) return error.NodesFull;
            self.nodes += 1;
            if (self.depth == self.limits.depth) return error.DepthFull;
            if (self.depth == 0) self.root_seen = true;
            if (!empty) {
                self.stack[self.depth] = name;
                self.depth += 1;
            }
            return .{ .start = .{ .name = name, .attributes = attrs, .empty = empty } };
        }
        if (!self.root_seen or self.depth != 0) return error.IncompleteDocument;
        return null;
    }
    fn readAttributes(self: *Reader, declaration: bool) ![]const Attribute {
        var count: usize = 0;
        while (true) {
            const previous = self.position;
            self.space();
            if (self.position == self.input.len) return error.InvalidXml;
            if (self.input[self.position] == '>' or self.input[self.position] == '/' or (declaration and self.input[self.position] == '?')) return self.attributes[0..count];
            if (previous == self.position) return error.AttributeSeparatorRequired;
            const name = try self.readName();
            for (self.attributes[0..count]) |attribute| if (std.mem.eql(u8, attribute.name, name)) return error.DuplicateAttribute;
            self.space();
            if (!self.consume("=")) return error.InvalidXml;
            self.space();
            if (self.position == self.input.len or (self.input[self.position] != '\'' and self.input[self.position] != '"')) return error.QuotedAttributeRequired;
            const quote = self.input[self.position];
            self.position += 1;
            const start = self.position;
            while (self.position < self.input.len and self.input[self.position] != quote) {
                if (self.input[self.position] == '<') return error.InvalidXml;
                self.position += 1;
                if (self.position - start > self.limits.attribute_bytes) return error.AttributeTooLarge;
            }
            if (self.position == self.input.len) return error.InvalidXml;
            const value = self.input[start..self.position];
            self.position += 1;
            _ = try decode(null, value, true);
            if (count == self.limits.attributes) return error.AttributesFull;
            self.attributes[count] = .{ .name = name, .value = value };
            count += 1;
        }
    }
    fn readName(self: *Reader) ![]const u8 {
        const start = self.position;
        if (start == self.input.len or !nameStart(self.input[start])) return error.UnsupportedXmlName;
        self.position += 1;
        while (self.position < self.input.len and (nameStart(self.input[self.position]) or std.ascii.isDigit(self.input[self.position]) or self.input[self.position] == '-' or self.input[self.position] == '.')) self.position += 1;
        if (self.position - start > 128) return error.NameTooLarge;
        return self.input[start..self.position];
    }
    fn space(self: *Reader) void {
        while (self.position < self.input.len and isSpace(self.input[self.position])) self.position += 1;
    }
    fn consume(self: *Reader, value: []const u8) bool {
        if (!std.mem.startsWith(u8, self.input[self.position..], value)) return false;
        self.position += value.len;
        return true;
    }
};
fn nameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == ':';
}
fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}
fn whitespace(bytes: []const u8) bool {
    for (bytes) |byte| if (!isSpace(byte)) return false;
    return true;
}
fn validCharacter(cp: u21) bool {
    return cp == 9 or cp == 10 or cp == 13 or (cp >= 0x20 and cp <= 0xd7ff) or (cp >= 0xe000 and cp <= 0xfffd) or (cp >= 0x10000 and cp <= 0x10ffff);
}

/// Decodes only predefined/numeric references, once. Pass null to validate and
/// count exact bytes. Literal attribute whitespace follows XML normalization;
/// referenced whitespace is preserved. Input must already be valid UTF-8.
pub fn decode(output: ?[]u8, bytes: []const u8, attribute: bool) !usize {
    var at: usize = 0;
    var written: usize = 0;
    while (at < bytes.len) {
        var scratch: [4]u8 = undefined;
        const value: []const u8 = if (bytes[at] == '&') blk: {
            const end = std.mem.indexOfScalarPos(u8, bytes, at + 1, ';') orelse return error.InvalidEntity;
            const name = bytes[at + 1 .. end];
            if (name.len > 16) return error.InvalidEntity;
            const named: ?u21 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else null;
            const cp: u21 = named orelse parse: {
                if (name.len < 2 or name[0] != '#') return error.UnsupportedEntity;
                const hex = name.len >= 3 and name[1] == 'x';
                const digits = name[if (hex) @as(usize, 2) else 1..];
                if (digits.len == 0) return error.InvalidEntity;
                for (digits) |byte| if (!(if (hex) std.ascii.isHex(byte) else std.ascii.isDigit(byte))) return error.InvalidEntity;
                break :parse std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return error.InvalidEntity;
            };
            if (!validCharacter(cp)) return error.InvalidXmlCharacter;
            const size = std.unicode.utf8Encode(cp, &scratch) catch return error.InvalidXmlCharacter;
            at = end + 1;
            break :blk scratch[0..size];
        } else blk: {
            const byte = bytes[at];
            at += 1;
            if (byte == '\r') {
                if (at < bytes.len and bytes[at] == '\n') at += 1;
                scratch[0] = if (attribute) ' ' else '\n';
            } else scratch[0] = if (attribute and (byte == '\n' or byte == '\t')) ' ' else byte;
            break :blk scratch[0..1];
        };
        if (output) |target| {
            if (value.len > target.len -| written) return error.BufferTooSmall;
            @memcpy(target[written..][0..value.len], value);
        }
        written += value.len;
    }
    return written;
}
