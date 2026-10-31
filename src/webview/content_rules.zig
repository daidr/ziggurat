//! Content rules in the WebKit content blocker format: a JSON array of rules,
//! each a trigger and an action. This module parses and matches them for the
//! engines without native content blockers (WebView2), and validates ids and
//! names compiled lists for the engines that keep them (WebKitGTK).
//!
//! Parsing is pure and may run on any thread. A parsed `List` is immutable
//! except for its matching scratch: match a list from one thread at a time.
const std = @import("std");
const zio = @import("ziggurat_io");

pub const max_id_bytes = 64;
/// Hexadecimal digits of the rules' hash in a list's identifier.
pub const hash_digits = 16;
/// The identifier of a list: the id, "-", and a hash of its rules.
pub const max_identifier_bytes = max_id_bytes + 1 + hash_digits;

/// The resource-type names a trigger may list, as bits.
pub const Type = struct {
    pub const document: u16 = 1 << 0;
    pub const image: u16 = 1 << 1;
    pub const style_sheet: u16 = 1 << 2;
    pub const script: u16 = 1 << 3;
    pub const font: u16 = 1 << 4;
    pub const raw: u16 = 1 << 5;
    pub const svg_document: u16 = 1 << 6;
    pub const media: u16 = 1 << 7;
    pub const popup: u16 = 1 << 8;
    pub const ping: u16 = 1 << 9;
    pub const fetch: u16 = 1 << 10;
    pub const websocket: u16 = 1 << 11;
    pub const other: u16 = 1 << 12;

    fn named(name: []const u8) u16 {
        const names = [_]struct { []const u8, u16 }{
            .{ "document", document },         .{ "image", image }, .{ "style-sheet", style_sheet },
            .{ "script", script },             .{ "font", font },   .{ "raw", raw },
            .{ "svg-document", svg_document }, .{ "media", media }, .{ "popup", popup },
            .{ "ping", ping },                 .{ "fetch", fetch }, .{ "websocket", websocket },
            .{ "other", other },
        };
        for (names) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
        return 0;
    }
};

const Action = enum { block, block_cookies, make_https, hide, ignore_previous };

fn actionNamed(name: []const u8) ?Action {
    if (std.mem.eql(u8, name, "block")) return .block;
    if (std.mem.eql(u8, name, "block-cookies")) return .block_cookies;
    if (std.mem.eql(u8, name, "make-https")) return .make_https;
    if (std.mem.eql(u8, name, "css-display-none")) return .hide;
    if (std.mem.eql(u8, name, "ignore-previous-rules")) return .ignore_previous;
    return null;
}

/// Why a list did not parse, and the index of the rule at fault.
pub const Failure = struct {
    reason: Reason,
    /// Null for failures of the whole list.
    rule: ?u32 = null,

    pub const Reason = enum {
        /// Not JSON, or not an array of objects.
        not_rule_array,
        no_rules,
        missing_url_filter,
        invalid_action,
        missing_selector,
        /// Outside WebKit's subset: alternatives, counted repetitions,
        /// classes such as \d, "^" but at the start, or not ASCII.
        unsupported_regex,
        invalid_regex,
        invalid_resource_type,
        invalid_load_type,
        /// More than one of if-domain, unless-domain, if-top-url, unless-top-url.
        conflicting_conditions,
        /// Domains must be lowercase ASCII (punycode).
        invalid_domain,
        /// The engine compiles the rules itself and rejected them (Linux).
        rejected_by_engine,
    };
};

pub const ParseError = error{ InvalidContentRules, OutOfMemory };

/// Reports whether id names a list: 1 to 64 letters, digits, "-", "_" and ".".
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_bytes) return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

/// Writes the identifier the engine keeps the list compiled from rules for
/// id under: the id and a hash of the rules, so that the same rules load
/// later without compiling and changed rules compile again.
pub fn identifier(id: []const u8, rules: []const u8, out: *[max_identifier_bytes]u8) []u8 {
    std.debug.assert(validId(id));
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rules, &digest, .{});
    @memcpy(out[0..id.len], id);
    out[id.len] = '-';
    const hex = std.fmt.bytesToHex(digest[0 .. hash_digits / 2], .lower);
    @memcpy(out[id.len + 1 ..][0..hash_digits], &hex);
    return out[0 .. id.len + 1 + hash_digits];
}

/// Reports whether name is an identifier of a list compiled for id from
/// other rules than current, the identifier of the rules now compiled.
pub fn staleIdentifier(id: []const u8, current: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, current)) return false;
    if (name.len != id.len + 1 + hash_digits or !std.mem.startsWith(u8, name, id) or name[id.len] != '-') return false;
    for (name[id.len + 1 ..]) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

// Regular expressions -------------------------------------------------------

/// WebKit's URL filter subset: literals, ".", classes "[...]", groups "(...)",
/// the quantifiers "*", "+" and "?", "^" at the start and "$". Matching runs
/// a Thompson automaton, so it takes time linear in the URL.
const Inst = struct {
    op: Op,
    a: u8 = 0,
    b: u8 = 0,
    x: u32 = 0,
    y: u32 = 0,
    const Op = enum(u8) { byte, any, set, split, jmp, eol, match };
};

const Regex = struct {
    start: u32,
    len: u32,
    anchored: bool,
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,
    fold: bool,
    insts: *std.ArrayListUnmanaged(Inst),
    sets: *std.ArrayListUnmanaged([32]u8),
    base: u32,

    const Error = error{ InvalidRegex, OutOfMemory };

    fn emit(self: *Compiler, inst: Inst) Error!u32 {
        const at: u32 = @intCast(self.insts.items.len - self.base);
        try self.insts.append(self.allocator, inst);
        return at;
    }
    fn here(self: *Compiler) u32 {
        return @intCast(self.insts.items.len - self.base);
    }
    fn instAt(self: *Compiler, pc: u32) *Inst {
        return &self.insts.items[self.base + pc];
    }

    /// Compiles a sequence up to ")" or the end. Returns the literal every
    /// match of it contains, as a slice of `literal` scratch.
    fn sequence(self: *Compiler, literal: *Literal) Error!void {
        var run: Literal = .{};
        while (self.pos < self.source.len and self.source[self.pos] != ')') {
            const atom_start = self.here();
            var atom_literal: Literal = .{};
            var single: ?u8 = null;
            const c = self.source[self.pos];
            switch (c) {
                '*', '+', '?' => return error.InvalidRegex, // nothing to repeat
                '(' => {
                    self.pos += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '?') return error.InvalidRegex;
                    try self.sequence(&atom_literal);
                    if (self.pos >= self.source.len) return error.InvalidRegex;
                    self.pos += 1;
                },
                '.' => {
                    self.pos += 1;
                    _ = try self.emit(.{ .op = .any });
                },
                '$' => {
                    self.pos += 1;
                    _ = try self.emit(.{ .op = .eol });
                    // An assertion takes no repetition.
                    if (self.pos < self.source.len and std.mem.indexOfScalar(u8, "*+?", self.source[self.pos]) != null) return error.InvalidRegex;
                    literal.take(&run);
                    run = .{};
                    continue;
                },
                '[' => try self.class(),
                '\\' => {
                    const escaped = try self.escape();
                    single = escaped;
                    try self.byte(escaped);
                },
                else => {
                    self.pos += 1;
                    single = c;
                    try self.byte(c);
                },
            }
            const repeat: u8 = if (self.pos < self.source.len and std.mem.indexOfScalar(u8, "*+?", self.source[self.pos]) != null) self.source[self.pos] else 0;
            if (repeat != 0) {
                self.pos += 1;
                // A lazy quantifier matches the same URLs.
                if (self.pos < self.source.len and self.source[self.pos] == '?') self.pos += 1;
                if (self.pos < self.source.len and std.mem.indexOfScalar(u8, "*+?", self.source[self.pos]) != null) return error.InvalidRegex;
                try self.repeatLast(atom_start, repeat);
            }
            if (repeat == 0 and single != null) {
                run.push(self.foldLower(single.?));
                continue;
            }
            literal.take(&run);
            run = .{};
            if (repeat == 0 or repeat == '+') {
                if (single) |byte_value| {
                    var one: Literal = .{};
                    one.push(self.foldLower(byte_value));
                    literal.take(&one);
                } else literal.take(&atom_literal);
            }
        }
        literal.take(&run);
    }

    fn foldLower(self: *Compiler, c: u8) u8 {
        return if (self.fold) std.ascii.toLower(c) else c;
    }

    fn byte(self: *Compiler, c: u8) Error!void {
        if (self.fold and std.ascii.isAlphabetic(c)) {
            _ = try self.emit(.{ .op = .byte, .a = std.ascii.toLower(c), .b = std.ascii.toUpper(c) });
        } else _ = try self.emit(.{ .op = .byte, .a = c, .b = c });
    }

    fn escape(self: *Compiler) Error!u8 {
        self.pos += 1;
        if (self.pos >= self.source.len) return error.InvalidRegex;
        const c = self.source[self.pos];
        self.pos += 1;
        return switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            else => if (std.ascii.isAlphanumeric(c)) error.InvalidRegex else c,
        };
    }

    fn class(self: *Compiler) Error!void {
        self.pos += 1;
        var set: [32]u8 = @splat(0);
        var negate = false;
        if (self.pos < self.source.len and self.source[self.pos] == '^') {
            negate = true;
            self.pos += 1;
        }
        var first = true;
        while (true) {
            if (self.pos >= self.source.len) return error.InvalidRegex;
            var lo = self.source[self.pos];
            if (lo == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            if (lo == '\\') lo = try self.escape() else self.pos += 1;
            var hi = lo;
            if (self.pos + 1 < self.source.len and self.source[self.pos] == '-' and self.source[self.pos + 1] != ']') {
                self.pos += 1;
                hi = self.source[self.pos];
                if (hi == '\\') hi = try self.escape() else self.pos += 1;
                if (hi < lo) return error.InvalidRegex;
            }
            var c: usize = lo;
            while (c <= hi) : (c += 1) {
                setBit(&set, @intCast(c));
                if (self.fold and std.ascii.isAlphabetic(@intCast(c))) {
                    setBit(&set, std.ascii.toLower(@intCast(c)));
                    setBit(&set, std.ascii.toUpper(@intCast(c)));
                }
            }
        }
        if (negate) {
            for (&set) |*b| b.* = ~b.*;
        }
        const index: u32 = @intCast(self.sets.items.len);
        try self.sets.append(self.allocator, set);
        _ = try self.emit(.{ .op = .set, .x = index });
    }

    /// Wraps the instructions from atom_start in the repetition.
    fn repeatLast(self: *Compiler, atom_start: u32, repeat: u8) Error!void {
        const atom_end = self.here();
        const atom_len = atom_end - atom_start;
        switch (repeat) {
            '+' => {
                // atom; split(atom_start, next)
                _ = try self.emit(.{ .op = .split, .x = atom_start, .y = atom_end + 1 });
            },
            '?', '*' => {
                // split(atom, after); atom; [jmp split]
                try self.insts.insert(self.allocator, self.base + atom_start, .{ .op = .split });
                self.shift(atom_start + 1, atom_end + 1, 1);
                const after = atom_end + 1 + @as(u32, if (repeat == '*') 1 else 0);
                self.instAt(atom_start).* = .{ .op = .split, .x = atom_start + 1, .y = after };
                if (repeat == '*') _ = try self.emit(.{ .op = .jmp, .x = atom_start });
                _ = atom_len;
            },
            else => unreachable,
        }
    }

    /// Moves the jump targets within [from, to) that point at or after from
    /// by delta, after inserting delta instructions at from - delta.
    fn shift(self: *Compiler, from: u32, to: u32, delta: u32) void {
        var pc = from;
        while (pc < to) : (pc += 1) {
            const moved = self.instAt(pc);
            if (moved.op == .split or moved.op == .jmp) {
                if (moved.x >= from - delta) moved.x += delta;
                if (moved.op == .split and moved.y >= from - delta) moved.y += delta;
            }
        }
    }
};

fn setBit(set: *[32]u8, c: u8) void {
    set[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
}
fn hasBit(set: *const [32]u8, c: u8) bool {
    return set[c >> 3] & (@as(u8, 1) << @intCast(c & 7)) != 0;
}

/// The longest literal found so far, kept inline: literals longer than the
/// buffer only lose prefiltering.
const Literal = struct {
    bytes: [48]u8 = undefined,
    len: u8 = 0,
    fn push(self: *Literal, c: u8) void {
        if (self.len == self.bytes.len) return;
        self.bytes[self.len] = c;
        self.len += 1;
    }
    fn take(self: *Literal, other: *const Literal) void {
        if (other.len > self.len) self.* = other.*;
    }
    fn slice(self: *const Literal) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Reports what of source WebKit's content blockers do not take:
/// alternatives, counted repetitions, classes as \d, "^" but at the start,
/// and other than ASCII.
fn webKitSubset(source: []const u8) bool {
    var in_class = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c >= 0x80) return false;
        if (c == '\\') {
            i += 1;
            if (i < source.len and std.mem.indexOfScalar(u8, "dDwWsSbB", source[i]) != null) return false;
            continue;
        }
        if (in_class) {
            in_class = c != ']';
            continue;
        }
        switch (c) {
            '[' => {
                in_class = true;
                if (i + 1 < source.len and source[i + 1] == '^') i += 1;
            },
            '|', '{' => return false,
            '^' => if (i > 0) return false,
            else => {},
        }
    }
    return true;
}

const Pattern = struct {
    regex: Regex,
    /// A string every match contains, lowercase unless sensitive.
    literal: []const u8,
    sensitive: bool,
};

// Lists ---------------------------------------------------------------------

const Party = enum(u2) { any, first, third };

const Rule = struct {
    filter: Pattern,
    types: u16,
    party: Party,
    action: Action,
    /// if-domain or unless-domain, and which.
    domains: []const []const u8,
    unless_domain: bool,
    /// if-top-url or unless-top-url, and which.
    top: []const Pattern,
    unless_top: bool,
};

/// A list of rules, parsed. Immutable but for its matching scratch.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    rules: []Rule,
    insts: []Inst,
    sets: [][32]u8,
    /// Rules whose url-filter matches only a domain and its subdomains, by
    /// that domain; those of the others with a literal of four bytes or more,
    /// by its least common four bytes; the rest, tried for every load.
    by_domain: std.StringHashMapUnmanaged([]const u32),
    by_gram: std.AutoHashMapUnmanaged(u32, []const u32),
    others: []const u32,
    /// The css-display-none and ignore-previous-rules rules, as JSON for
    /// `hidingScript`; empty when the list hides nothing.
    cosmetic: []const u8,
    /// Scratch of the automaton, sized for the longest program.
    threads: []u32,
    next_threads: []u32,
    stack: []u32,
    marks: []u32,
    mark: u32 = 0,

    pub fn deinit(self: *List) void {
        var arena = self.arena;
        arena.deinit();
    }

    /// Whether the list has css-display-none rules.
    pub fn hides(self: *const List) bool {
        return self.cosmetic.len != 0;
    }

    fn run(self: *List, regex: Regex, text: []const u8) bool {
        const prog = self.insts[regex.start..][0..regex.len];
        var current: usize = 0;
        self.nextMark();
        self.addThread(prog, self.threads, &current, 0, 0, text.len);
        var i: usize = 0;
        while (true) : (i += 1) {
            for (self.threads[0..current]) |pc| if (prog[pc].op == .match) return true;
            if (i == text.len) return false;
            const c = text[i];
            var next: usize = 0;
            self.nextMark();
            for (self.threads[0..current]) |pc| {
                const inst = prog[pc];
                const take = switch (inst.op) {
                    .byte => c == inst.a or c == inst.b,
                    .any => true,
                    .set => hasBit(&self.sets[inst.x], c),
                    else => false,
                };
                if (take) self.addThread(prog, self.next_threads, &next, pc + 1, i + 1, text.len);
            }
            if (!regex.anchored) self.addThread(prog, self.next_threads, &next, 0, i + 1, text.len);
            if (next == 0) return false;
            std.mem.swap([]u32, &self.threads, &self.next_threads);
            current = next;
        }
    }

    fn nextMark(self: *List) void {
        self.mark +%= 1;
        if (self.mark == 0) {
            @memset(self.marks, 0);
            self.mark = 1;
        }
    }

    fn addThread(self: *List, prog: []const Inst, list: []u32, count: *usize, start: u32, pos: usize, len: usize) void {
        var top: usize = 0;
        self.stack[top] = start;
        top += 1;
        while (top > 0) {
            top -= 1;
            const pc = self.stack[top];
            if (self.marks[pc] == self.mark) continue;
            self.marks[pc] = self.mark;
            const inst = prog[pc];
            switch (inst.op) {
                .jmp => {
                    self.stack[top] = inst.x;
                    top += 1;
                },
                .split => {
                    self.stack[top] = inst.y;
                    self.stack[top + 1] = inst.x;
                    top += 2;
                },
                .eol => if (pos == len) {
                    self.stack[top] = pc + 1;
                    top += 1;
                },
                else => {
                    list[count.*] = pc;
                    count.* += 1;
                },
            }
        }
    }

    fn patternMatches(self: *List, pattern: *const Pattern, text: []const u8, lower: []const u8) bool {
        if (pattern.literal.len != 0) {
            const in = if (pattern.sensitive) text else lower;
            if (std.mem.indexOf(u8, in, pattern.literal) == null) return false;
        }
        return self.run(pattern.regex, text);
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    insts: std.ArrayListUnmanaged(Inst) = .empty,
    sets: std.ArrayListUnmanaged([32]u8) = .empty,
    longest: u32 = 1,

    fn pattern(self: *Builder, source: []const u8, sensitive: bool) Compiler.Error!Pattern {
        const base: u32 = @intCast(self.insts.items.len);
        var compiler: Compiler = .{ .allocator = self.allocator, .source = source, .fold = !sensitive, .insts = &self.insts, .sets = &self.sets, .base = base };
        var anchored = false;
        if (source.len > 0 and source[0] == '^') {
            anchored = true;
            compiler.pos = 1;
        }
        var literal: Literal = .{};
        try compiler.sequence(&literal);
        if (compiler.pos != source.len) return error.InvalidRegex; // an unmatched ")"
        _ = try compiler.emit(.{ .op = .match });
        const len: u32 = @intCast(self.insts.items.len - base);
        self.longest = @max(self.longest, len);
        return .{ .regex = .{ .start = base, .len = len, .anchored = anchored }, .literal = try self.allocator.dupe(u8, literal.slice()), .sensitive = sensitive };
    }
};

/// The trigger of a css-display-none or ignore-previous-rules rule, as the
/// hiding script matches it against a document's URL.
const CosmeticEntry = struct {
    s: ?[]const []const u8 = null,
    u: ?[]const u8 = null,
    c: ?bool = null,
    d: ?[]const []const u8 = null,
    n: ?[]const []const u8 = null,
    t: ?[]const []const u8 = null,
    nt: ?[]const []const u8 = null,
    i: ?bool = null,

    fn sameTrigger(a: CosmeticEntry, b: CosmeticEntry) bool {
        return optionalEql(a.u, b.u) and a.c == b.c and listsEql(a.d, b.d) and listsEql(a.n, b.n) and listsEql(a.t, b.t) and listsEql(a.nt, b.nt);
    }
};

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
fn listsEql(a: ?[]const []const u8, b: ?[]const []const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    if (a.?.len != b.?.len) return false;
    for (a.?, b.?) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn stringList(arena: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const v = value orelse return null;
    if (v != .array) return error.WrongType;
    if (v.array.items.len == 0) return null;
    const out = try arena.alloc([]const u8, v.array.items.len);
    for (v.array.items, out) |item, *slot| {
        if (item != .string) return error.WrongType;
        slot.* = try arena.dupe(u8, item.string);
    }
    return out;
}

/// Parses rules, failing as WebKit does on what it would not compile. A rule
/// whose selector the engine cannot parse is kept: the engine skips it.
pub fn parse(allocator: std.mem.Allocator, rules: []const u8, failure: ?*Failure) ParseError!*List {
    var fail: Failure = .{ .reason = .not_rule_array };
    const list = parseInner(allocator, rules, &fail) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (failure) |out| out.* = fail;
        return error.InvalidContentRules;
    };
    return list;
}

const InnerError = error{ OutOfMemory, Invalid };

fn parseInner(allocator: std.mem.Allocator, rules: []const u8, fail: *Failure) InnerError!*List {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, rules, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failWith(fail, .not_rule_array, null),
    };
    if (parsed != .array) return failWith(fail, .not_rule_array, null);
    if (parsed.array.items.len == 0) return failWith(fail, .no_rules, null);

    var builder: Builder = .{ .allocator = arena };
    var kept: std.ArrayListUnmanaged(Rule) = .empty;
    var cosmetic: std.ArrayListUnmanaged(CosmeticEntry) = .empty;
    var by_domain: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .empty;
    var by_gram: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty;
    var others: std.ArrayListUnmanaged(u32) = .empty;

    for (parsed.array.items, 0..) |raw, index_usize| {
        const index: u32 = @intCast(index_usize);
        if (raw != .object) return failWith(fail, .not_rule_array, null);
        const trigger = raw.object.get("trigger") orelse return failWith(fail, .missing_url_filter, index);
        const action_value = raw.object.get("action") orelse return failWith(fail, .invalid_action, index);
        if (trigger != .object) return failWith(fail, .missing_url_filter, index);
        if (action_value != .object) return failWith(fail, .invalid_action, index);
        const action_type = action_value.object.get("type") orelse return failWith(fail, .invalid_action, index);
        if (action_type != .string) return failWith(fail, .invalid_action, index);
        const action = actionNamed(action_type.string) orelse return failWith(fail, .invalid_action, index);
        var selector: []const u8 = "";
        if (action_value.object.get("selector")) |value| {
            if (value != .string) return failWith(fail, .invalid_action, index);
            selector = value.string;
        }
        if (action == .hide and std.mem.trim(u8, selector, " \t\r\n").len == 0) return failWith(fail, .missing_selector, index);

        const t = trigger.object;
        const filter_value = t.get("url-filter") orelse return failWith(fail, .missing_url_filter, index);
        if (filter_value != .string) return failWith(fail, .missing_url_filter, index);
        const filter = filter_value.string;
        var sensitive = false;
        if (t.get("url-filter-is-case-sensitive")) |value| {
            if (value != .bool) return failWith(fail, .missing_url_filter, index);
            sensitive = value.bool;
        }
        const if_domain = stringList(arena, t.get("if-domain")) catch |err| return wrongType(err, fail, index);
        const unless_domain = stringList(arena, t.get("unless-domain")) catch |err| return wrongType(err, fail, index);
        const if_top = stringList(arena, t.get("if-top-url")) catch |err| return wrongType(err, fail, index);
        const unless_top = stringList(arena, t.get("unless-top-url")) catch |err| return wrongType(err, fail, index);
        const resource_types = stringList(scratch, t.get("resource-type")) catch |err| return wrongType(err, fail, index);
        const load_types = stringList(scratch, t.get("load-type")) catch |err| return wrongType(err, fail, index);

        var rule: Rule = .{ .filter = undefined, .types = 0, .party = .any, .action = action, .domains = &.{}, .unless_domain = false, .top = &.{}, .unless_top = false };
        if (!webKitSubset(filter)) return failWith(fail, .unsupported_regex, index);
        rule.filter = builder.pattern(filter, sensitive) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRegex => return failWith(fail, .invalid_regex, index),
        };
        if (resource_types) |names| for (names) |name| {
            const bit = Type.named(name);
            if (bit == 0) return failWith(fail, .invalid_resource_type, index);
            rule.types |= bit;
        };
        if (load_types) |names| {
            for (names) |name| {
                if (std.mem.eql(u8, name, "first-party")) rule.party = .first else if (std.mem.eql(u8, name, "third-party")) rule.party = .third else return failWith(fail, .invalid_load_type, index);
            }
            if (names.len > 1) rule.party = .any;
        }
        const conditions = @as(u8, @intFromBool(if_domain != null)) + @intFromBool(unless_domain != null) + @intFromBool(if_top != null) + @intFromBool(unless_top != null);
        if (conditions > 1) return failWith(fail, .conflicting_conditions, index);
        if (unless_domain) |domains| {
            rule.domains = domains;
            rule.unless_domain = true;
        } else if (if_domain) |domains| rule.domains = domains;
        for (rule.domains) |domain| for (domain) |c| {
            if (std.ascii.isUpper(c) or c >= 0x80) return failWith(fail, .invalid_domain, index);
        };
        if (if_top orelse unless_top) |sources| {
            rule.unless_top = unless_top != null;
            const patterns = try arena.alloc(Pattern, sources.len);
            for (sources, patterns) |source, *slot| {
                if (!webKitSubset(source)) return failWith(fail, .unsupported_regex, index);
                slot.* = builder.pattern(source, sensitive) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidRegex => return failWith(fail, .invalid_regex, index),
                };
            }
            rule.top = patterns;
        }

        if (action == .hide or action == .ignore_previous) {
            var entry: CosmeticEntry = .{
                .u = if (std.mem.eql(u8, filter, ".*") or filter.len == 0) null else try arena.dupe(u8, filter),
                .c = if (sensitive) true else null,
                .d = if_domain,
                .n = unless_domain,
                .t = if_top,
                .nt = unless_top,
            };
            if (action == .ignore_previous) {
                entry.i = true;
                try cosmetic.append(scratch, entry);
            } else {
                const owned = try arena.dupe(u8, selector);
                const last = if (cosmetic.items.len > 0) &cosmetic.items[cosmetic.items.len - 1] else null;
                if (last != null and last.?.i == null and last.?.sameTrigger(entry)) {
                    const selectors = try scratch.alloc([]const u8, last.?.s.?.len + 1);
                    @memcpy(selectors[0..last.?.s.?.len], last.?.s.?);
                    selectors[last.?.s.?.len] = owned;
                    last.?.s = selectors;
                } else {
                    const selectors = try scratch.alloc([]const u8, 1);
                    selectors[0] = owned;
                    entry.s = selectors;
                    try cosmetic.append(scratch, entry);
                }
                continue;
            }
        }

        const at: u32 = @intCast(kept.items.len);
        try kept.append(arena, rule);
        if (filterDomain(filter, scratch) catch return error.OutOfMemory) |domain| {
            const owned = try arena.dupe(u8, domain);
            const slot = try by_domain.getOrPut(scratch, owned);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(scratch, at);
        } else if (rarestGram(&by_gram, rule.filter.literal)) |gram_value| {
            const slot = try by_gram.getOrPut(scratch, gram_value);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(scratch, at);
        } else try others.append(scratch, at);
    }

    const list = try arena.create(List);
    list.* = .{
        .arena = undefined,
        .rules = kept.items,
        .insts = builder.insts.items,
        .sets = builder.sets.items,
        .by_domain = .empty,
        .by_gram = .empty,
        .others = try arena.dupe(u32, others.items),
        .cosmetic = "",
        .threads = try arena.alloc(u32, builder.longest),
        .next_threads = try arena.alloc(u32, builder.longest),
        .stack = try arena.alloc(u32, builder.longest * 2 + 2),
        .marks = try arena.alloc(u32, builder.longest),
    };
    @memset(list.marks, 0);
    var domains = by_domain.iterator();
    while (domains.next()) |entry| try list.by_domain.put(arena, entry.key_ptr.*, try arena.dupe(u32, entry.value_ptr.items));
    var grams = by_gram.iterator();
    while (grams.next()) |entry| try list.by_gram.put(arena, entry.key_ptr.*, try arena.dupe(u32, entry.value_ptr.items));
    for (cosmetic.items) |entry| if (entry.i == null) {
        list.cosmetic = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(cosmetic.items, .{ .emit_null_optional_fields = false })});
        break;
    };
    list.arena = arena_state;
    return list;
}

fn failWith(fail: *Failure, reason: Failure.Reason, rule: ?u32) InnerError {
    fail.* = .{ .reason = reason, .rule = rule };
    return error.Invalid;
}
fn wrongType(err: anyerror, fail: *Failure, rule: u32) InnerError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return failWith(fail, .missing_url_filter, rule);
}

fn gramOf(s: []const u8) u32 {
    return std.mem.readInt(u32, s[0..4], .little);
}

fn rarestGram(by_gram: *const std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)), literal: []const u8) ?u32 {
    if (literal.len < 4) return null;
    var lower: [48]u8 = undefined;
    const text = std.ascii.lowerString(lower[0..literal.len], literal);
    var best: u32 = 0;
    var count: usize = std.math.maxInt(usize);
    var i: usize = 0;
    while (i + 4 <= text.len) : (i += 1) {
        const g = gramOf(text[i..]);
        const n = if (by_gram.get(g)) |rules| rules.items.len else 0;
        if (n < count) {
            best = g;
            count = n;
        }
    }
    return best;
}

/// The url-filter prefix converters write for "a domain and its subdomains".
const domain_prefix = "^[^:]+://+([^:/]+\\.)?";

/// Returns the domain a url-filter matches only URLs of, with its
/// subdomains, if it starts as converters write those.
fn filterDomain(filter: []const u8, scratch: std.mem.Allocator) !?[]const u8 {
    if (!std.mem.startsWith(u8, filter, domain_prefix)) return null;
    var rest = filter[domain_prefix.len..];
    var domain: std.ArrayListUnmanaged(u8) = .empty;
    while (rest.len > 0) {
        const c = rest[0];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try domain.append(scratch, std.ascii.toLower(c));
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, rest, "\\.")) {
            try domain.append(scratch, '.');
            rest = rest[2..];
        } else break;
    }
    // The domain ends where the host does.
    for ([_][]const u8{ "[:/]", "[/:]", "/", ":" }) |end| {
        if (std.mem.startsWith(u8, rest, end)) {
            const after = rest[end.len..];
            if (after.len > 0 and (after[0] == '*' or after[0] == '?' or after[0] == '+')) continue;
            const d = domain.items;
            if (d.len > 0 and d[0] != '.' and d[d.len - 1] != '.') return d;
        }
    }
    return null;
}

// Matching -------------------------------------------------------------------

/// A load to match.
pub const Request = struct {
    /// What loads.
    url: []const u8,
    /// The page it loads for; the URL itself for a page. Empty means url.
    top_url: []const u8 = "",
    /// The kinds of resource it is, any of which a rule's resource-type may name.
    types: u16,
};

/// What the rules do to a load.
pub const Result = struct {
    block: bool = false,
    block_cookies: bool = false,
    make_https: bool = false,
};

/// Returns what the lists do to the load. Each list applies its rules in
/// order, and a list's ignore-previous-rules undoes only what its own earlier
/// rules did. Allocates only scratch, freed before returning.
pub fn match(allocator: std.mem.Allocator, lists: []const *List, request: Request) error{OutOfMemory}!Result {
    const top_url = if (request.top_url.len == 0) request.url else request.top_url;
    const url = try std.ascii.allocLowerString(allocator, request.url);
    defer allocator.free(url);
    const top = try std.ascii.allocLowerString(allocator, top_url);
    defer allocator.free(top);
    const host = urlHost(url);
    const top_host = urlHost(top);
    const third_party = !std.mem.eql(u8, site(host), site(top_host));
    var candidates: std.ArrayListUnmanaged(u32) = .empty;
    defer candidates.deinit(allocator);
    var out: Result = .{};
    for (lists) |list| {
        candidates.clearRetainingCapacity();
        var h = host;
        while (h.len > 0) {
            if (list.by_domain.get(h)) |rules| try candidates.appendSlice(allocator, rules);
            const dot = std.mem.indexOfScalar(u8, h, '.') orelse break;
            h = h[dot + 1 ..];
        }
        if (list.by_gram.count() > 0 and url.len >= 4) {
            var i: usize = 0;
            while (i + 4 <= url.len) : (i += 1) {
                if (list.by_gram.get(gramOf(url[i..]))) |rules| try candidates.appendSlice(allocator, rules);
            }
        }
        var order: []const u32 = list.others;
        if (candidates.items.len > 0) {
            try candidates.appendSlice(allocator, list.others);
            std.mem.sort(u32, candidates.items, {}, std.sort.asc(u32));
            var unique: usize = 0;
            for (candidates.items) |rule| {
                if (unique > 0 and candidates.items[unique - 1] == rule) continue;
                candidates.items[unique] = rule;
                unique += 1;
            }
            order = candidates.items[0..unique];
        }
        var result: Result = .{};
        for (order) |index| {
            const rule = &list.rules[index];
            if (!ruleMatches(list, rule, request.url, url, top_url, top, top_host, third_party, request.types)) continue;
            switch (rule.action) {
                .block => result.block = true,
                .block_cookies => result.block_cookies = true,
                .make_https => result.make_https = std.mem.startsWith(u8, url, "http:") or std.mem.startsWith(u8, url, "ws:"),
                .ignore_previous => result = .{},
                .hide => {},
            }
        }
        out.block = out.block or result.block;
        out.block_cookies = out.block_cookies or result.block_cookies;
        out.make_https = out.make_https or result.make_https;
    }
    return out;
}

fn ruleMatches(list: *List, rule: *const Rule, url: []const u8, url_lower: []const u8, top: []const u8, top_lower: []const u8, top_host: []const u8, third_party: bool, types: u16) bool {
    if (rule.types != 0 and rule.types & types == 0) return false;
    if ((rule.party == .first and third_party) or (rule.party == .third and !third_party)) return false;
    if (rule.domains.len > 0 and domainListed(rule.domains, top_host) == rule.unless_domain) return false;
    if (rule.top.len > 0) {
        var matched = false;
        for (rule.top) |*pattern| if (list.patternMatches(pattern, top, top_lower)) {
            matched = true;
            break;
        };
        if (matched == rule.unless_top) return false;
    }
    return list.patternMatches(&rule.filter, url, url_lower);
}

/// Reports whether host is one of domains, where "*" before a domain takes
/// its subdomains too.
fn domainListed(domains: []const []const u8, host: []const u8) bool {
    for (domains) |domain| {
        if (domain.len > 0 and domain[0] == '*') {
            const parent = domain[1..];
            if (std.mem.eql(u8, host, parent)) return true;
            if (host.len > parent.len and std.mem.endsWith(u8, host, parent) and host[host.len - parent.len - 1] == '.') return true;
        } else if (std.mem.eql(u8, host, domain)) return true;
    }
    return false;
}

/// Returns the host of a lowercase URL, without its port.
pub fn urlHost(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "";
    var rest = url[scheme_end + 3 ..];
    if (std.mem.indexOfAny(u8, rest, "/?#")) |end| rest = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (rest.len > 0 and rest[0] == '[') {
        if (std.mem.indexOfScalar(u8, rest, ']')) |end| return rest[0 .. end + 1];
    }
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| rest = rest[0..colon];
    if (rest.len > 0 and rest[rest.len - 1] == '.') rest = rest[0 .. rest.len - 1];
    return rest;
}

// Public suffixes ------------------------------------------------------------

const suffix_data = @embedFile("public_suffix.dat");
const SuffixKind = enum(u8) { normal, wildcard, exception };
var suffix_once = zio.once(loadSuffixes);
var suffixes: std.StringHashMapUnmanaged(SuffixKind) = .empty;
/// The parents of wildcard rules ("*.ck" as "ck"), apart: a parent may be a
/// rule of its own too.
var wildcards: std.StringHashMapUnmanaged(void) = .empty;

fn loadSuffixes() void {
    const allocator = std.heap.page_allocator;
    var lines = std.mem.splitScalar(u8, suffix_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (line[0] == '!') {
            suffixes.put(allocator, line[1..], .exception) catch {};
        } else if (std.mem.startsWith(u8, line, "*.")) {
            wildcards.put(allocator, line[2..], {}) catch {};
        } else {
            const slot = suffixes.getOrPut(allocator, line) catch continue;
            if (!slot.found_existing) slot.value_ptr.* = .normal;
        }
    }
}

/// Returns the public suffix of a lowercase host: the longest rule of the
/// Public Suffix List it ends with, an exception rule naming its parent, or
/// its last label when no rule matches.
pub fn publicSuffix(host: []const u8) []const u8 {
    suffix_once.call();
    var candidate = host;
    while (true) {
        const dot = std.mem.indexOfScalar(u8, candidate, '.');
        const parent = if (dot) |at| candidate[at + 1 ..] else "";
        if (suffixes.get(candidate)) |kind| return if (kind == .exception) parent else candidate;
        if (dot != null and wildcards.contains(parent)) return candidate;
        if (dot == null) return candidate;
        candidate = parent;
    }
}

/// Returns the registrable domain of a host, which tells first-party loads
/// from third-party ones: its public suffix and one more label, or the host
/// itself when it has none.
pub fn site(host: []const u8) []const u8 {
    if (host.len == 0 or host[0] == '.' or host[host.len - 1] == '.' or std.mem.indexOf(u8, host, "..") != null) return host;
    const suffix = publicSuffix(host);
    if (suffix.len >= host.len) return host;
    const before = host[0 .. host.len - suffix.len - 1];
    const dot = std.mem.lastIndexOfScalar(u8, before, '.') orelse return host;
    return host[dot + 1 ..];
}

// Hiding ---------------------------------------------------------------------

/// Returns JavaScript that hides, in a document of a page applying the lists,
/// the elements their css-display-none rules select for its URL, or null
/// when the lists hide nothing. Caller owns the result.
pub fn hidingScript(allocator: std.mem.Allocator, lists: []const *const List) error{OutOfMemory}!?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var any = false;
    for (lists) |list| {
        if (!list.hides()) continue;
        try out.appendSlice(allocator, if (any) "," else "(()=>{const lists=[");
        try out.appendSlice(allocator, list.cosmetic);
        any = true;
    }
    if (!any) return null;
    try out.appendSlice(allocator, "];");
    try out.appendSlice(allocator, hiding_body);
    try out.appendSlice(allocator, "})();");
    return try out.toOwnedSlice(allocator);
}

/// Hides what the lists select through a style sheet the document adopts:
/// it needs no element to exist yet, and stays when the page sets its own
/// adopted style sheets. It is the page's own style sheet, so an element's
/// inline style with !important wins over it. Domains are the top page's, as
/// the engines' content blockers take them; a frame of another origin knows
/// it by its referrer. Each selector is a rule of its own, so that one the
/// engine cannot parse leaves the others.
const hiding_body =
    \\const url=location.href;
    \\let top;try{top=window.top.location.href}catch(e){top=document.referrer||url}
    \\let host;try{host=new URL(top).hostname.toLowerCase().replace(/\.$/,"")}catch(e){host=location.hostname}
    \\const listed=ds=>ds.some(d=>d[0]==="*"?host===d.slice(1)||host.endsWith("."+d.slice(1)):host===d);
    \\const test=(src,s,c)=>new RegExp(src,c?"":"i").test(s);
    \\const css=[];
    \\for(const list of lists){let hidden=[];for(const e of list){
    \\if(e.u&&!test(e.u,url,e.c))continue;
    \\if(e.d&&!listed(e.d)||e.n&&listed(e.n))continue;
    \\if(e.t&&!e.t.some(t=>test(t,top,e.c))||e.nt&&e.nt.some(t=>test(t,top,e.c)))continue;
    \\if(e.i)hidden=[];else hidden.push(...e.s)}
    \\for(const s of hidden)css.push(s+"{display:none!important}")}
    \\if(css.length===0)return;
    \\const sheet=new CSSStyleSheet();
    \\for(const rule of css){try{sheet.insertRule(rule,sheet.cssRules.length)}catch(e){}}
    \\const adopted=Object.getOwnPropertyDescriptor(Document.prototype,"adoptedStyleSheets");
    \\adopted.set.call(document,[...adopted.get.call(document),sheet]);
    \\Object.defineProperty(document,"adoptedStyleSheets",{configurable:true,enumerable:true,
    \\get(){return adopted.get.call(this)},
    \\set(v){adopted.set.call(this,Array.prototype.includes.call(v,sheet)?v:[...v,sheet])}});
;

// Tests ------------------------------------------------------------------------

const testing = std.testing;

fn expectMatch(list: *List, url: []const u8, top: []const u8, types: u16, expected: Result) !void {
    const got = try match(testing.allocator, &.{list}, .{ .url = url, .top_url = top, .types = types });
    try testing.expectEqual(expected, got);
}

test "ids and identifiers" {
    try testing.expect(validId("easy-list_1.0"));
    try testing.expect(!validId(""));
    try testing.expect(!validId("a b"));
    try testing.expect(!validId(&@as([65]u8, @splat('x'))));
    var buffer: [max_identifier_bytes]u8 = undefined;
    const name = identifier("ads", "[]", &buffer);
    try testing.expectEqual(@as(usize, 3 + 1 + hash_digits), name.len);
    try testing.expect(std.mem.startsWith(u8, name, "ads-"));
    var other: [max_identifier_bytes]u8 = undefined;
    const changed = identifier("ads", "[ ]", &other);
    try testing.expect(staleIdentifier("ads", name, changed));
    try testing.expect(!staleIdentifier("ads", name, name));
    try testing.expect(!staleIdentifier("ad", name, changed));
    try testing.expect(!staleIdentifier("ads", name, "ads-zzzzzzzzzzzzzzzz"));
}

test "regular expressions of the WebKit subset" {
    const cases = [_]struct { []const u8, bool, []const u8, bool }{
        .{ "ads", false, "https://x.com/ADS/1", true },
        .{ "ads", true, "https://x.com/ADS/1", false },
        .{ "^https?://", false, "http://a", true },
        .{ "^https?://", false, "ftp://http://", false },
        .{ "\\.js$", false, "https://a/b.js", true },
        .{ "\\.js$", false, "https://a/b.json", false },
        .{ "a[0-9]+b", false, "xa123b", true },
        .{ "a[0-9]+b", false, "xab", false },
        .{ "a[^/]*c", false, "a/c", false },
        .{ "a[^/]*c", false, "abbc", true },
        .{ "(ab)+c", false, "xababc", true },
        .{ "(ab)+c", false, "xac", false },
        .{ "x(ab)?c", false, "xc", true },
        .{ "x(ab)*c", false, "xababababc", true },
        .{ ".*", false, "", true },
        .{ "(a*)*b", false, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac", false },
        .{ "[A-C]x", false, "bX", true },
        .{ "[]a]", false, "]", true },
    };
    for (cases) |case| {
        const json = try std.fmt.allocPrint(testing.allocator, "[{{\"trigger\":{{\"url-filter\":{f},\"url-filter-is-case-sensitive\":{}}},\"action\":{{\"type\":\"block\"}}}}]", .{ std.json.fmt(case[0], .{}), case[1] });
        defer testing.allocator.free(json);
        const list = try parse(testing.allocator, json, null);
        defer list.deinit();
        const got = try match(testing.allocator, &.{list}, .{ .url = case[2], .types = Type.script });
        testing.expectEqual(case[3], got.block) catch |err| {
            std.debug.print("{s} against {s}\n", .{ case[0], case[2] });
            return err;
        };
    }
}

test "rules WebKit would not compile fail the list" {
    const bad = [_]struct { []const u8, Failure.Reason, ?u32 }{
        .{ "", .not_rule_array, null },
        .{ "{}", .not_rule_array, null },
        .{ "[]", .no_rules, null },
        .{ "[{\"trigger\":{\"url-filter\":\"a|b\"},\"action\":{\"type\":\"block\"}}]", .unsupported_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"a{2}\"},\"action\":{\"type\":\"block\"}}]", .unsupported_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"\\\\d\"},\"action\":{\"type\":\"block\"}}]", .unsupported_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"a^\"},\"action\":{\"type\":\"block\"}}]", .unsupported_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"é\"},\"action\":{\"type\":\"block\"}}]", .unsupported_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"(a\"},\"action\":{\"type\":\"block\"}}]", .invalid_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"a)\"},\"action\":{\"type\":\"block\"}}]", .invalid_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"*a\"},\"action\":{\"type\":\"block\"}}]", .invalid_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"a**\"},\"action\":{\"type\":\"block\"}}]", .invalid_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"[b-a]\"},\"action\":{\"type\":\"block\"}}]", .invalid_regex, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{},\"action\":{\"type\":\"block\"}}]", .missing_url_filter, 1 },
        .{ "[{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"nope\"}}]", .invalid_action, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"css-display-none\"}}]", .missing_selector, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"x\",\"resource-type\":[\"video\"]},\"action\":{\"type\":\"block\"}}]", .invalid_resource_type, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"x\",\"load-type\":[\"own\"]},\"action\":{\"type\":\"block\"}}]", .invalid_load_type, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"x\",\"if-domain\":[\"a.com\"],\"unless-domain\":[\"b.com\"]},\"action\":{\"type\":\"block\"}}]", .conflicting_conditions, 0 },
        .{ "[{\"trigger\":{\"url-filter\":\"x\",\"if-domain\":[\"A.com\"]},\"action\":{\"type\":\"block\"}}]", .invalid_domain, 0 },
    };
    for (bad) |case| {
        var failure: Failure = undefined;
        testing.expectError(error.InvalidContentRules, parse(testing.allocator, case[0], &failure)) catch |err| {
            std.debug.print("{s}\n", .{case[0]});
            return err;
        };
        try testing.expectEqual(case[1], failure.reason);
        try testing.expectEqual(case[2], failure.rule);
    }
    // A selector the engine cannot parse is the engine's to skip.
    const list = try parse(testing.allocator, "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"css-display-none\",\"selector\":\"a[[[\"}},{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"block\"}}]", null);
    list.deinit();
}

test "triggers narrow loads by type, party, domain and page" {
    const list = try parse(testing.allocator,
        \\[{"trigger":{"url-filter":"/ads/","resource-type":["script"]},"action":{"type":"block"}},
        \\ {"trigger":{"url-filter":"track","load-type":["third-party"]},"action":{"type":"block"}},
        \\ {"trigger":{"url-filter":"cookie","if-domain":["*example.com"]},"action":{"type":"block-cookies"}},
        \\ {"trigger":{"url-filter":"^http://secure\\.test/"},"action":{"type":"make-https"}},
        \\ {"trigger":{"url-filter":"pixel","unless-top-url":["^https://trusted\\.org/"]},"action":{"type":"block"}},
        \\ {"trigger":{"url-filter":"/ads/allowed"},"action":{"type":"ignore-previous-rules"}}]
    , null);
    defer list.deinit();
    try expectMatch(list, "https://a.com/ads/x.js", "https://a.com/", Type.script, .{ .block = true });
    try expectMatch(list, "https://a.com/ads/x.png", "https://a.com/", Type.image, .{});
    try expectMatch(list, "https://a.com/ads/allowed.js", "https://a.com/", Type.script, .{});
    try expectMatch(list, "https://cdn.a.com/track.js", "https://www.a.com/", Type.script, .{});
    try expectMatch(list, "https://b.net/track.js", "https://www.a.com/", Type.script, .{ .block = true });
    try expectMatch(list, "https://x.org/cookie", "https://sub.example.com/", Type.raw, .{ .block_cookies = true });
    try expectMatch(list, "https://x.org/cookie", "https://example.com/", Type.raw, .{ .block_cookies = true });
    try expectMatch(list, "https://x.org/cookie", "https://notexample.com/", Type.raw, .{});
    try expectMatch(list, "http://secure.test/a", "", Type.document, .{ .make_https = true });
    try expectMatch(list, "https://img.org/pixel.gif", "https://news.org/", Type.image, .{ .block = true });
    try expectMatch(list, "https://img.org/pixel.gif", "https://trusted.org/a", Type.image, .{});
}

test "indexed rules keep their order" {
    const list = try parse(testing.allocator,
        \\[{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[/:]"},"action":{"type":"block"}},
        \\ {"trigger":{"url-filter":"banner-image"},"action":{"type":"block"}},
        \\ {"trigger":{"url-filter":".*","if-domain":["safe.org"]},"action":{"type":"ignore-previous-rules"}}]
    , null);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.by_domain.count());
    try testing.expectEqual(@as(usize, 1), list.by_gram.count());
    try expectMatch(list, "https://cdn.ads.example.com/x", "https://news.org/", Type.image, .{ .block = true });
    try expectMatch(list, "https://ads.example.com:8080/x", "https://news.org/", Type.image, .{ .block = true });
    try expectMatch(list, "https://ads.example.community/x", "https://news.org/", Type.image, .{});
    try expectMatch(list, "https://x.org/BANNER-IMAGE.png", "https://news.org/", Type.image, .{ .block = true });
    try expectMatch(list, "https://ads.example.com/x", "https://safe.org/", Type.image, .{});
    // Lists apply independently: one list's ignore-previous-rules leaves another's.
    const other = try parse(testing.allocator, "[{\"trigger\":{\"url-filter\":\"ads\"},\"action\":{\"type\":\"block\"}}]", null);
    defer other.deinit();
    const both = try match(testing.allocator, &.{ other, list }, .{ .url = "https://ads.example.com/x", .top_url = "https://safe.org/", .types = Type.image });
    try testing.expect(both.block);
}

test "registrable domains" {
    try testing.expectEqualStrings("example.com", site("www.example.com"));
    try testing.expectEqualStrings("example.co.uk", site("a.b.example.co.uk"));
    try testing.expectEqualStrings("co.uk", site("co.uk"));
    try testing.expectEqualStrings("user.github.io", site("x.user.github.io"));
    try testing.expectEqualStrings("localhost", site("localhost"));
    try testing.expectEqualStrings("example.unknowntld", site("a.example.unknowntld"));
    // Wildcard and exception rules: *.ck and !www.ck.
    try testing.expectEqualStrings("foo.bar.ck", site("a.foo.bar.ck"));
    try testing.expectEqualStrings("www.ck", site("a.www.ck"));
    try testing.expectEqualStrings("www.ck", site("www.ck"));
    try testing.expectEqualStrings("example.com", urlHost("https://user@example.com:8443/path?q"));
    try testing.expectEqualStrings("[::1]", urlHost("http://[::1]:80/"));
}

test "hiding script groups selectors by trigger and keeps lists apart" {
    const list = try parse(testing.allocator,
        \\[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".banner"}},
        \\ {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#ad"}},
        \\ {"trigger":{"url-filter":"x","if-domain":["a.com"]},"action":{"type":"css-display-none","selector":"aside"}},
        \\ {"trigger":{"url-filter":"block"},"action":{"type":"block"}}]
    , null);
    defer list.deinit();
    try testing.expectEqualStrings(
        \\[{"s":[".banner","#ad"]},{"s":["aside"],"u":"x","d":["a.com"]}]
    , list.cosmetic);
    const blocking = try parse(testing.allocator, "[{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"block\"}}]", null);
    defer blocking.deinit();
    try testing.expect(!blocking.hides());
    try testing.expect(try hidingScript(testing.allocator, &.{blocking}) == null);
    const script = (try hidingScript(testing.allocator, &.{ list, blocking })).?;
    defer testing.allocator.free(script);
    try testing.expect(std.mem.startsWith(u8, script, "(()=>{const lists=[[{\"s\":"));
    try testing.expect(std.mem.endsWith(u8, script, "})();"));
}
