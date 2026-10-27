//! `ziggurat vet`: checks of an app's Zig sources that the compiler does
//! not make. The view lifetime check flags values that only live through
//! one pass, `*view.View` while a build function runs and `*ui.Frame` while
//! a paint runs, where they would outlive it: in struct fields, in
//! container-level variables, and in the arguments of `std.Thread.spawn`,
//! whose thread is not the main thread. Callback signatures taking them are
//! fine, as are the state, `view.Host` and buffers that persist.
//!
//! It reads the syntax tree only: it follows the names the file gives the
//! view and UI modules (`@import("ziggurat_view")`, `@import("ziggurat_ui")`)
//! and their `View` and `Frame`, so a value whose type it cannot see, such
//! as one inferred from a call, is not checked.
const std = @import("std");
const Ast = std.zig.Ast;

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    message: []const u8,
};

pub const stored_in_struct = "view pass value stored in a struct field; keep the state it describes, or the view.Host, instead";
pub const stored_in_container = "view pass value stored in a container-level variable; keep the state it describes, or the view.Host, instead";
pub const passed_to_thread = "view pass value passed to a thread; build and paint run on the main thread, so hand results back with App.post";

const module_types = [_]struct { module: []const u8, name: []const u8 }{
    .{ .module = "ziggurat_view", .name = "View" },
    .{ .module = "ziggurat_ui", .name = "Frame" },
};

const Names = struct {
    /// Names of the view and UI modules, as `view` in `view.View`.
    modules: [module_types.len]std.ArrayList([]const u8) = @splat(.empty),
    /// Names that stand for a transient type itself, as `const View = view.View;`.
    types: std.ArrayList([]const u8) = .empty,
};

/// Diagnostics of one file, in source order. Their messages are static.
pub fn analyze(allocator: std.mem.Allocator, source: [:0]const u8) ![]Diagnostic {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len > 0) return error.ParseFailed;
    var names: Names = .{};
    defer {
        for (&names.modules) |*list| list.deinit(allocator);
        names.types.deinit(allocator);
    }
    try collectNames(allocator, &tree, &names);
    var out: std.ArrayList(Diagnostic) = .empty;
    errdefer out.deinit(allocator);
    const has_any = blk: {
        for (names.modules) |list| if (list.items.len > 0) break :blk true;
        break :blk names.types.items.len > 0;
    };
    if (!has_any) return out.toOwnedSlice(allocator);

    var buffer: [2]Ast.Node.Index = undefined;
    // Fields of every container, and container-level variables.
    try checkContainer(allocator, &tree, &names, tree.rootDecls(), &out);
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.fullContainerDecl(&buffer, node)) |container| try checkContainer(allocator, &tree, &names, container.ast.members, &out);
    }
    // Thread arguments, function by function.
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .fn_decl) continue;
        try checkFunction(allocator, &tree, &names, node, &out);
    }
    std.mem.sort(Diagnostic, out.items, {}, struct {
        fn less(_: void, a: Diagnostic, b: Diagnostic) bool {
            return a.line < b.line or (a.line == b.line and a.column < b.column);
        }
    }.less);
    return out.toOwnedSlice(allocator);
}

fn collectNames(allocator: std.mem.Allocator, tree: *const Ast, names: *Names) !void {
    // Two rounds: aliases of types may come before the import they use.
    for (0..2) |_| for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        const decl = tree.fullVarDecl(node) orelse continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        const name = tree.tokenSlice(decl.ast.mut_token + 1);
        const text = tree.getNodeSource(init);
        for (module_types, 0..) |entry, m| {
            var quoted: [64]u8 = undefined;
            const import = std.fmt.bufPrint(&quoted, "@import(\"{s}\")", .{entry.module}) catch unreachable;
            if (std.mem.eql(u8, text, import) and !contains(names.modules[m].items, name)) try names.modules[m].append(allocator, name);
            for (names.modules[m].items) |module| {
                if (text.len == module.len + 1 + entry.name.len and std.mem.startsWith(u8, text, module) and text[module.len] == '.' and std.mem.endsWith(u8, text, entry.name) and !contains(names.types.items, name))
                    try names.types.append(allocator, name);
            }
        }
    };
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// Whether the tokens of a type expression name a transient type outside
/// a function prototype's parameters.
fn transient(tree: *const Ast, names: *const Names, type_node: Ast.Node.Index) bool {
    const first = tree.firstToken(type_node);
    const last = tree.lastToken(type_node);
    var token = first;
    while (token <= last) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .keyword_fn => {
                // Skip the parameter list: callbacks that take a pass value
                // are how passes hand them out.
                while (token <= last and tree.tokenTag(token) != .l_paren) token += 1;
                var depth: usize = 0;
                while (token <= last) : (token += 1) switch (tree.tokenTag(token)) {
                    .l_paren => depth += 1,
                    .r_paren => {
                        depth -= 1;
                        if (depth == 0) break;
                    },
                    else => {},
                };
            },
            .identifier => {
                const text = tree.tokenSlice(token);
                const after_dot = token > first and tree.tokenTag(token - 1) == .period;
                if (!after_dot and contains(names.types.items, text)) return true;
                if (token + 2 <= last and tree.tokenTag(token + 1) == .period and tree.tokenTag(token + 2) == .identifier and !after_dot) {
                    const member = tree.tokenSlice(token + 2);
                    for (module_types, 0..) |entry, m| if (std.mem.eql(u8, member, entry.name) and contains(names.modules[m].items, text)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn report(allocator: std.mem.Allocator, tree: *const Ast, token: Ast.TokenIndex, message: []const u8, out: *std.ArrayList(Diagnostic)) !void {
    const location = tree.tokenLocation(0, token);
    for (out.items) |existing| if (existing.line == location.line + 1 and existing.column == location.column + 1) return;
    try out.append(allocator, .{ .line = location.line + 1, .column = location.column + 1, .message = message });
}

fn checkContainer(allocator: std.mem.Allocator, tree: *const Ast, names: *const Names, members: []const Ast.Node.Index, out: *std.ArrayList(Diagnostic)) !void {
    for (members) |member| {
        if (tree.fullContainerField(member)) |field| {
            const type_node = field.ast.type_expr.unwrap() orelse continue;
            if (transient(tree, names, type_node)) try report(allocator, tree, field.ast.main_token, stored_in_struct, out);
        } else if (tree.fullVarDecl(member)) |decl| {
            if (tree.tokenTag(decl.ast.mut_token) != .keyword_var) continue;
            const type_node = decl.ast.type_node.unwrap() orelse continue;
            if (transient(tree, names, type_node)) try report(allocator, tree, decl.ast.mut_token + 1, stored_in_container, out);
        }
    }
}

fn checkFunction(allocator: std.mem.Allocator, tree: *const Ast, names: *const Names, node: Ast.Node.Index, out: *std.ArrayList(Diagnostic)) !void {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, node) orelse return;
    const body = tree.nodeData(node).node_and_node[1];
    const body_first = tree.firstToken(body);
    const body_last = tree.lastToken(body);
    var locals: std.ArrayList([]const u8) = .empty;
    defer locals.deinit(allocator);
    var params = proto.iterate(tree);
    while (params.next()) |param| {
        const name = param.name_token orelse continue;
        const type_node = param.type_expr orelse continue;
        if (transient(tree, names, type_node)) try locals.append(allocator, tree.tokenSlice(name));
    }
    for (0..tree.nodes.len) |i| {
        const child: Ast.Node.Index = @enumFromInt(i);
        const first = tree.firstToken(child);
        if (first < body_first or first > body_last) continue;
        const decl = tree.fullVarDecl(child) orelse continue;
        const type_node = decl.ast.type_node.unwrap() orelse continue;
        if (transient(tree, names, type_node)) try locals.append(allocator, tree.tokenSlice(decl.ast.mut_token + 1));
    }
    if (locals.items.len == 0) return;
    for (0..tree.nodes.len) |i| {
        const child: Ast.Node.Index = @enumFromInt(i);
        const first = tree.firstToken(child);
        if (first < body_first or first > body_last) continue;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, child) orelse continue;
        const callee = tree.getNodeSource(call.ast.fn_expr);
        if (!std.mem.endsWith(u8, callee, "Thread.spawn") or call.ast.params.len < 3) continue;
        const args = call.ast.params[2];
        var token = tree.firstToken(args);
        while (token <= tree.lastToken(args)) : (token += 1) {
            if (tree.tokenTag(token) != .identifier) continue;
            if (token > 0 and tree.tokenTag(token - 1) == .period) continue;
            if (contains(locals.items, tree.tokenSlice(token))) try report(allocator, tree, token, passed_to_thread, out);
        }
    }
}

test "pass values kept past their pass are reported" {
    const source =
        \\const std = @import("std");
        \\const view = @import("ziggurat_view");
        \\const ui = @import("ziggurat_ui");
        \\const View = view.View;
        \\
        \\var last_view: ?*view.View = null;
        \\var frames: [2]*ui.Frame = undefined;
        \\const Host = view.Host;
        \\
        \\const App = struct {
        \\    count: u32 = 0,
        \\    builder: *View,
        \\    callback: *const fn (*view.View) anyerror!void,
        \\    host: view.Host,
        \\    pending: std.ArrayList(*ui.Frame),
        \\
        \\    fn build(self: *App, v: *view.View) !void {
        \\        _ = try std.Thread.spawn(.{}, work, .{ self, v });
        \\        const copy: *View = v;
        \\        _ = try std.Thread.spawn(.{}, work, .{copy});
        \\        _ = try std.Thread.spawn(.{}, work, .{self.count});
        \\    }
        \\    fn work(_: anytype) void {}
        \\};
    ;
    const diagnostics = try analyze(std.testing.allocator, source);
    defer std.testing.allocator.free(diagnostics);
    const expected = [_]struct { line: usize, message: []const u8 }{
        .{ .line = 6, .message = stored_in_container },
        .{ .line = 7, .message = stored_in_container },
        .{ .line = 12, .message = stored_in_struct },
        .{ .line = 15, .message = stored_in_struct },
        .{ .line = 18, .message = passed_to_thread },
        .{ .line = 20, .message = passed_to_thread },
    };
    try std.testing.expectEqual(expected.len, diagnostics.len);
    for (expected, diagnostics) |want, got| {
        try std.testing.expectEqual(want.line, got.line);
        try std.testing.expectEqualStrings(want.message, got.message);
    }
}

test "files that do not use views have nothing to report" {
    const diagnostics = try analyze(std.testing.allocator,
        \\const std = @import("std");
        \\const Frame = struct { x: u32 };
        \\var frame: Frame = .{ .x = 1 };
    );
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
    try std.testing.expectError(error.ParseFailed, analyze(std.testing.allocator, "const = ;"));
}
