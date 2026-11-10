const std = @import("std");
const zio = @import("ziggurat_io");
const syntax = @import("root.zig");
const languages = syntax.languages;

const TokenKind = syntax.TokenKind;
const Token = syntax.Token;

/// The tokens of `line` as "text:kind" runs, ignoring whitespace runs.
fn expectRuns(language: *const syntax.Language, line: []const u8, state: u64, expected: []const struct { []const u8, TokenKind }) !u64 {
    var buffer: [128]Token = undefined;
    const result = syntax.tokenizeLine(language.tokenizer.?, line, state, &buffer);
    var from: usize = 0;
    var at: usize = 0;
    for (result.tokens) |token| {
        defer from = token.end;
        const text = line[from..token.end];
        if (token.kind == .text and std.mem.trim(u8, text, " \t").len == 0) continue;
        if (at == expected.len) {
            std.debug.print("unexpected run {s}:{s}\n", .{ text, @tagName(token.kind) });
            return error.TestUnexpectedResult;
        }
        std.testing.expectEqualStrings(expected[at][0], text) catch |err| {
            std.debug.print("run {d} kind {s}\n", .{ at, @tagName(token.kind) });
            return err;
        };
        std.testing.expectEqual(expected[at][1], token.kind) catch |err| {
            std.debug.print("run {d} {s}\n", .{ at, text });
            return err;
        };
        at += 1;
    }
    try std.testing.expectEqual(expected.len, at);
    try std.testing.expectEqual(line.len, from);
    return result.state;
}

test "the general lexer reads keywords, calls, types, numbers, strings and comments" {
    _ = try expectRuns(&languages.go, "func main() { x := 0x1F + 1.5e-3 // done", 0, &.{
        .{ "func", .keyword }, .{ "main", .function }, .{ "()", .punctuation }, .{ "{", .punctuation }, .{ "x", .variable },
        .{ ":=", .operator },  .{ "0x1F", .number },   .{ "+", .operator },     .{ "1.5e-3", .number }, .{ "// done", .comment },
    });
    _ = try expectRuns(&languages.go, "fmt.Println(\"a\\n\")", 0, &.{
        .{ "fmt", .variable }, .{ ".", .punctuation }, .{ "Println", .function }, .{ "(", .punctuation }, .{ "\"a", .string }, .{ "\\n", .escape }, .{ "\"", .string }, .{ ")", .punctuation },
    });
    // A dot before an identifier makes it a property, even a keyword.
    _ = try expectRuns(&languages.typescript, "obj.type = Foo", 0, &.{
        .{ "obj", .variable }, .{ ".", .punctuation }, .{ "type", .property }, .{ "=", .operator }, .{ "Foo", .type },
    });
    _ = try expectRuns(&languages.zig, "const x = @import(\"std\");", 0, &.{
        .{ "const", .keyword }, .{ "x", .variable }, .{ "=", .operator }, .{ "@import", .meta }, .{ "(", .punctuation }, .{ "\"std\"", .string }, .{ ");", .punctuation },
    });
    _ = try expectRuns(&languages.c, "#include <stdio.h>", 0, &.{ .{ "#include", .meta }, .{ "<", .operator }, .{ "stdio", .variable }, .{ ".", .punctuation }, .{ "h", .property }, .{ ">", .operator } });
    _ = try expectRuns(&languages.sql, "SELECT id FROM t", 0, &.{ .{ "SELECT", .keyword }, .{ "id", .variable }, .{ "FROM", .keyword }, .{ "t", .variable } });
    _ = try expectRuns(&languages.shell, "echo $HOME \"${x}y\"", 0, &.{ .{ "echo", .function }, .{ "$HOME", .variable }, .{ "\"", .string }, .{ "${x}", .variable }, .{ "y\"", .string } });
}

test "block comments, multiline strings and interpolations carry state across lines" {
    var state = try expectRuns(&languages.go, "a /* open", 0, &.{ .{ "a", .variable }, .{ "/* open", .comment } });
    try std.testing.expect(state != 0);
    state = try expectRuns(&languages.go, "still */ b", state, &.{ .{ "still */", .comment }, .{ "b", .variable } });
    try std.testing.expectEqual(@as(u64, 0), state);
    // Nested block comments.
    state = try expectRuns(&languages.rust, "/* a /* b */ c", 0, &.{.{ "/* a /* b */ c", .comment }});
    state = try expectRuns(&languages.rust, "*/ fn", state, &.{ .{ "*/", .comment }, .{ "fn", .keyword } });
    try std.testing.expectEqual(@as(u64, 0), state);
    // A template literal with an interpolation holding braces, over two lines.
    state = try expectRuns(&languages.javascript, "`a ${ {b: 1}.b } c", 0, &.{
        .{ "`a ", .string }, .{ "${", .escape }, .{ "{", .punctuation }, .{ "b", .variable }, .{ ":", .operator }, .{ "1", .number }, .{ "}.", .punctuation }, .{ "b", .property }, .{ "}", .escape }, .{ " c", .string },
    });
    try std.testing.expect(state != 0);
    state = try expectRuns(&languages.javascript, "d` + 1", state, &.{ .{ "d`", .string }, .{ "+", .operator }, .{ "1", .number } });
    try std.testing.expectEqual(@as(u64, 0), state);
    // A single-line string ends with its line.
    state = try expectRuns(&languages.go, "\"open", 0, &.{.{ "\"open", .string }});
    try std.testing.expectEqual(@as(u64, 0), state);
    // Python's prefixed and formatted strings.
    _ = try expectRuns(&languages.python, "f\"x{y}\"", 0, &.{ .{ "f\"x", .string }, .{ "{", .escape }, .{ "y", .variable }, .{ "}", .escape }, .{ "\"", .string } });
    _ = try expectRuns(&languages.javascript, "x = /a[/]b/g;", 0, &.{ .{ "x", .variable }, .{ "=", .operator }, .{ "/a[/]b/g", .regexp }, .{ ";", .punctuation } });
}

test "dedicated lexers for data, styles, markup, Markdown and diffs" {
    _ = try expectRuns(&languages.json, "{\"key\": \"value\", \"n\": true}", 0, &.{
        .{ "{", .punctuation }, .{ "\"key\"", .property }, .{ ":", .operator }, .{ "\"value\"", .string }, .{ ",", .punctuation }, .{ "\"n\"", .property }, .{ ":", .operator }, .{ "true", .constant }, .{ "}", .punctuation },
    });
    // A key's escapes are the key's; a value's stay escapes.
    _ = try expectRuns(&languages.json, "{\"k\\\"x\": \"v\\n\"}", 0, &.{
        .{ "{", .punctuation }, .{ "\"k\\\"x\"", .property }, .{ ":", .operator }, .{ "\"v", .string }, .{ "\\n", .escape }, .{ "\"", .string }, .{ "}", .punctuation },
    });
    _ = try expectRuns(&languages.toml, "[package]", 0, &.{.{ "[package]", .type }});
    _ = try expectRuns(&languages.toml, "name = \"x\"", 0, &.{ .{ "name", .property }, .{ "=", .operator }, .{ "\"x\"", .string } });
    var state = try expectRuns(&languages.css, "a:hover { color: #fff; }", 0, &.{
        .{ "a", .tag }, .{ ":hover", .keyword }, .{ "{", .punctuation }, .{ "color", .property }, .{ ":", .punctuation }, .{ "#fff", .number }, .{ ";", .punctuation }, .{ "}", .punctuation },
    });
    try std.testing.expectEqual(@as(u64, 0), state);
    state = try expectRuns(&languages.html, "<p class=\"x\">&amp;<!-- c", 0, &.{
        .{ "<", .punctuation }, .{ "p", .tag }, .{ "class", .attribute }, .{ "=", .operator }, .{ "\"x\"", .string }, .{ ">", .punctuation }, .{ "&amp;", .escape }, .{ "<!-- c", .comment },
    });
    state = try expectRuns(&languages.html, "--><script>let a", state, &.{ .{ "-->", .comment }, .{ "<", .punctuation }, .{ "script", .tag }, .{ ">", .punctuation }, .{ "let", .keyword }, .{ "a", .variable } });
    state = try expectRuns(&languages.html, "1</script>", state, &.{ .{ "1", .number }, .{ "</", .punctuation }, .{ "script", .tag }, .{ ">", .punctuation } });
    try std.testing.expectEqual(@as(u64, 0), state);

    _ = try expectRuns(&languages.markdown, "# Title", 0, &.{.{ "# Title", .heading }});
    _ = try expectRuns(&languages.markdown, "- [x] **bold** and `code` [l](u)", 0, &.{
        .{ "-", .punctuation }, .{ "[x]", .keyword }, .{ "**bold**", .strong }, .{ " and ", .text }, .{ "`code`", .code }, .{ "[l]", .link }, .{ "(u)", .string },
    });
    state = try expectRuns(&languages.markdown, "```go", 0, &.{ .{ "```", .punctuation }, .{ "go", .type } });
    state = try expectRuns(&languages.markdown, "func f() {}", state, &.{ .{ "func", .keyword }, .{ "f", .function }, .{ "()", .punctuation }, .{ "{}", .punctuation } });
    state = try expectRuns(&languages.markdown, "```", state, &.{.{ "```", .punctuation }});
    try std.testing.expectEqual(@as(u64, 0), state);

    _ = try expectRuns(&languages.diff, "@@ -1,2 +1,3 @@ fn main", 0, &.{ .{ "@@ -1,2 +1,3 @@", .keyword }, .{ " fn main", .function } });
    _ = try expectRuns(&languages.diff, "+added", 0, &.{.{ "+added", .inserted }});
    _ = try expectRuns(&languages.diff, "--- a/file", 0, &.{.{ "--- a/file", .meta }});
}

test "Dart, Scala, R, GraphQL and Nix" {
    var state = try expectRuns(&languages.dart, "final s = r'\\d' + \"a${b}c$d\"; // c", 0, &.{
        .{ "final", .keyword }, .{ "s", .variable }, .{ "=", .operator }, .{ "r'\\d'", .string }, .{ "+", .operator }, .{ "\"a", .string }, .{ "${", .escape }, .{ "b", .variable }, .{ "}", .escape }, .{ "c", .string }, .{ "$d", .variable }, .{ "\"", .string }, .{ ";", .punctuation }, .{ "// c", .comment },
    });
    state = try expectRuns(&languages.dart, "/* a /* b */ c */ var t = '''x", 0, &.{ .{ "/* a /* b */ c */", .comment }, .{ "var", .keyword }, .{ "t", .variable }, .{ "=", .operator }, .{ "'''x", .string } });
    state = try expectRuns(&languages.dart, "y''';", state, &.{ .{ "y'''", .string }, .{ ";", .punctuation } });
    try std.testing.expectEqual(@as(u64, 0), state);

    _ = try expectRuns(&languages.scala, "val s = s\"Hi $name ${a + 1}\" + raw\"\\d\" // c", 0, &.{
        .{ "val", .keyword }, .{ "s", .variable }, .{ "=", .operator }, .{ "s\"Hi ", .string }, .{ "$name", .variable }, .{ " ", .string }, .{ "${", .escape }, .{ "a", .variable }, .{ "+", .operator }, .{ "1", .number }, .{ "}", .escape }, .{ "\"", .string }, .{ "+", .operator }, .{ "raw\"\\d\"", .string }, .{ "// c", .comment },
    });
    state = try expectRuns(&languages.scala, "/* a /* b */ c */ def f[T](x: T): Unit = \"\"\"multi", 0, &.{
        .{ "/* a /* b */ c */", .comment }, .{ "def", .keyword }, .{ "f", .variable }, .{ "[", .punctuation }, .{ "T", .type }, .{ "](", .punctuation }, .{ "x", .variable }, .{ ":", .operator }, .{ "T", .type }, .{ ")", .punctuation }, .{ ":", .operator }, .{ "Unit", .type }, .{ "=", .operator }, .{ "\"\"\"multi", .string },
    });
    state = try expectRuns(&languages.scala, "line\"\"\"", state, &.{.{ "line\"\"\"", .string }});
    try std.testing.expectEqual(@as(u64, 0), state);

    _ = try expectRuns(&languages.r, "x <- c(1L, NA) %in% r\"(a\\b)\" # c", 0, &.{
        .{ "x", .variable }, .{ "<-", .operator }, .{ "c", .function }, .{ "(", .punctuation }, .{ "1L", .number }, .{ ",", .punctuation }, .{ "NA", .constant }, .{ ")", .punctuation }, .{ "%in%", .operator }, .{ "r\"(a\\b)\"", .string }, .{ "# c", .comment },
    });
    _ = try expectRuns(&languages.r, "if (TRUE) df$col.name |> is.na()", 0, &.{
        .{ "if", .keyword }, .{ "(", .punctuation }, .{ "TRUE", .constant }, .{ ")", .punctuation }, .{ "df", .variable }, .{ "$", .operator }, .{ "col.name", .variable }, .{ "|>", .operator }, .{ "is.na", .function }, .{ "()", .punctuation },
    });

    state = try expectRuns(&languages.graphql, "query Get($id: ID!) @cached { user(id: $id) { ...F ... on User { name } } } # c", 0, &.{
        .{ "query", .keyword }, .{ "Get", .type },      .{ "(", .punctuation }, .{ "$id", .variable },  .{ ":", .operator },    .{ "ID", .type },       .{ "!", .operator },    .{ ")", .punctuation },   .{ "@cached", .meta }, .{ "{", .punctuation },
        .{ "user", .variable }, .{ "(", .punctuation }, .{ "id", .property },   .{ ":", .operator },    .{ "$id", .variable },  .{ ")", .punctuation }, .{ "{", .punctuation }, .{ "...", .punctuation }, .{ "F", .type },       .{ "...", .punctuation },
        .{ "on", .keyword },    .{ "User", .type },     .{ "{", .punctuation }, .{ "name", .variable }, .{ "}", .punctuation }, .{ "}", .punctuation }, .{ "}", .punctuation }, .{ "# c", .comment },
    });
    state = try expectRuns(&languages.graphql, "\"\"\"Doc", 0, &.{.{ "\"\"\"Doc", .string }});
    state = try expectRuns(&languages.graphql, "\"\"\"", state, &.{.{ "\"\"\"", .string }});
    try std.testing.expectEqual(@as(u64, 0), state);

    state = try expectRuns(&languages.nix, "{ pkgs ? import <nixpkgs> {} }: let s = \"a${pkgs.hello-world}\\n\"; # c", 0, &.{
        .{ "{", .punctuation },  .{ "pkgs", .variable }, .{ "?", .operator },    .{ "import", .function },      .{ "<", .operator },  .{ "nixpkgs", .variable }, .{ ">", .operator },
        .{ "{}", .punctuation }, .{ "}", .punctuation }, .{ ":", .operator },    .{ "let", .keyword },          .{ "s", .property },  .{ "=", .operator },       .{ "\"a", .string },
        .{ "${", .escape },      .{ "pkgs", .variable }, .{ ".", .punctuation }, .{ "hello-world", .property }, .{ "}\\n", .escape }, .{ "\"", .string },        .{ ";", .punctuation },
        .{ "# c", .comment },
    });
    try std.testing.expectEqual(@as(u64, 0), state);
    state = try expectRuns(&languages.nix, "in rec { x = '' echo ${s}", 0, &.{
        .{ "in", .keyword }, .{ "rec", .keyword }, .{ "{", .punctuation }, .{ "x", .property }, .{ "=", .operator }, .{ "'' echo ", .string }, .{ "${", .escape }, .{ "s", .variable }, .{ "}", .escape },
    });
    state = try expectRuns(&languages.nix, "''; y = s // { z = true; }; /* d */ }", state, &.{
        .{ "''", .string },  .{ ";", .punctuation }, .{ "y", .property },    .{ "=", .operator },    .{ "s", .variable },     .{ "//", .operator },     .{ "{", .punctuation },
        .{ "z", .property }, .{ "=", .operator },    .{ "true", .constant }, .{ ";", .punctuation }, .{ "};", .punctuation }, .{ "/* d */", .comment }, .{ "}", .punctuation },
    });
    try std.testing.expectEqual(@as(u64, 0), state);
    // The whole of a path before = is the binding's; a.b == c is no binding.
    _ = try expectRuns(&languages.nix, "inputs.x.\"y\".${s} = a.b == c;", 0, &.{
        .{ "inputs", .property }, .{ ".", .punctuation }, .{ "x", .property },    .{ ".", .punctuation }, .{ "\"y\"", .string }, .{ ".", .punctuation }, .{ "$", .text },
        .{ "{", .punctuation },   .{ "s", .variable },    .{ "}", .punctuation }, .{ "=", .operator },    .{ "a", .variable },   .{ ".", .punctuation }, .{ "b", .property },
        .{ "==", .operator },     .{ "c", .variable },    .{ ";", .punctuation },
    });

    const files = [_]struct { []const u8, *const syntax.Language }{
        .{ "flake.nix", &languages.nix }, .{ "main.dart", &languages.dart },   .{ "schema.graphql", &languages.graphql }, .{ "q.gql", &languages.graphql }, .{ "plot.r", &languages.r },
        .{ "plot.R", &languages.r },      .{ "Main.scala", &languages.scala }, .{ "build.sc", &languages.scala },         .{ "a/.Rprofile", &languages.r },
    };
    for (files) |file| try std.testing.expectEqual(file[1], syntax.forFile(file[0]).?);
    const names = [_]struct { []const u8, *const syntax.Language }{
        .{ "Nix", &languages.nix }, .{ "dart", &languages.dart }, .{ "GraphQL", &languages.graphql }, .{ "gql", &languages.graphql }, .{ "r", &languages.r }, .{ " R ", &languages.r }, .{ "Scala", &languages.scala }, .{ "sc", &languages.scala },
    };
    for (names) |name| try std.testing.expectEqual(name[1], syntax.named(name[0]).?);
}

test "languages are found by file name, extension, name and alias" {
    try std.testing.expectEqual(&languages.go, syntax.forFile("src/main.go").?);
    try std.testing.expectEqual(&languages.makefile, syntax.forFile("C:\\proj\\Makefile").?);
    try std.testing.expectEqual(&languages.json, syntax.forFile("tsconfig.json").?);
    try std.testing.expectEqual(&languages.cpp, syntax.forFile("a.HPP").?);
    try std.testing.expectEqual(@as(?*const syntax.Language, null), syntax.forFile("notes"));
    try std.testing.expectEqual(&languages.typescript, syntax.named("tsx").?);
    try std.testing.expectEqual(&languages.shell, syntax.named(" Bash ").?);
    try std.testing.expectEqual(&languages.cpp, syntax.named("C++").?);
    try std.testing.expectEqual(&languages.csharp, syntax.named("cs").?);
    try std.testing.expectEqual(@as(?*const syntax.Language, null), syntax.named("klingon"));
    for (languages.all) |language| try std.testing.expect(language.tokenizer != null);
}

test "token output merges runs and degrades without losing coverage when full" {
    var small: [2]Token = undefined;
    const result = syntax.tokenizeLine(languages.go.tokenizer.?, "a + b + c", 0, &small);
    try std.testing.expectEqual(@as(usize, 2), result.tokens.len);
    try std.testing.expectEqual(@as(u32, 9), result.tokens[1].end);
    // Overlong lines stay plain and pass the state through.
    const long = @as([syntax.max_line + 1]u8, @splat('"'));
    var buffer: [4]Token = undefined;
    const plain = syntax.tokenizeLine(languages.go.tokenizer.?, &long, 7, &buffer);
    try std.testing.expectEqual(@as(u64, 7), plain.state);
    try std.testing.expectEqual(TokenKind.text, plain.tokens[0].kind);
}

test "the highlighter re-lexes after edits until states agree" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..50) |i| try text.print(allocator, "line {d}\n", .{i});
    var h = try syntax.Highlighter.init(allocator, languages.go.tokenizer.?);
    defer h.deinit();
    try std.testing.expect(!try h.highlight(syntax.highlighter.SliceLines{ .text = text.items }, 40, 10));
    try std.testing.expect(try h.highlight(syntax.highlighter.SliceLines{ .text = text.items }, 40, 100));
    try std.testing.expect(h.stateOf(40).final);
    // Open a comment on line 3: every later line is inside it.
    try text.replaceRange(allocator, std.mem.indexOf(u8, text.items, "line 3").?, 0, "/* ");
    try h.sync(syntax.highlighter.SliceLines{ .text = text.items });
    try std.testing.expect(!h.stateOf(10).final);
    try std.testing.expect(try h.highlight(syntax.highlighter.SliceLines{ .text = text.items }, 49, 1000));
    try std.testing.expect(h.stateOf(30).state != 0);
    var buffer: [16]Token = undefined;
    try std.testing.expectEqual(TokenKind.comment, h.tokens(30, "line 30", &buffer).tokens[0].kind);
    // Close it again on line 5: lines after it return to code, and a later
    // edit that changes no state stops at the next line.
    const at = std.mem.indexOf(u8, text.items, "line 5").?;
    try text.replaceRange(allocator, at, 0, "*/ ");
    try h.sync(syntax.highlighter.SliceLines{ .text = text.items });
    try std.testing.expect(try h.highlight(syntax.highlighter.SliceLines{ .text = text.items }, 49, 1000));
    try std.testing.expectEqual(@as(u64, 0), h.stateOf(30).state);
    const before = h.states.items.len;
    try text.replaceRange(allocator, std.mem.indexOf(u8, text.items, "line 20").?, 4, "row");
    try h.sync(syntax.highlighter.SliceLines{ .text = text.items });
    try std.testing.expect(try h.highlight(syntax.highlighter.SliceLines{ .text = text.items }, 49, 2));
    try std.testing.expectEqual(before, h.states.items.len);
    // Inserting lines shifts later states with them.
    try text.replaceRange(allocator, std.mem.indexOf(u8, text.items, "line 1\n").?, 0, "x\ny\n");
    try h.edit(1, 1, 3);
    try std.testing.expect(try h.highlight(syntax.highlighter.SliceLines{ .text = text.items }, 51, 1000));
    try std.testing.expectEqual(@as(usize, 53), h.states.items.len);
}

test "brackets match outside strings and comments, and enclose a range" {
    const text =
        \\f(a, "(", [b]) {
        \\  // }
        \\  g(c)
        \\}
    ;
    const lines = syntax.highlighter.SliceLines{ .text = text };
    var h = try syntax.Highlighter.init(std.testing.allocator, languages.go.tokenizer.?);
    defer h.deinit();
    _ = try h.highlight(lines, 10, 100);
    var line: [256]u8 = undefined;
    var tokens: [64]Token = undefined;
    var matcher: syntax.brackets.Matcher(syntax.highlighter.SliceLines) = .{ .source = lines, .highlighter = &h, .pairs = .of(&languages.go), .line = &line, .tokens = &tokens };
    const open_paren = std.mem.indexOfScalar(u8, text, '(').?;
    const pair = (try matcher.match(open_paren)).?;
    try std.testing.expectEqual(@as(usize, 13), pair.close);
    const brace = std.mem.indexOfScalar(u8, text, '{').?;
    try std.testing.expectEqual(text.len - 1, (try matcher.match(brace)).?.close);
    try std.testing.expectEqual(brace, (try matcher.match(text.len - 1)).?.open);
    // A caret inside g(c) is inside its parentheses; one in the comment
    // line is inside the braces.
    const c_at = std.mem.lastIndexOfScalar(u8, text, 'c').?;
    const inner = (try matcher.enclosing(c_at, c_at)).?;
    try std.testing.expectEqual(c_at - 1, inner.open);
    const comment = std.mem.indexOf(u8, text, "//").?;
    try std.testing.expectEqual(brace, (try matcher.enclosing(comment, comment)).?.open);
    // Just after a closing bracket is still in its pair.
    try std.testing.expectEqual(c_at - 1, (try matcher.enclosing(c_at + 2, c_at + 2)).?.open);
    try std.testing.expectEqual(c_at + 1, syntax.brackets.jumpTarget(c_at, inner));
    try std.testing.expectEqual(c_at, syntax.brackets.jumpTarget(c_at + 1, inner));
    try std.testing.expectEqual(c_at - 1, syntax.brackets.jumpTarget(c_at + 2, inner));
}

test "lines restarting start in state 0 whatever the line before ends in, and move with edits" {
    // Two hunks of a patch: the first ends inside a block comment, which
    // must not go on into the second.
    const source = "a /* open\nstill\nb := 1\nc";
    var highlighter = try syntax.Highlighter.init(std.testing.allocator, languages.go.tokenizer.?);
    defer highlighter.deinit();
    const lines = syntax.highlighter.SliceLines{ .text = source };
    _ = try highlighter.highlight(lines, 3, 100);
    try std.testing.expect(highlighter.stateOf(2).state != 0);
    try highlighter.setRestarts(&.{ 0, 2 });
    try std.testing.expect(highlighter.restartsAt(2) and !highlighter.restartsAt(1));
    try std.testing.expect(try highlighter.highlight(lines, 3, 100));
    try std.testing.expect(highlighter.stateOf(1).state != 0);
    try std.testing.expectEqual(@as(u64, 0), highlighter.stateOf(2).state);
    try std.testing.expectEqual(@as(u64, 0), highlighter.stateOf(3).state);
    var buffer: [16]Token = undefined;
    const tokens = highlighter.tokens(2, "b := 1", &buffer).tokens;
    try std.testing.expectEqual(TokenKind.variable, tokens[0].kind);
    // A line inserted above moves the restart; one replacing it drops it.
    try highlighter.edit(0, 0, 1);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, highlighter.restartLines());
    try highlighter.edit(2, 3, 2);
    try std.testing.expectEqualSlices(usize, &.{0}, highlighter.restartLines());
    try std.testing.expectError(error.InvalidValue, highlighter.setRestarts(&.{ 2, 1 }));
}

test "a script's language is found by its #! line when its name tells nothing" {
    try std.testing.expectEqualStrings("python", languages.shebangInterpreter("#!/usr/bin/python3.12\nprint()"));
    try std.testing.expectEqualStrings("ruby", languages.shebangInterpreter("#!/usr/bin/env -S RUBYOPT=-W0 ruby -w"));
    try std.testing.expectEqualStrings("bash", languages.shebangInterpreter("#!/bin/bash -e"));
    try std.testing.expectEqualStrings("", languages.shebangInterpreter("# not a script"));
    try std.testing.expectEqualStrings("", languages.shebangInterpreter("#!"));
    const scripts = [_]struct { []const u8, []const u8, *const syntax.Language }{
        .{ "bin/rails", "#!/usr/bin/env ruby\nrequire_relative '../config/boot'", &languages.ruby },
        .{ "bin/setup", "#!/bin/sh\nset -e", &languages.shell },
        .{ "run", "#!/usr/bin/env node\n", &languages.javascript },
        .{ "tool", "#!/usr/bin/env -S deno run\n", &languages.typescript },
        .{ "plot", "#!/usr/bin/Rscript\n", &languages.r },
        .{ "build", "#!/usr/bin/make -f\n", &languages.makefile },
        // The name wins over the #! line.
        .{ "main.go", "#!/usr/bin/env python3\n", &languages.go },
    };
    for (scripts) |script| try std.testing.expectEqual(script[2], syntax.forText(script[0], script[1]).?);
    try std.testing.expectEqual(@as(?*const syntax.Language, null), syntax.forText("notes", "plain"));
    try std.testing.expectEqual(@as(?*const syntax.Language, null), syntax.forText("notes", "#!/usr/bin/env klingon"));
    try std.testing.expectEqual(&languages.ruby, syntax.forFile("user.rbs").?);
}

test "ERB and Jinja templates lex their code in tags over the text around them" {
    // ERB's Ruby in tags, in attribute values and across lines, its
    // comments, and the HTML around them.
    var state = try expectRuns(&languages.erb, "<p class=\"<%= cls %>\"><% if x -%>", 0, &.{
        .{ "<", .punctuation }, .{ "p", .tag },     .{ "class", .attribute }, .{ "=", .operator }, .{ "\"", .string },  .{ "<%=", .meta },   .{ "cls", .variable },
        .{ "%>", .meta },       .{ "\"", .string }, .{ ">", .punctuation },   .{ "<%", .meta },    .{ "if", .keyword }, .{ "x", .variable }, .{ "-%>", .meta },
    });
    state = try expectRuns(&languages.erb, "<%# a", state, &.{.{ "<%# a", .comment }});
    try std.testing.expect(state != 0);
    state = try expectRuns(&languages.erb, "b %><%= link_to \"a\",", state, &.{ .{ "b %>", .comment }, .{ "<%=", .meta }, .{ "link_to", .variable }, .{ "\"a\"", .string }, .{ ",", .punctuation } });
    state = try expectRuns(&languages.erb, "  root_path %></p>", state, &.{ .{ "root_path", .variable }, .{ "%>", .meta }, .{ "</", .punctuation }, .{ "p", .tag }, .{ ">", .punctuation } });
    try std.testing.expectEqual(@as(u64, 0), state);
    // ERB's <%% is a literal <%, opening no tag.
    _ = try expectRuns(&languages.erb, "<p><%% x %></p><%= y %>", 0, &.{
        .{ "<", .punctuation }, .{ "p", .tag }, .{ ">", .punctuation }, .{ "<%% x %>", .text }, .{ "</", .punctuation }, .{ "p", .tag }, .{ ">", .punctuation }, .{ "<%=", .meta }, .{ "y", .variable }, .{ "%>", .meta },
    });
    // Jinja's expressions, statements with whitespace control, comments
    // over lines, and the plain text around them.
    state = try expectRuns(&languages.jinja, "ExecStart={{ script | default('/bin/x') }}", 0, &.{
        .{ "ExecStart=", .text }, .{ "{{", .meta }, .{ "script", .variable }, .{ "|", .operator }, .{ "default", .function }, .{ "(", .punctuation }, .{ "'/bin/x'", .string }, .{ ")", .punctuation }, .{ "}}", .meta },
    });
    state = try expectRuns(&languages.jinja, "{%- for r in rules if r.port > 0 +%}", state, &.{
        .{ "{%-", .meta },      .{ "for", .keyword },   .{ "r", .variable }, .{ "in", .keyword }, .{ "rules", .variable }, .{ "if", .keyword }, .{ "r", .variable },
        .{ ".", .punctuation }, .{ "port", .property }, .{ ">", .operator }, .{ "0", .number },   .{ "+%}", .meta },
    });
    state = try expectRuns(&languages.jinja, "{# a", state, &.{.{ "{# a", .comment }});
    state = try expectRuns(&languages.jinja, "b #}x{{ none }}", state, &.{ .{ "b #}", .comment }, .{ "x", .text }, .{ "{{", .meta }, .{ "none", .constant }, .{ "}}", .meta } });
    try std.testing.expectEqual(@as(u64, 0), state);
    const files = [_]struct { []const u8, *const syntax.Language }{ .{ "show.html.erb", &languages.erb }, .{ "model.tt", &languages.erb }, .{ "page.jinja2", &languages.jinja } };
    for (files) |file| try std.testing.expectEqual(file[1], syntax.forFile(file[0]).?);
    const names = [_]struct { []const u8, *const syntax.Language }{ .{ "erb", &languages.erb }, .{ "ERB", &languages.erb }, .{ "eruby", &languages.erb }, .{ "jinja", &languages.jinja }, .{ "Jinja", &languages.jinja }, .{ "jinja2", &languages.jinja }, .{ "j2", &languages.jinja } };
    for (names) |name| try std.testing.expectEqual(name[1], syntax.named(name[0]).?);
    try std.testing.expectEqualStrings("", languages.jinja.line_comment);
    try std.testing.expectEqualStrings("{#", languages.jinja.block_comment[0]);
    try std.testing.expectEqualStrings("#}", languages.jinja.block_comment[1]);
}

/// The runs of a line, as "kind(text)" joined, skipping blank text.
fn lexRuns(tokenizer: syntax.Tokenizer, line: []const u8, out: []u8) ![]const u8 {
    var buffer: [128]Token = undefined;
    const result = syntax.tokenizeLine(tokenizer, line, 0, &buffer);
    var writer = std.Io.Writer.fixed(out);
    var from: usize = 0;
    for (result.tokens) |token| {
        defer from = token.end;
        const text = line[from..token.end];
        if (token.kind == .text and std.mem.trim(u8, text, " \t").len == 0) continue;
        try writer.print("{s}({s})", .{ @tagName(token.kind), text });
    }
    return writer.buffered();
}

test "a template's text is in the language the name before its extension gives" {
    const cases = [_]struct { name: []const u8, host: ?*const syntax.Language, line: []const u8 }{
        .{ .name = "compose.yaml.j2", .host = &languages.yaml, .line = "image: app # pinned" },
        .{ .name = "config.json.erb", .host = &languages.json, .line = "{\"a\": [1, true]}" },
        .{ .name = "Dockerfile.j2", .host = &languages.dockerfile, .line = "FROM ruby AS app" },
        .{ .name = "show.html.erb", .host = &languages.html, .line = "<p class=\"x\">a</p>" },
        .{ .name = "show.erb", .host = &languages.html, .line = "<p class=\"x\">a</p>" },
        .{ .name = "welcome.text.erb", .host = null, .line = "<p class=\"x\">a: 1</p>" },
        .{ .name = "nginx.conf.j2", .host = &languages.toml, .line = "listen = 80" },
        .{ .name = "motd.j2", .host = null, .line = "[a] = 1 # b" },
    };
    for (cases) |case| {
        const language = syntax.forFile(case.name).?;
        var path: [64]u8 = undefined;
        try std.testing.expectEqual(language, syntax.forFile(try std.fmt.bufPrint(&path, "x/{s}", .{case.name})).?);
        var got: [512]u8 = undefined;
        var want: [512]u8 = undefined;
        const expected = if (case.host) |host| try lexRuns(host.tokenizer.?, case.line, &want) else try std.fmt.bufPrint(&want, "text({s})", .{case.line});
        try std.testing.expectEqualStrings(expected, try lexRuns(language.tokenizer.?, case.line, &got));
        const jinja = std.mem.eql(u8, language.name, "Jinja");
        const tag = if (jinja) "{{ tag }}" else "<%= tag %>";
        const tagged = if (jinja) "meta({{)variable(tag)meta(}})" else "meta(<%=)variable(tag)meta(%>)";
        try std.testing.expectEqualStrings(tagged, try lexRuns(language.tokenizer.?, tag, &got));
    }
    // A template in its own text language is the template itself, and so
    // is one inside another.
    try std.testing.expectEqual(&languages.erb, syntax.forFile("show.html.erb").?);
    try std.testing.expectEqual(&languages.jinja, syntax.forFile("motd.j2").?);
    try std.testing.expectEqual(&languages.jinja, syntax.forFile("page.html.erb.j2").?);
    try std.testing.expectEqual(&languages.erb, syntax.forFile("x.j2.erb").?);
    try std.testing.expect(syntax.forFile("compose.yaml.j2").? != syntax.forFile("config.json.erb").?);
}

test "Svelte lexes expressions, blocks and TypeScript scripts in its markup" {
    // Expressions in text, tags and values, and its blocks.
    _ = try expectRuns(&languages.svelte, "<p class=\"a {b}\" {c}>{#if x > 1}{y}{/if}</p>", 0, &.{
        .{ "<", .punctuation }, .{ "p", .tag },         .{ "class", .attribute }, .{ "=", .operator }, .{ "\"a ", .string },     .{ "{", .punctuation }, .{ "b", .variable },
        .{ "}", .punctuation }, .{ "\"", .string },     .{ "{", .punctuation },   .{ "c", .variable }, .{ "}>{", .punctuation }, .{ "#if", .keyword },   .{ "x", .variable },
        .{ ">", .operator },    .{ "1", .number },      .{ "}{", .punctuation },  .{ "y", .variable }, .{ "}{", .punctuation },  .{ "/if", .keyword },   .{ "}</", .punctuation },
        .{ "p", .tag },         .{ ">", .punctuation },
    });
    var state = try expectRuns(&languages.svelte, "{fn({a: 1,", 0, &.{ .{ "{", .punctuation }, .{ "fn", .function }, .{ "({", .punctuation }, .{ "a", .variable }, .{ ":", .operator }, .{ "1", .number }, .{ ",", .punctuation } });
    try std.testing.expect(state != 0);
    state = try expectRuns(&languages.svelte, "b})}<i>", state, &.{ .{ "b", .variable }, .{ "})}<", .punctuation }, .{ "i", .tag }, .{ ">", .punctuation } });
    state = try expectRuns(&languages.svelte, "<script lang=\"ts\">let x: number</script>", state, &.{
        .{ "<", .punctuation }, .{ "script", .tag }, .{ "lang", .attribute }, .{ "=", .operator },     .{ "\"ts\"", .string }, .{ ">", .punctuation }, .{ "let", .keyword },
        .{ "x", .variable },    .{ ":", .operator }, .{ "number", .type },    .{ "</", .punctuation }, .{ "script", .tag },    .{ ">", .punctuation },
    });
    try std.testing.expectEqual(@as(u64, 0), state);
    // A line whose expressions all close leaves the state of plain text.
    for ([_][]const u8{ "<p class=\"a {b}\">", "<p class='a {b}'>", "<p {c}>", "{x}", "<p>{#if a}{b}{/if}</p>" }) |line| {
        var buffer: [64]Token = undefined;
        try std.testing.expectEqual(@as(u64, 0), syntax.tokenizeLine(languages.svelte.tokenizer.?, line, 0, &buffer).state);
    }
    // HTML's braces are text.
    _ = try expectRuns(&languages.html, "<p>{x}</p>", 0, &.{ .{ "<", .punctuation }, .{ "p", .tag }, .{ ">", .punctuation }, .{ "{x}", .text }, .{ "</", .punctuation }, .{ "p", .tag }, .{ ">", .punctuation } });
    try std.testing.expectEqual(&languages.svelte, syntax.forFile("App.svelte").?);
    try std.testing.expectEqual(&languages.html, syntax.forFile("x.vue").?);
}

test "HCL lexes blocks, attributes, interpolations, comments and heredocs" {
    var state = try expectRuns(&languages.hcl, "resource \"aws_s3_bucket\" \"b\" {", 0, &.{ .{ "resource", .keyword }, .{ "\"aws_s3_bucket\"", .string }, .{ "\"b\"", .string }, .{ "{", .punctuation } });
    state = try expectRuns(&languages.hcl, "  count = var.n > 0 ? 1 : 0 # c", state, &.{
        .{ "count", .property }, .{ "=", .operator }, .{ "var", .variable }, .{ ".", .punctuation }, .{ "n", .property },  .{ ">", .operator }, .{ "0", .number },
        .{ "?", .operator },     .{ "1", .number },   .{ ":", .operator },   .{ "0", .number },      .{ "# c", .comment },
    });
    state = try expectRuns(&languages.hcl, "  tags = { Name = \"x-${var.env}\" } // d", state, &.{
        .{ "tags", .property }, .{ "=", .operator },    .{ "{", .punctuation }, .{ "Name", .property }, .{ "=", .operator }, .{ "\"x-", .string },   .{ "${", .escape },
        .{ "var", .variable },  .{ ".", .punctuation }, .{ "env", .property },  .{ "}", .escape },      .{ "\"", .string },  .{ "}", .punctuation }, .{ "// d", .comment },
    });
    state = try expectRuns(&languages.hcl, "  policy = <<-EOT", state, &.{ .{ "policy", .property }, .{ "=", .operator }, .{ "<<-EOT", .string } });
    try std.testing.expect(state != 0);
    state = try expectRuns(&languages.hcl, "    {\"a\": \"${b}\"}", state, &.{.{ "    {\"a\": \"${b}\"}", .string }});
    state = try expectRuns(&languages.hcl, "  EOT", state, &.{.{ "  EOT", .string }});
    try std.testing.expectEqual(@as(u64, 0), state);
    state = try expectRuns(&languages.hcl, "  type = list(string) /* e */", state, &.{ .{ "type", .property }, .{ "=", .operator }, .{ "list", .type }, .{ "(", .punctuation }, .{ "string", .type }, .{ ")", .punctuation }, .{ "/* e */", .comment } });
    // A block word before a dot names a value, like var.
    _ = try expectRuns(&languages.hcl, "  id = data.z.a.id", 0, &.{
        .{ "id", .property }, .{ "=", .operator }, .{ "data", .variable }, .{ ".", .punctuation }, .{ "z", .property }, .{ ".", .punctuation }, .{ "a", .property }, .{ ".", .punctuation }, .{ "id", .property },
    });
    _ = try expectRuns(&languages.hcl, "  x = module.m.out", 0, &.{ .{ "x", .property }, .{ "=", .operator }, .{ "module", .variable }, .{ ".", .punctuation }, .{ "m", .property }, .{ ".", .punctuation }, .{ "out", .property } });
    // A heredoc's opener in a string or comment opens none.
    try std.testing.expectEqual(@as(u64, 0), try expectRuns(&languages.hcl, "a = \"<<EOT\"", 0, &.{ .{ "a", .property }, .{ "=", .operator }, .{ "\"<<EOT\"", .string } }));
    try std.testing.expectEqual(@as(u64, 0), try expectRuns(&languages.hcl, "b = 1 # <<EOT", 0, &.{ .{ "b", .property }, .{ "=", .operator }, .{ "1", .number }, .{ "# <<EOT", .comment } }));
    const files = [_][]const u8{ "main.tf", "prod.tfvars", "config.hcl" };
    for (files) |file| try std.testing.expectEqual(&languages.hcl, syntax.forFile(file).?);
    for ([_][]const u8{ "hcl", "terraform", "tf", "tfvars" }) |name| try std.testing.expectEqual(&languages.hcl, syntax.named(name).?);
    try std.testing.expectEqualStrings("#", languages.hcl.line_comment);
}

test "the highlighter keeps within its budget when lines are long" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    // Lines of 8 KB, as minified JSON has, count as 32 lines each.
    for (0..20) |_| {
        try text.appendNTimes(allocator, 'a', 8 << 10);
        try text.append(allocator, '\n');
    }
    // A line too long to color is not tokenized and counts as one; the
    // line after it starts as it did.
    try text.appendNTimes(allocator, '"', syntax.max_line + 1);
    try text.appendSlice(allocator, "\nshort\n");
    const source = syntax.highlighter.SliceLines{ .text = text.items };
    var h = try syntax.Highlighter.init(allocator, languages.go.tokenizer.?);
    defer h.deinit();
    try std.testing.expect(!try h.highlight(source, 21, 64));
    // The first line costs 33 of 64, the second goes past it.
    try std.testing.expectEqual(@as(usize, 3), h.frontier);
    while (!try h.highlight(source, 21, 64)) {}
    try std.testing.expect(h.stateOf(21).final);
    try std.testing.expectEqual(@as(u64, 0), h.stateOf(21).state);
    // Short lines still cost one each.
    var short = try syntax.Highlighter.init(allocator, languages.go.tokenizer.?);
    defer short.deinit();
    try std.testing.expect(!try short.highlight(syntax.highlighter.SliceLines{ .text = "a\nb\nc\nd\n" }, 3, 2));
    try std.testing.expectEqual(@as(usize, 3), short.frontier);
}
