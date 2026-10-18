const std = @import("std");
const d = @import("document.zig");
const s = @import("style.zig");
pub const Limits = struct { bytes: usize = 128 * 1024, rules: usize = 256, declarations: usize = 4096 };
pub const Work = struct {
    used: u64 = 0,
    limit: u64,
    pub fn charge(self: *Work, amount: usize) !void {
        if (amount > self.limit -| self.used) return error.StyleWorkExceeded;
        self.used += amount;
    }
};
pub const Declaration = struct { property: s.Property, value: []const u8, important: bool };
const Selector = struct {
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: [8][]const u8 = undefined,
    class_count: usize = 0,
    specificity: u16 = 0,
    fn matches(self: Selector, node: d.Node, name: []const u8, classes: []const []const u8, work: *Work) !bool {
        try work.charge(1);
        if (self.tag) |tag| {
            try work.charge(@min(tag.len, name.len));
            if (!std.mem.eql(u8, tag, name)) return false;
        }
        if (self.id) |id| {
            const actual = node.attribute("id") orelse return false;
            try work.charge(@min(id.len, actual.len));
            if (!std.mem.eql(u8, id, actual)) return false;
        }
        for (self.classes[0..self.class_count]) |class| {
            var found = false;
            for (classes) |actual| {
                try work.charge(1 + @min(class.len, actual.len));
                if (std.mem.eql(u8, class, actual)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }
};
const Rule = struct { selector: Selector, first: usize, count: usize };
const Winner = struct { declaration: Declaration, specificity: u16 };
pub const Sheet = struct {
    allocator: std.mem.Allocator,
    source: []u8 = &.{},
    rules: []Rule = &.{},
    declarations: []Declaration = &.{},
    pub fn init(allocator: std.mem.Allocator, nodes: []const d.Node, limits: Limits, byte_budget: usize) !Sheet {
        if (limits.bytes > 1024 * 1024 or limits.rules == 0 or limits.rules > 1024 or limits.declarations == 0 or limits.declarations > 16384) return error.InvalidStyleLimits;
        var source_bytes: usize = 0;
        for (nodes) |node| if (node.kind == .element and isStyle(node.name)) {
            if (node.attribute("type")) |value| if (!std.mem.eql(u8, value, "text/css")) return error.UnsupportedStylesheet;
            if (source_bytes == limits.bytes) return error.StylesheetTooLarge;
            source_bytes += 1; // Separate documents cannot complete each other's rule.
            var child = node.first_child;
            while (child) |at| {
                const text = nodes[at];
                if (text.kind != .text) return error.InvalidStylesheet;
                if (text.text.len > limits.bytes -| source_bytes) return error.StylesheetTooLarge;
                source_bytes += text.text.len;
                child = text.next_sibling;
            }
        };
        var result: Sheet = .{ .allocator = allocator };
        if (source_bytes == 0) return result;
        if (source_bytes > byte_budget) return error.CapacityExceeded;
        result.source = try allocator.alloc(u8, source_bytes);
        errdefer allocator.free(result.source);
        var position: usize = 0;
        for (nodes) |node| if (node.kind == .element and isStyle(node.name)) {
            var child = node.first_child;
            while (child) |at| {
                const text = nodes[at].text;
                @memcpy(result.source[position..][0..text.len], text);
                position += text.len;
                child = nodes[at].next_sibling;
            }
            result.source[position] = 0;
            position += 1;
        };
        const size = try clean(result.source);
        var parser: Parser = .{ .input = result.source[0..size], .limits = limits };
        try parser.parse();
        const metadata = parser.rule_count * @sizeOf(Rule) + parser.declaration_count * @sizeOf(Declaration);
        if (metadata > byte_budget - source_bytes) return error.CapacityExceeded;
        result.rules = try allocator.alloc(Rule, parser.rule_count);
        errdefer allocator.free(result.rules);
        result.declarations = try allocator.alloc(Declaration, parser.declaration_count);
        parser = .{ .input = result.source[0..size], .limits = limits, .rules = result.rules, .declarations = result.declarations };
        // The same validated immutable bytes make the second pass infallible.
        parser.parse() catch unreachable;
        return result;
    }
    pub fn bytes(self: Sheet) usize {
        return self.source.len + self.rules.len * @sizeOf(Rule) + self.declarations.len * @sizeOf(Declaration);
    }
    pub fn deinit(self: *Sheet) void {
        self.allocator.free(self.source);
        self.allocator.free(self.rules);
        self.allocator.free(self.declarations);
        self.* = .{ .allocator = self.allocator };
    }
    pub fn derive(self: *const Sheet, parent: s.Style, node: d.Node, name: []const u8, work: *Work) !s.Style {
        var result = parent;
        result.clip_path = null;
        result.mask = null;
        result.mask_type = .luminance;
        result.opacity = 1;
        result.vector_effect = .none;
        result.displayed = true;
        // SVG's default stylesheet clips nested viewports and symbol instances.
        result.overflow_hidden = (node.parent != null and std.mem.eql(u8, name, "svg")) or std.mem.eql(u8, name, "symbol") or std.mem.eql(u8, name, "image") or std.mem.eql(u8, name, "pattern") or std.mem.eql(u8, name, "marker");
        result.overflow_scrollable = false;
        result.stop_color = .{ .color = .{} };
        result.stop_opacity = 1;
        if (node.attribute("xml:lang")) |language| result.font.locale = language;
        if (node.attribute("xml:space")) |space| result.preserve_space = if (std.mem.eql(u8, space, "default")) false else if (std.mem.eql(u8, space, "preserve")) true else return error.UnsupportedTextWhitespace;
        for (node.attributes) |attribute| if (s.property(attribute.name)) |kind| {
            try work.charge(attribute.value.len + 1);
            try result.applyDeclaration(parent, kind, attribute.value);
        };
        var classes: [64][]const u8 = undefined;
        var class_count: usize = 0;
        if (self.rules.len != 0) if (node.attribute("class")) |value| {
            try work.charge(value.len);
            var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n\x0c");
            while (tokens.next()) |class| {
                if (class_count == classes.len) return error.ClassesFull;
                classes[class_count] = class;
                class_count += 1;
            }
        };
        var winners: [std.meta.fields(s.Property).len]?Winner = @splat(null);
        for (self.rules) |rule| if (try rule.selector.matches(node, name, classes[0..class_count], work)) {
            try work.charge(rule.count);
            for (self.declarations[rule.first..][0..rule.count]) |declaration| select(&winners, declaration, rule.selector.specificity);
        };
        if (node.attribute("style")) |source| {
            var declarations: Declarations = .{ .input = source };
            while (try declarations.next()) |declaration| {
                try work.charge(declaration.value.len + 1);
                select(&winners, declaration, 1000);
            }
        }
        // Parse only winning values. Losing declarations never repeatedly
        // shape/parse across every node; matching and parsing have one budget.
        for (winners) |winner| if (winner) |value| {
            try work.charge(value.declaration.value.len + 1);
            try result.applyDeclaration(parent, value.declaration.property, value.declaration.value);
        };
        return result;
    }
};
fn select(winners: []?Winner, declaration: Declaration, specificity: u16) void {
    const index = @intFromEnum(declaration.property);
    if (winners[index]) |old| {
        if (old.declaration.important and !declaration.important) return;
        if (old.declaration.important == declaration.important and old.specificity > specificity) return;
    }
    winners[index] = .{ .declaration = declaration, .specificity = specificity };
}
fn isStyle(name: []const u8) bool {
    return std.mem.eql(u8, name, "style") or (if (std.mem.lastIndexOfScalar(u8, name, ':')) |at| std.mem.eql(u8, name[at + 1 ..], "style") else false);
}
fn whitespace(byte: u8) bool {
    return std.mem.indexOfScalar(u8, " \t\r\n\x0c", byte) != null;
}
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n\x0c");
}
fn nameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}
fn identifier(text: []const u8) bool {
    if (text.len == 0 or text.len > 128) return false;
    const at: usize = @intFromBool(text[0] == '-');
    if (at == text.len) return false;
    return std.ascii.isAlphabetic(text[at]) or text[at] == '_' or (at == 1 and text[at] == '-');
}
fn selector(input: []const u8) !Selector {
    const text = trim(input);
    if (text.len == 0) return error.InvalidSelector;
    var at: usize = 0;
    var result: Selector = .{};
    if (text[0] == '*') at = 1 else if (nameByte(text[0])) {
        while (at < text.len and nameByte(text[at])) at += 1;
        if (!identifier(text[0..at])) return error.InvalidSelector;
        result.tag = text[0..at];
        result.specificity = 1;
    }
    while (at < text.len) {
        const kind = text[at];
        if (kind != '.' and kind != '#') return error.UnsupportedSelector;
        at += 1;
        const start = at;
        while (at < text.len and nameByte(text[at])) at += 1;
        if (!identifier(text[start..at])) return error.InvalidSelector;
        if (kind == '#') {
            if (result.id != null) return error.UnsupportedSelector;
            result.id = text[start..at];
            result.specificity += 100;
        } else {
            if (result.class_count == result.classes.len) return error.SelectorClassesFull;
            result.classes[result.class_count] = text[start..at];
            result.class_count += 1;
            result.specificity += 10;
        }
    }
    return result;
}
pub const Declarations = struct {
    input: []const u8,
    at: usize = 0,
    count: usize = 0,
    pub fn next(self: *Declarations) !?Declaration {
        while (self.at < self.input.len and (whitespace(self.input[self.at]) or self.input[self.at] == ';')) self.at += 1;
        if (self.at == self.input.len) return null;
        if (self.count == 64) return error.DeclarationsFull;
        self.count += 1;
        const start = self.at;
        while (self.at < self.input.len and nameByte(self.input[self.at])) self.at += 1;
        const property = s.property(self.input[start..self.at]) orelse return error.UnsupportedStyleProperty;
        while (self.at < self.input.len and whitespace(self.input[self.at])) self.at += 1;
        if (self.at == self.input.len or self.input[self.at] != ':') return error.InvalidStyle;
        self.at += 1;
        const value_start = self.at;
        var depth: usize = 0;
        var quote: ?u8 = null;
        var bang: ?usize = null;
        while (self.at < self.input.len) : (self.at += 1) {
            const byte = self.input[self.at];
            if (byte == '\\') return error.UnsupportedCssEscape;
            if (quote) |character| {
                if (byte == character) quote = null;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                continue;
            }
            if (byte == '(') {
                if (depth == 8) return error.CssNestingFull;
                depth += 1;
            } else if (byte == ')') {
                if (depth == 0) return error.InvalidStyle;
                depth -= 1;
            } else if (byte == ';' and depth == 0) break else if (byte == '!' and depth == 0) {
                if (bang != null) return error.InvalidStyle;
                bang = self.at;
            }
        }
        if (depth != 0 or quote != null) return error.InvalidStyle;
        var value = trim(self.input[value_start..self.at]);
        var important = false;
        if (bang) |at| {
            if (!std.ascii.eqlIgnoreCase(trim(self.input[at + 1 .. self.at]), "important")) return error.InvalidStyle;
            value = trim(self.input[value_start..at]);
            important = true;
        }
        if (value.len == 0) return error.InvalidStyle;
        if (std.mem.indexOf(u8, value, "/*") != null) return error.UnsupportedCssCommentPlacement;
        // Validate once even for currently unmatched selectors.
        var validation: s.Style = .{};
        try validation.applyDeclaration(.{}, property, value);
        return .{ .property = property, .value = value, .important = important };
    }
};
const Parser = struct {
    input: []const u8,
    limits: Limits,
    rules: ?[]Rule = null,
    declarations: ?[]Declaration = null,
    rule_count: usize = 0,
    declaration_count: usize = 0,
    fn parse(self: *Parser) !void {
        var sheets = std.mem.splitScalar(u8, self.input, 0);
        while (sheets.next()) |input| {
            var at: usize = 0;
            while (at < input.len) {
                while (at < input.len and whitespace(input[at])) at += 1;
                if (at == input.len) break;
                if (input[at] == '@') return error.UnsupportedCssRule;
                const begin = at;
                while (at < input.len and input[at] != '{') at += 1;
                if (at == input.len) return error.InvalidStylesheet;
                const selectors = input[begin..at];
                at += 1;
                const body = at;
                var quote: ?u8 = null;
                while (at < input.len) : (at += 1) {
                    const byte = input[at];
                    if (quote) |character| {
                        if (byte == character) quote = null;
                        continue;
                    }
                    if (byte == '\'' or byte == '"') {
                        quote = byte;
                        continue;
                    }
                    if (byte == '}') break;
                    if (byte == '{' or byte == '\\') return error.InvalidStylesheet;
                }
                if (at == input.len or quote != null) return error.InvalidStylesheet;
                var declarations: Declarations = .{ .input = input[body..at] };
                const first = self.declaration_count;
                while (try declarations.next()) |declaration| {
                    if (self.declaration_count == self.limits.declarations) return error.DeclarationsFull;
                    if (self.declarations) |output| output[self.declaration_count] = declaration;
                    self.declaration_count += 1;
                }
                var choices = std.mem.splitScalar(u8, selectors, ',');
                while (choices.next()) |choice| {
                    const parsed = try selector(choice);
                    if (self.rule_count == self.limits.rules) return error.RulesFull;
                    if (self.rules) |output| output[self.rule_count] = .{ .selector = parsed, .first = first, .count = self.declaration_count - first };
                    self.rule_count += 1;
                }
                at += 1;
            }
        }
    }
};
fn clean(source: []u8) !usize {
    var read: usize = 0;
    var write: usize = 0;
    var quote: ?u8 = null;
    while (read < source.len) {
        const byte = source[read];
        if (byte == '\\') return error.UnsupportedCssEscape;
        if (byte == 0 and quote != null) return error.InvalidStylesheet;
        if (quote) |character| {
            if (byte == character) quote = null;
        } else if (byte == '\'' or byte == '"') quote = byte else if (std.mem.startsWith(u8, source[read..], "/*")) {
            read += 2;
            while (read + 1 < source.len and !std.mem.startsWith(u8, source[read..], "*/")) : (read += 1) if (source[read] == 0) return error.InvalidStylesheet;
            if (read + 1 >= source.len) return error.InvalidStylesheet;
            read += 2;
            source[write] = ' ';
            write += 1;
            continue;
        }
        source[write] = byte;
        write += 1;
        read += 1;
    }
    if (quote != null) return error.InvalidStylesheet;
    return write;
}

test "marker CSS winner storage is fixed and allocation free" {
    std.debug.print("svg_marker_css_sizes property_count={d} winner={d} winner_slots={d} pre_marker_slots={d}\n", .{ std.meta.fields(s.Property).len, @sizeOf(?Winner), @sizeOf([std.meta.fields(s.Property).len]?Winner), @sizeOf([std.meta.fields(s.Property).len - 3]?Winner) });
}
