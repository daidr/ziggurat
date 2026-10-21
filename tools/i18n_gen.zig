//! Reads the catalogs of an app's messages, checks them, and writes their
//! typed accessors: Zig functions in the catalogs' directory (catalog.zig)
//! and a TypeScript module that formats the same messages in pages with
//! `@ziggurat/runtime/i18n`. `ziggurat generate` and `ziggurat i18n check`
//! use it.
//!
//! A catalog is `<tag>.json` in the catalogs' directory, named by its BCP
//! 47 tag in canonical form: an object of messages, each key a letter then
//! letters, digits and `_`. In the source language's catalog, `@key`
//! describes the message `key`: `{"description": "...", "placeholders":
//! {"count": {"type": "int"}}}`, whose types are String, int, double, num,
//! DateTime and Object. `@@locale` names the file's language; other `@@`
//! attributes are kept by translation tools and ignored here.
const std = @import("std");
const i18n = @import("ziggurat_i18n");

pub const zig_file = "catalog.zig";

pub const Options = struct {
    /// Names the directory of the catalogs in diagnostics, as "locales".
    dir_name: []const u8 = "locales",
    /// The language the messages are written in first, whose catalog has
    /// every key and the metadata.
    source: []const u8 = "en",
};

pub const Type = enum {
    String,
    int,
    double,
    num,
    DateTime,
    Object,

    fn zig(self: Type) []const u8 {
        return switch (self) {
            .String => "[]const u8",
            .int => "i64",
            .double, .num => "f64",
            .DateTime => "i18n.Instant",
            .Object => "i18n.Value",
        };
    }

    fn typescript(self: Type) []const u8 {
        return switch (self) {
            .String => "string",
            .int, .double, .num => "number",
            .DateTime => "Date",
            .Object => "unknown",
        };
    }

    /// Whether an argument of this type can be used as `kind`.
    fn fits(self: Type, kind: i18n.message.Kind) bool {
        return switch (kind) {
            .plural, .selectordinal, .number => self == .int or self == .double or self == .num or self == .Object,
            .date, .time => self == .DateTime or self == .Object,
            .select => self == .String or self == .Object,
            .simple => true,
        };
    }

    /// The type of an argument nothing declares: a number for plural,
    /// selectordinal and number arguments, a time for date and time ones,
    /// a string otherwise.
    fn infer(kind: ?i18n.message.Kind) Type {
        return switch (kind orelse .simple) {
            .plural, .selectordinal, .number => .int,
            .date, .time => .DateTime,
            .simple, .select => .String,
        };
    }
};

pub const Param = struct {
    /// As the message names it.
    name: []const u8,
    type: Type,
    /// The names of the accessors' parameters, which keywords and the
    /// accessors' own names would clash with.
    zig: []const u8 = "",
    typescript: []const u8 = "",
};

pub const Key = struct {
    name: []const u8,
    message: []const u8,
    description: []const u8 = "",
    params: []const Param = &.{},
};

/// What a message holds: its arguments and the cases of each.
pub const Usage = struct {
    pub const Argument = struct { name: []const u8, kind: i18n.message.Kind, cases: std.ArrayList([]const u8) = .empty };
    arguments: std.ArrayList(Argument) = .empty,

    fn find(self: *Usage, name: []const u8) ?*Argument {
        for (self.arguments.items) |*argument| if (std.mem.eql(u8, argument.name, name)) return argument;
        return null;
    }
};

pub const File = struct {
    tag: []const u8,
    /// As diagnostics name it, "locales/de.json".
    name: []const u8,
    keys: std.ArrayList([]const u8) = .empty,
    messages: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The messages that parse.
    usage: std.StringHashMapUnmanaged(Usage) = .empty,
    /// The line of each key, metadata too.
    lines: std.StringHashMapUnmanaged(u32) = .empty,
    metadata: std.StringArrayHashMapUnmanaged(std.json.Value) = .empty,
};

pub const Diagnostic = struct {
    file: []const u8,
    /// 0 for the whole file.
    line: u32 = 0,
    warning: bool = false,
    text: []const u8,

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.file);
        if (self.line > 0) try writer.print(":{d}", .{self.line});
        try writer.writeAll(if (self.warning) ": warning: " else ": ");
        try writer.writeAll(self.text);
    }
};

pub const Catalog = struct {
    source: []const u8,
    /// The source first, then the others sorted.
    languages: []const []const u8,
    /// The messages of the source, in the order of its file.
    keys: []const Key,
    files: std.StringHashMapUnmanaged(*File),
    diagnostics: []const Diagnostic,

    pub fn errors(self: *const Catalog) usize {
        var count: usize = 0;
        for (self.diagnostics) |d| count += @intFromBool(!d.warning);
        return count;
    }
};

const Loader = struct {
    arena: std.mem.Allocator,
    options: Options,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    files: std.StringHashMapUnmanaged(*File) = .empty,
    keys: std.ArrayList(Key) = .empty,

    fn report(self: *Loader, warning: bool, file: []const u8, line: u32, comptime format: []const u8, arguments: anytype) !void {
        try self.diagnostics.append(self.arena, .{ .file = file, .line = line, .warning = warning, .text = try std.fmt.allocPrint(self.arena, format, arguments) });
    }

    fn err(self: *Loader, file: []const u8, line: u32, comptime format: []const u8, arguments: anytype) !void {
        try self.report(false, file, line, format, arguments);
    }

    fn warn(self: *Loader, file: []const u8, line: u32, comptime format: []const u8, arguments: anytype) !void {
        try self.report(true, file, line, format, arguments);
    }
};

/// The canonical tag of `text`, or null when it is not a BCP 47 tag.
fn canonical(buffer: []u8, text: []const u8) ?[]const u8 {
    const locale = i18n.Locale.parse(text) catch return null;
    if (locale.isRoot()) return null;
    const tag = locale.tag();
    if (tag.len > buffer.len) return null;
    @memcpy(buffer[0..tag.len], tag);
    return buffer[0..tag.len];
}

fn isPseudo(tag: []const u8) bool {
    const locale = i18n.Locale.parse(tag) catch return false;
    return i18n.pseudo.modeFor(&locale) != .none;
}

/// Reads the catalogs in `dir` and checks them. It fails only when it
/// cannot read them; problems of their contents are diagnostics, and a
/// catalog with errors still holds what could be read. Everything is
/// allocated in `arena`.
pub fn load(arena: std.mem.Allocator, dir: std.fs.Dir, options: Options) !Catalog {
    var loader: Loader = .{ .arena = arena, .options = options };
    var buffer: [i18n.locale.max_tag_len]u8 = undefined;
    const source_ok = if (canonical(&buffer, options.source)) |tag| std.mem.eql(u8, tag, options.source) and !isPseudo(tag) else false;
    if (!source_ok) {
        try loader.err(options.dir_name, 0, "the source language \"{s}\" is not a BCP 47 tag in its canonical form, as en, de-CH or zh-Hans", .{options.source});
        return finish(&loader, &.{});
    }
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        const tag = name[0 .. name.len - ".json".len];
        const display = try std.fmt.allocPrint(arena, "{s}/{s}", .{ options.dir_name, name });
        const normal = canonical(&buffer, tag);
        if (normal == null or !std.mem.eql(u8, normal.?, tag)) {
            if (normal) |good|
                try loader.err(display, 0, "the name of a catalog is a BCP 47 tag in its canonical form, as en.json or zh-Hant.json: rename it {s}.json", .{good})
            else
                try loader.err(display, 0, "the name of a catalog is a BCP 47 tag in its canonical form, as en.json or zh-Hant.json", .{});
            continue;
        }
        if (isPseudo(tag)) {
            try loader.err(display, 0, "{s} is a pseudo locale, made from the source language: remove the file", .{tag});
            continue;
        }
        const bytes = try dir.readFileAlloc(arena, name, i18n.catalog.max_json_bytes);
        if (try readFile(&loader, display, tag, bytes)) |file| try loader.files.put(arena, tag, file);
    }
    const source_file = loader.files.get(options.source) orelse {
        try loader.err(try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ options.dir_name, options.source }), 0, "missing: it holds the messages of the source language, {s}", .{options.source});
        return finish(&loader, &.{});
    };
    var languages: std.ArrayList([]const u8) = .empty;
    var tags = loader.files.keyIterator();
    while (tags.next()) |tag| if (!std.mem.eql(u8, tag.*, options.source)) try languages.append(arena, tag.*);
    std.mem.sort([]const u8, languages.items, {}, lessThan);
    try languages.insert(arena, 0, options.source);
    try sourceKeys(&loader, source_file);
    for (languages.items) |tag| try checkFile(&loader, loader.files.get(tag).?);
    return finish(&loader, languages.items);
}

fn finish(loader: *Loader, languages: []const []const u8) Catalog {
    // By file, then line, those of a whole file last.
    std.mem.sort(Diagnostic, loader.diagnostics.items, {}, struct {
        fn less(_: void, a: Diagnostic, b: Diagnostic) bool {
            const order = std.mem.order(u8, a.file, b.file);
            if (order != .eq) return order == .lt;
            const la = if (a.line == 0) std.math.maxInt(u32) else a.line;
            const lb = if (b.line == 0) std.math.maxInt(u32) else b.line;
            return la < lb;
        }
    }.less);
    return .{ .source = loader.options.source, .languages = languages, .keys = loader.keys.items, .files = loader.files, .diagnostics = loader.diagnostics.items };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lineAt(bytes: []const u8, offset: usize) u32 {
    return @intCast(1 + std.mem.count(u8, bytes[0..@min(offset, bytes.len)], "\n"));
}

/// Reads a catalog: an object of messages, metadata and `@@` attributes,
/// in order.
fn readFile(loader: *Loader, name: []const u8, tag: []const u8, bytes: []const u8) !?*File {
    const arena = loader.arena;
    const file = try arena.create(File);
    file.* = .{ .tag = tag, .name = name };
    var scanner = std.json.Scanner.initCompleteInput(arena, bytes);
    const first = scanner.next() catch null;
    if (first == null or first.? != .object_begin) {
        try loader.err(name, 0, "not a JSON object of messages", .{});
        return null;
    }
    while (true) {
        const token = scanner.nextAlloc(arena, .alloc_always) catch {
            try loader.err(name, lineAt(bytes, scanner.cursor), "not valid JSON", .{});
            return null;
        };
        const key = switch (token) {
            .object_end => break,
            .allocated_string => |text| text,
            else => unreachable,
        };
        const line = lineAt(bytes, scanner.cursor);
        const value = std.json.Value.jsonParse(arena, &scanner, .{ .max_value_len = bytes.len, .allocate = .alloc_always, .duplicate_field_behavior = .use_last }) catch {
            try loader.err(name, line, "not valid JSON", .{});
            return null;
        };
        if (file.lines.contains(key)) {
            try loader.err(name, line, "\"{s}\" comes twice", .{key});
            continue;
        }
        try file.lines.put(arena, key, line);
        if (std.mem.eql(u8, key, "@@locale")) {
            var buffer: [i18n.locale.max_tag_len]u8 = undefined;
            const named = if (value == .string) canonical(&buffer, value.string) else null;
            if (named == null or !std.mem.eql(u8, named.?, tag)) try loader.err(name, line, "@@locale is not {s}, the language the file is named after", .{tag});
        } else if (std.mem.startsWith(u8, key, "@@")) {
            // Other attributes of the file, as @@last_modified.
        } else if (key.len > 0 and key[0] == '@') {
            try file.metadata.put(arena, key[1..], value);
        } else {
            if (value != .string) {
                try loader.err(name, line, "\"{s}\" is not a string", .{key});
                continue;
            }
            try file.keys.append(arena, key);
            try file.messages.put(arena, key, value.string);
            var usage: Usage = .{};
            var recorder: Recorder = .{ .arena = arena, .usage = &usage };
            if (i18n.message.visit(value.string, recorder.visitor())) {
                if (recorder.failed) return error.OutOfMemory;
                try file.usage.put(arena, key, usage);
            } else |failure| switch (failure) {
                error.NestingTooDeep => try loader.err(name, line, "\"{s}\" nests arguments more than {d} deep", .{ key, i18n.message.max_depth }),
                else => try loader.err(name, line, "\"{s}\" is not a valid message: check its braces, the other case of each plural and select, and the kinds of arguments", .{key}),
            }
        }
    }
    const last = scanner.next() catch null;
    if (last == null or last.? != .end_of_document) try loader.err(name, lineAt(bytes, scanner.cursor), "text after the object", .{});
    return file;
}

const Recorder = struct {
    arena: std.mem.Allocator,
    usage: *Usage,
    failed: bool = false,

    fn visitor(self: *Recorder) i18n.message.Visitor {
        return .{ .context = self, .argument = argument, .case = case };
    }

    fn argument(context: *anyopaque, name: []const u8, kind: i18n.message.Kind) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (self.usage.find(name) != null) return;
        self.usage.arguments.append(self.arena, .{ .name = name, .kind = kind }) catch {
            self.failed = true;
        };
    }

    fn case(context: *anyopaque, name: []const u8, key: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const found = self.usage.find(name) orelse return;
        found.cases.append(self.arena, key) catch {
            self.failed = true;
        };
    }
};

fn validKey(key: []const u8) bool {
    if (key.len == 0 or !std.ascii.isAlphabetic(key[0])) return false;
    for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Names the generated Zig declares next to the accessors.
const zig_taken = [_][]const u8{ "std", "i18n", "source", "languages", "bundles", "catalog", "Messages", "in", "localizer", "self", "writer" };

const typescript_reserved = [_][]const u8{ "arguments", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "eval", "export", "extends", "false", "finally", "for", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "package", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield" };

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// Reads the keys of the source language and their parameters.
fn sourceKeys(loader: *Loader, file: *File) !void {
    const arena = loader.arena;
    for (file.keys.items) |key| {
        const line = file.lines.get(key).?;
        if (!validKey(key)) {
            try loader.err(file.name, line, "\"{s}\" is not a key: a letter, then letters, digits and _, as filesSelected", .{key});
            continue;
        }
        if (contains(&zig_taken, key)) {
            try loader.err(file.name, line, "\"{s}\" would name its Zig function as a declaration of the generated code", .{key});
            continue;
        }
        var entry: Key = .{ .name = key, .message = file.messages.get(key).? };
        try readMetadata(loader, file, &entry);
        try loader.keys.append(arena, entry);
    }
    var described = file.metadata.iterator();
    while (described.next()) |item| if (!file.messages.contains(item.key_ptr.*)) {
        try loader.warn(file.name, file.lines.get(try std.fmt.allocPrint(arena, "@{s}", .{item.key_ptr.*})) orelse 0, "@{s} describes no message", .{item.key_ptr.*});
    };
    // Parameter names clash with no function or declaration.
    var functions: std.ArrayList([]const u8) = .empty;
    try functions.appendSlice(arena, &zig_taken);
    for (loader.keys.items) |entry| try functions.append(arena, entry.name);
    for (loader.keys.items) |*entry| {
        const params: []Param = @constCast(entry.params);
        for (params) |*param| {
            var zig = param.name;
            while (contains(functions.items, zig) or std.zig.Token.keywords.has(zig) or std.zig.primitives.isPrimitive(zig)) zig = try std.fmt.allocPrint(arena, "{s}_", .{zig});
            param.zig = zig;
            var typescript = if (std.ascii.isDigit(param.name[0])) try std.fmt.allocPrint(arena, "arg{s}", .{param.name}) else param.name;
            if (contains(&typescript_reserved, typescript)) typescript = try std.fmt.allocPrint(arena, "{s}_", .{typescript});
            param.typescript = typescript;
        }
    }
}

/// Reads the description and placeholders of a key, and its parameters:
/// the declared placeholders in their order, then the other arguments of
/// the message in theirs, typed by what they declare or how the message
/// uses them.
fn readMetadata(loader: *Loader, file: *File, entry: *Key) !void {
    const arena = loader.arena;
    const meta_key = try std.fmt.allocPrint(arena, "@{s}", .{entry.name});
    const line = file.lines.get(meta_key) orelse file.lines.get(entry.name).?;
    var params: std.ArrayList(Param) = .empty;
    var declared: std.StringHashMapUnmanaged(?Type) = .empty;
    if (file.metadata.get(entry.name)) |meta| {
        if (meta != .object) {
            try loader.err(file.name, line, "@{s} is not an object", .{entry.name});
        } else {
            if (meta.object.get("description")) |description| {
                if (description == .string) entry.description = description.string else try loader.err(file.name, line, "@{s}.description is not a string", .{entry.name});
            }
            if (meta.object.get("placeholders")) |placeholders| switch (placeholders) {
                .null => {},
                .object => |object| {
                    var items = object.iterator();
                    while (items.next()) |item| {
                        const name = item.key_ptr.*;
                        var declared_type: ?Type = null;
                        if (item.value_ptr.* != .object) {
                            try loader.err(file.name, line, "@{s}.placeholders.{s} is not an object", .{ entry.name, name });
                            continue;
                        }
                        if (item.value_ptr.object.get("type")) |type_value| {
                            declared_type = if (type_value == .string) std.meta.stringToEnum(Type, type_value.string) else null;
                            if (declared_type == null) try loader.err(file.name, line, "@{s}.placeholders.{s}: the type is not String, int, double, num, DateTime or Object", .{ entry.name, name });
                        }
                        try declared.put(arena, name, declared_type);
                        try params.append(arena, .{ .name = name, .type = .String });
                    }
                },
                else => try loader.err(file.name, line, "@{s}.placeholders is not an object", .{entry.name}),
            };
        }
    }
    const usage = file.usage.getPtr(entry.name);
    if (usage) |u| for (u.arguments.items) |argument| {
        var known = false;
        for (params.items) |param| known = known or std.mem.eql(u8, param.name, argument.name);
        if (!known) try params.append(arena, .{ .name = argument.name, .type = .String });
    };
    for (params.items) |*param| {
        const kind: ?i18n.message.Kind = if (usage) |u| if (u.find(param.name)) |a| a.kind else null else null;
        if (kind == null and usage != null) try loader.warn(file.name, line, "@{s} declares the placeholder {s}, which the message does not use", .{ entry.name, param.name });
        const declared_type = declared.get(param.name) orelse null;
        param.type = declared_type orelse Type.infer(kind);
        if (declared_type != null and kind != null and !declared_type.?.fits(kind.?)) {
            try loader.err(file.name, file.lines.get(entry.name).?, "\"{s}\" uses {s} as a {s} argument, which its type {s} cannot be", .{ entry.name, param.name, @tagName(kind.?), @tagName(declared_type.?) });
        }
    }
    entry.params = params.items;
    if (usage) |u| try checkPlurals(loader, file, entry.name, u);
}

/// Checks a file against the source language: its keys, their arguments
/// and their plural forms.
fn checkFile(loader: *Loader, file: *File) !void {
    const arena = loader.arena;
    const source = loader.files.get(loader.options.source).?;
    if (file == source) return;
    for (file.keys.items) |key| {
        const line = file.lines.get(key).?;
        const entry = for (loader.keys.items) |*k| {
            if (std.mem.eql(u8, k.name, key)) break k;
        } else {
            // A bad key of the source is reported there.
            if (!source.messages.contains(key)) try loader.err(file.name, line, "\"{s}\" is not a key of {s}", .{ key, source.name });
            continue;
        };
        const usage = file.usage.getPtr(key) orelse continue;
        for (usage.arguments.items) |argument| {
            const param = for (entry.params) |p| {
                if (std.mem.eql(u8, p.name, argument.name)) break p;
            } else {
                if (entry.params.len == 0) {
                    try loader.err(file.name, line, "\"{s}\" uses the argument {s}, but the source message has no arguments", .{ key, argument.name });
                } else {
                    var names: std.Io.Writer.Allocating = .init(arena);
                    for (entry.params, 0..) |p, index| try names.writer.print("{s}{s}", .{ if (index > 0) ", " else "", p.name });
                    try loader.err(file.name, line, "\"{s}\" uses the argument {s}, but the source message has the arguments {s}", .{ key, argument.name, names.written() });
                }
                continue;
            };
            if (!param.type.fits(argument.kind)) try loader.err(file.name, line, "\"{s}\" uses {s} as a {s} argument, which its type {s} cannot be", .{ key, argument.name, @tagName(argument.kind), @tagName(param.type) });
        }
        for (entry.params) |param| if (usage.find(param.name) == null) try loader.warn(file.name, line, "\"{s}\" does not use the argument {s}", .{ key, param.name });
        try checkPlurals(loader, file, key, usage);
    }
    var missing: std.ArrayList([]const u8) = .empty;
    for (loader.keys.items) |entry| if (!file.messages.contains(entry.name)) try missing.append(arena, entry.name);
    if (missing.items.len > 0) {
        var list: std.Io.Writer.Allocating = .init(arena);
        for (missing.items[0..@min(8, missing.items.len)], 0..) |name, index| try list.writer.print("{s}{s}", .{ if (index > 0) ", " else "", name });
        if (missing.items.len > 8) try list.writer.print(" and {d} more", .{missing.items.len - 8});
        try loader.warn(file.name, 0, "{d} of {d} messages missing, which say the language they fall back to: {s}", .{ missing.items.len, loader.keys.items.len, list.written() });
    }
}

/// Warns of plural and selectordinal cases the language's rules never
/// select, and of the categories they lack.
fn checkPlurals(loader: *Loader, file: *File, key: []const u8, usage: *Usage) !void {
    const arena = loader.arena;
    const line = file.lines.get(key).?;
    const locale = i18n.Locale.parse(file.tag) catch return;
    for (usage.arguments.items) |argument| {
        if (argument.kind != .plural and argument.kind != .selectordinal) continue;
        const ordinal = argument.kind == .selectordinal;
        const have = if (ordinal) i18n.plural.ordinalCategories(&locale) else i18n.plural.cardinalCategories(i18n.plural.rulesFor(&locale));
        const word = if (ordinal) "ordinal" else "plural";
        var extra: std.Io.Writer.Allocating = .init(arena);
        var extra_count: usize = 0;
        var cases: i18n.plural.Categories = .initEmpty();
        for (argument.cases.items) |name| {
            const category = i18n.plural.Category.parse(name) orelse continue;
            cases.insert(category);
            if (!have.contains(category)) {
                try extra.writer.print("{s}{s}", .{ if (extra_count > 0) ", " else "", name });
                extra_count += 1;
            }
        }
        var names: std.Io.Writer.Allocating = .init(arena);
        var lacking: std.Io.Writer.Allocating = .init(arena);
        var lacking_count: usize = 0;
        var categories = have.iterator();
        var first = true;
        while (categories.next()) |category| {
            try names.writer.print("{s}{s}", .{ if (first) "" else ", ", @tagName(category) });
            first = false;
            if (!cases.contains(category)) {
                try lacking.writer.print("{s}{s}", .{ if (lacking_count > 0) ", " else "", @tagName(category) });
                lacking_count += 1;
            }
        }
        if (extra_count > 0) try loader.warn(file.name, line, "\"{s}\": {s} has no {s} {s} {s} (its {s} categories are {s})", .{ key, file.tag, word, if (extra_count == 1) "category" else "categories", extra.written(), word, names.written() });
        if (lacking_count > 0) try loader.warn(file.name, line, "\"{s}\": the {s} argument {s} lacks {s}, {s} {s} of {s}, which says other in its place", .{ key, @tagName(argument.kind), argument.name, lacking.written(), if (lacking_count == 1) "a" else "the", if (lacking_count == 1) "category" else "categories", file.tag });
    }
}

// ---------------------------------------------------------------- Zig

/// The Zig accessors of a catalog without errors: the messages of every
/// language, a function that makes the `i18n.Catalog` of them, and
/// `Messages`, whose functions say each message through a Localizer.
pub fn writeZig(writer: *std.Io.Writer, catalog: *const Catalog) !void {
    try writer.writeAll(
        \\//! Generated by `ziggurat generate` from the catalogs in this directory. Do not edit.
        \\const std = @import("std");
        \\const i18n = @import("ziggurat_i18n");
        \\
        \\/// The language the messages are written in first.
        \\
    );
    try writer.print("pub const source = \"{f}\";\n", .{std.zig.fmtString(catalog.source)});
    try writer.writeAll("/// The languages of the catalogs: the source, then the others.\npub const languages = [_][]const u8{");
    for (catalog.languages, 0..) |tag, index| try writer.print("{s}\"{f}\"", .{ if (index > 0) ", " else " ", std.zig.fmtString(tag) });
    try writer.writeAll(" };\n\n/// The messages of each language of `languages`, as `i18n.Catalog.addEntries` takes them.\npub const bundles = [_][]const i18n.Entry{\n");
    for (catalog.languages) |tag| {
        const file = catalog.files.get(tag).?;
        try writer.writeAll("    &.{\n");
        for (catalog.keys) |entry| {
            const message = file.messages.get(entry.name) orelse continue;
            if (!file.usage.contains(entry.name)) continue;
            try writer.print("        .{{ .key = \"{f}\", .message = \"{f}\" }},\n", .{ std.zig.fmtString(entry.name), std.zig.fmtString(message) });
        }
        try writer.writeAll("    },\n");
    }
    try writer.writeAll(
        \\};
        \\
        \\comptime {
        \\    for (bundles) |entries| i18n.catalog.comptimeValidate(entries);
        \\}
        \\
        \\/// A catalog of every language, which borrows the messages. Caller deinits.
        \\pub fn catalog(allocator: std.mem.Allocator) i18n.catalog.AddError!i18n.Catalog {
        \\    var result = i18n.Catalog.init(allocator, i18n.Locale.parse(source) catch unreachable);
        \\    errdefer result.deinit();
        \\    for (languages, bundles) |tag, entries| try result.addEntries(i18n.Locale.parse(tag) catch unreachable, entries, null);
        \\    return result;
        \\}
        \\
        \\/// Says the messages in the language of a Localizer of `catalog()`.
        \\pub const Messages = struct {
        \\    localizer: *const i18n.Localizer,
        \\
        \\    pub fn in(localizer: *const i18n.Localizer) Messages {
        \\        return .{ .localizer = localizer };
        \\    }
        \\
    );
    for (catalog.keys) |entry| {
        try writer.writeAll("\n    /// `");
        try writeOneLine(writer, entry.message, "`", "'");
        try writer.writeAll("`\n");
        if (entry.description.len > 0) {
            try writer.writeAll("    ///\n");
            var lines = std.mem.tokenizeScalar(u8, entry.description, '\n');
            while (lines.next()) |line| try writer.print("    /// {s}\n", .{std.mem.trim(u8, line, " \t\r")});
        }
        try writer.print("    pub fn {f}(self: Messages, writer: *std.Io.Writer", .{std.zig.fmtId(entry.name)});
        for (entry.params) |param| try writer.print(", {f}: {s}", .{ std.zig.fmtId(param.zig), param.type.zig() });
        try writer.print(") i18n.catalog.FormatError!void {{\n        return self.localizer.format(writer, \"{f}\", &.{{", .{std.zig.fmtString(entry.name)});
        for (entry.params, 0..) |param, index| {
            try writer.print("{s}.{{ .name = \"{f}\", .value = ", .{ if (index > 0) ", " else " ", std.zig.fmtString(param.name) });
            const value = switch (param.type) {
                .String => ".{ .string = ",
                .int => ".{ .int = ",
                .double, .num => ".{ .float = ",
                .DateTime => ".{ .instant = ",
                .Object => "",
            };
            try writer.print("{s}{f}{s} }}", .{ value, std.zig.fmtId(param.zig), if (value.len > 0) " }" else "" });
        }
        try writer.writeAll(if (entry.params.len > 0) " });\n    }\n" else "});\n    }\n");
    }
    try writer.writeAll("};\n");
}

/// `writeZig`'s output as `zig fmt` lays it out. Caller frees.
pub fn formattedZig(allocator: std.mem.Allocator, catalog: *const Catalog) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeZig(&out.writer, catalog);
    const source = try out.toOwnedSliceSentinel(0);
    defer allocator.free(source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len > 0) return error.InvalidGeneratedCode;
    return tree.renderAlloc(allocator);
}

/// `text` on one line, `bad` replaced by `good`.
fn writeOneLine(writer: *std.Io.Writer, text: []const u8, bad: []const u8, good: []const u8) !void {
    var rest = text;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, bad)) {
            try writer.writeAll(good);
            rest = rest[bad.len..];
            continue;
        }
        try writer.writeByte(if (rest[0] == '\n' or rest[0] == '\r') ' ' else rest[0]);
        rest = rest[1..];
    }
}

// ---------------------------------------------------------------- TypeScript

/// The TypeScript module of a catalog without errors: the messages of
/// every language, bundled with the page so its first paint is in the
/// right language, which `@ziggurat/runtime/i18n` formats, with a typed
/// function per key.
pub fn writeTypeScript(writer: *std.Io.Writer, catalog: *const Catalog) !void {
    try writer.writeAll(
        \\// Generated by `ziggurat generate` from the catalogs of the app. Do not edit.
        \\import { createCatalog } from "@ziggurat/runtime/i18n";
        \\
        \\/** The messages of the app in one language. */
        \\export interface Messages {
        \\
    );
    for (catalog.keys) |entry| {
        try writer.writeAll("  /**\n");
        if (entry.description.len > 0) {
            var lines = std.mem.tokenizeScalar(u8, entry.description, '\n');
            while (lines.next()) |line| {
                try writer.writeAll("   * ");
                try writeOneLine(writer, std.mem.trim(u8, line, " \t\r"), "*/", "*\\/");
                try writer.writeByte('\n');
            }
            try writer.writeAll("   *\n");
        }
        try writer.writeAll("   * `");
        try writeOneLine(writer, entry.message, "*/", "*\\/");
        try writer.print("`\n   */\n  {s}(", .{entry.name});
        for (entry.params, 0..) |param, index| try writer.print("{s}{s}: {s}", .{ if (index > 0) ", " else "", param.typescript, param.type.typescript() });
        try writer.writeAll("): string;\n");
    }
    try writer.print("}}\n\nconst catalog = createCatalog({{\n  source: {f},\n  params: {{\n", .{std.json.fmt(catalog.source, .{})});
    for (catalog.keys) |entry| {
        try writer.print("    {f}: [", .{std.json.fmt(entry.name, .{})});
        for (entry.params, 0..) |param, index| try writer.print("{s}{f}", .{ if (index > 0) ", " else "", std.json.fmt(param.name, .{}) });
        try writer.writeAll("],\n");
    }
    try writer.writeAll("  },\n  messages: {\n");
    for (catalog.languages) |tag| {
        const file = catalog.files.get(tag).?;
        try writer.print("    {f}: {{\n", .{std.json.fmt(tag, .{})});
        for (catalog.keys) |entry| {
            const message = file.messages.get(entry.name) orelse continue;
            if (!file.usage.contains(entry.name)) continue;
            try writer.print("      {f}: {f},\n", .{ std.json.fmt(entry.name, .{}), std.json.fmt(message, .{}) });
        }
        try writer.writeAll("    },\n");
    }
    try writer.writeAll(
        \\  },
        \\});
        \\
        \\/**
        \\ * The messages in the language the page shows. Each call says its
        \\ * message in the language of the moment.
        \\ */
        \\export const messages: Messages = catalog.messages<Messages>();
        \\
        \\/** The messages in the language of `locale`, as "de" or "zh-Hant". */
        \\export const messagesIn = (locale: string): Messages => catalog.messagesIn<Messages>(locale);
        \\
        \\/** The languages of the catalogs: the source language, then the others. */
        \\export const languages: readonly string[] = catalog.locales;
        \\
    );
}

// ---------------------------------------------------------------- tests

fn loadText(arena: std.mem.Allocator, files: []const [2][]const u8, options: Options) !Catalog {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    for (files) |file| try temp.dir.writeFile(.{ .sub_path = file[0], .data = file[1] });
    return load(arena, temp.dir, options);
}

fn expectDiagnostics(catalog: *const Catalog, expected: []const []const u8) !void {
    var all: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer all.deinit();
    for (catalog.diagnostics) |d| try all.writer.print("{f}\n", .{d});
    var want: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    for (expected) |line| try want.writer.print("{s}\n", .{line});
    try std.testing.expectEqualStrings(want.written(), all.written());
}

const english =
    \\{
    \\  "@@locale": "en",
    \\  "greeting": "Hello, {name}!",
    \\  "@greeting": {"description": "Shown on the start page."},
    \\  "files": "{count, plural, =0 {No files} one {# file} other {# files}}",
    \\  "@files": {"placeholders": {"count": {"type": "int"}}},
    \\  "saved": "Saved {when, date, short}"
    \\}
;

test "catalogs load in order with parameters typed by use and declaration" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const catalog = try loadText(arena_state.allocator(), &.{
        .{ "en.json", english },
        .{ "de.json", "{\"greeting\": \"Hallo, {name}!\", \"files\": \"{count, plural, one {# Datei} other {# Dateien}}\"}" },
    }, .{});
    try expectDiagnostics(&catalog, &.{"locales/de.json: warning: 1 of 3 messages missing, which say the language they fall back to: saved"});
    try std.testing.expectEqualStrings("en", catalog.languages[0]);
    try std.testing.expectEqualStrings("de", catalog.languages[1]);
    try std.testing.expectEqual(@as(usize, 3), catalog.keys.len);
    try std.testing.expectEqualStrings("Shown on the start page.", catalog.keys[0].description);
    try std.testing.expectEqual(Type.String, catalog.keys[0].params[0].type);
    try std.testing.expectEqual(Type.int, catalog.keys[1].params[0].type);
    try std.testing.expectEqual(Type.DateTime, catalog.keys[2].params[0].type);
}

test "problems are diagnosed with their lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const catalog = try loadText(arena_state.allocator(), &.{
        .{ "en.json", english },
        .{
            "ru.json",
            \\{
            \\  "greeting": "Привет, {who}!",
            \\  "files": "{count, plural, one {# файл} two {# файла} other {# файлов}}",
            \\  "saved": "{when, select, other {x}}",
            \\  "extra": "x",
            \\  "broken": "{oops"
            \\}
        },
        .{ "EN-us.json", "{}" },
        .{ "en-XA.json", "{}" },
    }, .{});
    try expectDiagnostics(&catalog, &.{
        "locales/EN-us.json: the name of a catalog is a BCP 47 tag in its canonical form, as en.json or zh-Hant.json: rename it en-US.json",
        "locales/en-XA.json: en-XA is a pseudo locale, made from the source language: remove the file",
        "locales/ru.json:2: \"greeting\" uses the argument who, but the source message has the arguments name",
        "locales/ru.json:2: warning: \"greeting\" does not use the argument name",
        "locales/ru.json:3: warning: \"files\": ru has no plural category two (its plural categories are one, few, many, other)",
        "locales/ru.json:3: warning: \"files\": the plural argument count lacks few, many, the categories of ru, which says other in its place",
        "locales/ru.json:4: \"saved\" uses when as a select argument, which its type DateTime cannot be",
        "locales/ru.json:5: \"extra\" is not a key of locales/en.json",
        "locales/ru.json:6: \"broken\" is not a valid message: check its braces, the other case of each plural and select, and the kinds of arguments",
        "locales/ru.json:6: \"broken\" is not a key of locales/en.json",
    });
    try std.testing.expectEqual(@as(usize, 7), catalog.errors());
}

test "source problems: bad keys, declared types and a missing source" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = try loadText(arena, &.{.{
        "en.json",
        \\{
        \\  "a-b": "x",
        \\  "count": "{n, number}",
        \\  "@count": {"placeholders": {"n": {"type": "String"}, "unused": {}}},
        \\  "@ghost": {},
        \\  "count": "again",
        \\  "in": "x"
        \\}
    }}, .{});
    try expectDiagnostics(&catalog, &.{
        "locales/en.json:2: \"a-b\" is not a key: a letter, then letters, digits and _, as filesSelected",
        "locales/en.json:3: \"count\" uses n as a number argument, which its type String cannot be",
        "locales/en.json:4: warning: @count declares the placeholder unused, which the message does not use",
        "locales/en.json:5: warning: @ghost describes no message",
        "locales/en.json:6: \"count\" comes twice",
        "locales/en.json:7: \"in\" would name its Zig function as a declaration of the generated code",
    });
    const missing = try loadText(arena, &.{.{ "de.json", "{}" }}, .{ .dir_name = "i18n" });
    try expectDiagnostics(&missing, &.{"i18n/en.json: missing: it holds the messages of the source language, en"});
    const bad_source = try loadText(arena, &.{}, .{ .source = "EN" });
    try expectDiagnostics(&bad_source, &.{"locales: the source language \"EN\" is not a BCP 47 tag in its canonical form, as en, de-CH or zh-Hans"});
}

test "the Zig accessors are formatted Zig and the TypeScript module follows the runtime's catalog" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = try loadText(arena, &.{
        .{
            "en.json",
            \\{
            \\  "greeting": "Hello, {name}! `x` */",
            \\  "@greeting": {"description": "Shown first."},
            \\  "files": "{count, plural, one {# file} other {# files}}",
            \\  "error": "{fn} {u8}"
            \\}
        },
        .{ "de.json", "{\"greeting\": \"Hallo, {name}!\"}" },
    }, .{});
    try std.testing.expectEqual(@as(usize, 0), catalog.errors());
    const source = try formattedZig(arena, &catalog);
    const again = try std.zig.Ast.parse(arena, try arena.dupeZ(u8, source), .zig);
    try std.testing.expectEqualStrings(source, try again.renderAlloc(arena));
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn files(self: Messages, writer: *std.Io.Writer, count: i64) i18n.catalog.FormatError!void {\n        return self.localizer.format(writer, \"files\", &.{.{ .name = \"count\", .value = .{ .int = count } }});") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn @\"error\"(self: Messages, writer: *std.Io.Writer, fn_: []const u8, u8_: []const u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "    /// `Hello, {name}! 'x' */`\n    ///\n    /// Shown first.\n") != null);
    var typescript: std.Io.Writer.Allocating = .init(arena);
    try writeTypeScript(&typescript.writer, &catalog);
    const module = typescript.written();
    try std.testing.expect(std.mem.indexOf(u8, module, "import { createCatalog } from \"@ziggurat/runtime/i18n\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, module, "   * Shown first.\n   *\n   * `Hello, {name}! `x` *\\/`\n   */\n  greeting(name: string): string;") != null);
    try std.testing.expect(std.mem.indexOf(u8, module, "  error(fn: string, u8: string): string;") != null);
    try std.testing.expect(std.mem.indexOf(u8, module, "  params: {\n    \"greeting\": [\"name\"],\n    \"files\": [\"count\"],\n    \"error\": [\"fn\", \"u8\"],\n  },") != null);
    try std.testing.expect(std.mem.indexOf(u8, module, "    \"de\": {\n      \"greeting\": \"Hallo, {name}!\",\n    },") != null);
    try std.testing.expect(std.mem.indexOf(u8, module, "export const languages: readonly string[] = catalog.locales;") != null);
}
