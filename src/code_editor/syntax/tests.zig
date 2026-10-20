const std = @import("std");
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
    const long = [_]u8{'"'} ** (syntax.max_line + 1);
    var buffer: [4]Token = undefined;
    const plain = syntax.tokenizeLine(languages.go.tokenizer.?, &long, 7, &buffer);
    try std.testing.expectEqual(@as(u64, 7), plain.state);
    try std.testing.expectEqual(TokenKind.text, plain.tokens[0].kind);
}

test "the highlighter re-lexes after edits until states agree" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..50) |i| try text.writer(allocator).print("line {d}\n", .{i});
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
