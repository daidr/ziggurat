const std = @import("std");
const md = @import("root.zig");

var storage: md.Storage(1024, 16 * 1024) = .{};

fn render(source: []const u8, out: []u8) ![]const u8 {
    const tree = try md.parse(source, storage.buffers());
    var writer = std.Io.Writer.fixed(out);
    try md.html.write(tree, &writer);
    return writer.buffered();
}

fn expectHtml(source: []const u8, expected: []const u8) !void {
    var out: [8192]u8 = undefined;
    const actual = try render(source, &out);
    std.testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("source:\n{s}\n", .{source});
        return err;
    };
}

test "paragraphs, breaks and headings" {
    try expectHtml("aaa\n\nbbb\n", "<p>aaa</p>\n<p>bbb</p>\n");
    try expectHtml("aaa\nbbb", "<p>aaa\nbbb</p>\n");
    try expectHtml("  aaa\n bbb", "<p>aaa\nbbb</p>\n");
    try expectHtml("foo  \nbar", "<p>foo<br />\nbar</p>\n");
    try expectHtml("foo\\\nbar", "<p>foo<br />\nbar</p>\n");
    try expectHtml("foo  ", "<p>foo</p>\n");
    try expectHtml("# foo\n## foo\n###### foo", "<h1>foo</h1>\n<h2>foo</h2>\n<h6>foo</h6>\n");
    try expectHtml("####### foo", "<p>####### foo</p>\n");
    try expectHtml("#5 bolt", "<p>#5 bolt</p>\n");
    try expectHtml("# foo ##   ", "<h1>foo</h1>\n");
    try expectHtml("### foo ### b", "<h3>foo ### b</h3>\n");
    try expectHtml("# foo#", "<h1>foo#</h1>\n");
    try expectHtml("#", "<h1></h1>\n");
    try expectHtml("Foo *bar*\n=========\n\nFoo\n---", "<h1>Foo <em>bar</em></h1>\n<h2>Foo</h2>\n");
    try expectHtml("Foo\nbar\n===", "<h1>Foo\nbar</h1>\n");
    try expectHtml("- foo\n---", "<ul>\n<li>foo</li>\n</ul>\n<hr />\n");
    try expectHtml("***\n---\n___", "<hr />\n<hr />\n<hr />\n");
    try expectHtml(" - - -", "<hr />\n");
    try expectHtml("Foo\n***\nbar", "<p>Foo</p>\n<hr />\n<p>bar</p>\n");
    try expectHtml("a\r\nb\rc", "<p>a\nb\nc</p>\n");
}

test "code blocks" {
    try expectHtml("    a simple\n      indented code block", "<pre><code>a simple\n  indented code block\n</code></pre>\n");
    try expectHtml("    chunk1\n\n    chunk2\n  \n \n \n    chunk3", "<pre><code>chunk1\n\nchunk2\n\n\n\nchunk3\n</code></pre>\n");
    try expectHtml("Foo\n    bar", "<p>Foo\nbar</p>\n");
    try expectHtml("    foo\nbar", "<pre><code>foo\n</code></pre>\n<p>bar</p>\n");
    try expectHtml("```\n<\n >\n```", "<pre><code>&lt;\n &gt;\n</code></pre>\n");
    try expectHtml("~~~\naaa\n```\n~~~", "<pre><code>aaa\n```\n</code></pre>\n");
    try expectHtml("````\naaa\n```\n``````", "<pre><code>aaa\n```\n</code></pre>\n");
    try expectHtml("```\n", "<pre><code></code></pre>\n");
    try expectHtml("> ```\n> aaa\n\nbbb", "<blockquote>\n<pre><code>aaa\n</code></pre>\n</blockquote>\n<p>bbb</p>\n");
    try expectHtml("  ```\n aaa\naaa\n  aaa\n  ```", "<pre><code>aaa\naaa\naaa\n</code></pre>\n");
    try expectHtml("```ruby startline=3\ndef foo(x)\n```", "<pre><code class=\"language-ruby\">def foo(x)\n</code></pre>\n");
    try expectHtml("``` aa ```\nfoo", "<p><code>aa</code>\nfoo</p>\n");
    try expectHtml("\tfoo\tbaz", "<pre><code>foo\tbaz\n</code></pre>\n");
    try expectHtml("- foo\n\n\tbar", "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n</ul>\n");
    try expectHtml(">\t\tfoo", "<blockquote>\n<pre><code>  foo\n</code></pre>\n</blockquote>\n");
}

test "block quotes" {
    try expectHtml("> # Foo\n> bar\n> baz", "<blockquote>\n<h1>Foo</h1>\n<p>bar\nbaz</p>\n</blockquote>\n");
    try expectHtml("> bar\nbaz\n> foo", "<blockquote>\n<p>bar\nbaz\nfoo</p>\n</blockquote>\n");
    try expectHtml("> foo\n---", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n");
    try expectHtml(">", "<blockquote>\n</blockquote>\n");
    try expectHtml("> foo\n\n> bar", "<blockquote>\n<p>foo</p>\n</blockquote>\n<blockquote>\n<p>bar</p>\n</blockquote>\n");
    try expectHtml("> > > foo\nbar", "<blockquote>\n<blockquote>\n<blockquote>\n<p>foo\nbar</p>\n</blockquote>\n</blockquote>\n</blockquote>\n");
}

test "lists" {
    try expectHtml("- one\n\n two", "<ul>\n<li>one</li>\n</ul>\n<p>two</p>\n");
    try expectHtml("- one\n\n  two", "<ul>\n<li>\n<p>one</p>\n<p>two</p>\n</li>\n</ul>\n");
    try expectHtml("1.  A paragraph\n    with two lines.\n\n        indented code\n\n    > A block quote.", "<ol>\n<li>\n<p>A paragraph\nwith two lines.</p>\n<pre><code>indented code\n</code></pre>\n<blockquote>\n<p>A block quote.</p>\n</blockquote>\n</li>\n</ol>\n");
    try expectHtml("- foo\n- bar\n+ baz", "<ul>\n<li>foo</li>\n<li>bar</li>\n</ul>\n<ul>\n<li>baz</li>\n</ul>\n");
    try expectHtml("1. foo\n2. bar\n3) baz", "<ol>\n<li>foo</li>\n<li>bar</li>\n</ol>\n<ol start=\"3\">\n<li>baz</li>\n</ol>\n");
    try expectHtml("Foo\n- bar\n- baz", "<p>Foo</p>\n<ul>\n<li>bar</li>\n<li>baz</li>\n</ul>\n");
    try expectHtml("The number of windows in my house is\n14.  The number of doors is 6.", "<p>The number of windows in my house is\n14.  The number of doors is 6.</p>\n");
    try expectHtml("- foo\n\n- bar\n\n\n- baz", "<ul>\n<li>\n<p>foo</p>\n</li>\n<li>\n<p>bar</p>\n</li>\n<li>\n<p>baz</p>\n</li>\n</ul>\n");
    try expectHtml("- foo\n  - bar\n    - baz", "<ul>\n<li>foo\n<ul>\n<li>bar\n<ul>\n<li>baz</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n");
    try expectHtml("- a\n- b\n\n- c", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n");
    try expectHtml("- a\n  - b\n\n    c\n- d", "<ul>\n<li>a\n<ul>\n<li>\n<p>b</p>\n<p>c</p>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n");
    try expectHtml("-\n  foo\n-\n  ```\n  bar\n  ```", "<ul>\n<li>foo</li>\n<li>\n<pre><code>bar\n</code></pre>\n</li>\n</ul>\n");
    try expectHtml("-\n\n  foo", "<ul>\n<li></li>\n</ul>\n<p>foo</p>\n");
    try expectHtml("10) foo\n    - bar", "<ol start=\"10\">\n<li>foo\n<ul>\n<li>bar</li>\n</ul>\n</li>\n</ol>\n");
    try expectHtml("1.     indented code\n\n   paragraph\n\n       more code", "<ol>\n<li>\n<pre><code>indented code\n</code></pre>\n<p>paragraph</p>\n<pre><code>more code\n</code></pre>\n</li>\n</ol>\n");
    try expectHtml(" -    one\n\n     two", "<ul>\n<li>one</li>\n</ul>\n<pre><code> two\n</code></pre>\n");
    try expectHtml("- # Foo\n- Bar\n  ---\n  baz", "<ul>\n<li>\n<h1>Foo</h1>\n</li>\n<li>\n<h2>Bar</h2>\nbaz</li>\n</ul>\n");
    try expectHtml("- foo\n-\n- bar", "<ul>\n<li>foo</li>\n<li></li>\n<li>bar</li>\n</ul>\n");
    try expectHtml("* a\n  > b\n  >\n* c", "<ul>\n<li>a\n<blockquote>\n<p>b</p>\n</blockquote>\n</li>\n<li>c</li>\n</ul>\n");
    try expectHtml("* a\n*\n\n* c", "<ul>\n<li>\n<p>a</p>\n</li>\n<li></li>\n<li>\n<p>c</p>\n</li>\n</ul>\n");
}

test "emphasis" {
    try expectHtml("*foo bar*", "<p><em>foo bar</em></p>\n");
    try expectHtml("a * foo bar*", "<p>a * foo bar*</p>\n");
    try expectHtml("foo*bar*", "<p>foo<em>bar</em></p>\n");
    try expectHtml("_foo_bar", "<p>_foo_bar</p>\n");
    try expectHtml("**foo bar**", "<p><strong>foo bar</strong></p>\n");
    try expectHtml("__foo, __bar__, baz__", "<p><strong>foo, <strong>bar</strong>, baz</strong></p>\n");
    try expectHtml("*foo **bar** baz*", "<p><em>foo <strong>bar</strong> baz</em></p>\n");
    try expectHtml("***foo***", "<p><em><strong>foo</strong></em></p>\n");
    try expectHtml("*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n");
    try expectHtml("foo***bar***baz", "<p>foo<em><strong>bar</strong></em>baz</p>\n");
    try expectHtml("**foo*", "<p>*<em>foo</em></p>\n");
    try expectHtml("*foo**", "<p><em>foo</em>*</p>\n");
    try expectHtml("*(*foo*)*", "<p><em>(<em>foo</em>)</em></p>\n");
    try expectHtml("*foo [bar](/url)*", "<p><em>foo <a href=\"/url\">bar</a></em></p>\n");
    try expectHtml("*a `*`*", "<p><em>a <code>*</code></em></p>\n");
    try expectHtml("**a<http://foo.bar/?q=**>", "<p>**a<a href=\"http://foo.bar/?q=**\">http://foo.bar/?q=**</a></p>\n");
    try expectHtml("中文*强调*文字", "<p>中文<em>强调</em>文字</p>\n");
    try expectHtml("“*引号*”", "<p>“<em>引号</em>”</p>\n");
}

test "code spans, escapes and entities" {
    try expectHtml("`foo`", "<p><code>foo</code></p>\n");
    try expectHtml("`` foo ` bar ``", "<p><code>foo ` bar</code></p>\n");
    try expectHtml("` `` `", "<p><code>``</code></p>\n");
    try expectHtml("``\nfoo\nbar  \nbaz\n``", "<p><code>foo bar   baz</code></p>\n");
    try expectHtml("`foo\\`bar`", "<p><code>foo\\</code>bar`</p>\n");
    try expectHtml("```foo``", "<p>```foo``</p>\n");
    try expectHtml("\\*not emphasized*", "<p>*not emphasized*</p>\n");
    try expectHtml("\\\\*emphasis*", "<p>\\<em>emphasis</em></p>\n");
    try expectHtml("\\a\\b", "<p>\\a\\b</p>\n");
    try expectHtml("&nbsp; &amp; &copy; &#35; &#x22; &#0; &bogus;", "<p>\u{a0} &amp; © # &quot; \u{fffd} &amp;bogus;</p>\n");
    try expectHtml("<div>*raw*</div>", "<p>&lt;div&gt;<em>raw</em>&lt;/div&gt;</p>\n");
}

test "links and images" {
    try expectHtml("[link](/uri \"title\")", "<p><a href=\"/uri\" title=\"title\">link</a></p>\n");
    try expectHtml("[link]()", "<p><a href=\"\">link</a></p>\n");
    try expectHtml("[link](<foo bar>)", "<p><a href=\"foo%20bar\">link</a></p>\n");
    try expectHtml("[link](foo(and(bar)))", "<p><a href=\"foo(and(bar))\">link</a></p>\n");
    try expectHtml("[link](foo\\)\\:)", "<p><a href=\"foo):\">link</a></p>\n");
    try expectHtml("[link](/url \"title \\\"&quot;\")", "<p><a href=\"/url\" title=\"title &quot;&quot;\">link</a></p>\n");
    try expectHtml("[link [foo [bar]]](/uri)", "<p><a href=\"/uri\">link [foo [bar]]</a></p>\n");
    try expectHtml("[link [bar](/uri)", "<p>[link <a href=\"/uri\">bar</a></p>\n");
    try expectHtml("[foo [bar](/uri)](/uri)", "<p>[foo <a href=\"/uri\">bar</a>](/uri)</p>\n");
    try expectHtml("[link *foo **bar** `#`*](/uri)", "<p><a href=\"/uri\">link <em>foo <strong>bar</strong> <code>#</code></em></a></p>\n");
    try expectHtml("*[foo*](/uri)", "<p>*<a href=\"/uri\">foo*</a></p>\n");
    try expectHtml("[foo][bar]\n\n[bar]: /url \"title\"", "<p><a href=\"/url\" title=\"title\">foo</a></p>\n");
    try expectHtml("[Foo Bar]\n\n[foo  bar]: /url", "<p><a href=\"/url\">Foo Bar</a></p>\n");
    try expectHtml("[foo][]\n\n[foo]: /url", "<p><a href=\"/url\">foo</a></p>\n");
    try expectHtml("[foo]: /url\n'the title'\n\n[foo]", "<p><a href=\"/url\" title=\"the title\">foo</a></p>\n");
    try expectHtml("[foo]: /url 'title\n\nwith blank line'\n\n[foo]", "<p>[foo]: /url 'title</p>\n<p>with blank line'</p>\n<p>[foo]</p>\n");
    try expectHtml("[foo]: /url \"title\" ok", "<p>[foo]: /url &quot;title&quot; ok</p>\n");
    try expectHtml("[foo]: /url\n===\n[foo]", "<p>===\n<a href=\"/url\">foo</a></p>\n");
    try expectHtml("[foo]\n\n[foo]: first\n[foo]: second", "<p><a href=\"first\">foo</a></p>\n");
    try expectHtml("![foo *bar*](train.jpg \"t\")", "<p><img src=\"train.jpg\" alt=\"foo bar\" title=\"t\" /></p>\n");
    try expectHtml("![](/url)", "<p><img src=\"/url\" alt=\"\" /></p>\n");
    try expectHtml("<http://foo.bar.baz/test?q=hello&id=22&boolean>", "<p><a href=\"http://foo.bar.baz/test?q=hello&amp;id=22&amp;boolean\">http://foo.bar.baz/test?q=hello&amp;id=22&amp;boolean</a></p>\n");
    try expectHtml("<foo@bar.example.com>", "<p><a href=\"mailto:foo@bar.example.com\">foo@bar.example.com</a></p>\n");
    try expectHtml("<http://foo.bar/baz bim>", "<p>&lt;http://foo.bar/baz bim&gt;</p>\n");
    try expectHtml("[链接](https://例子.cn/路径)", "<p><a href=\"https://%E4%BE%8B%E5%AD%90.cn/%E8%B7%AF%E5%BE%84\">链接</a></p>\n");
}

test "tables" {
    try expectHtml("| foo | bar |\n| --- | --- |\n| baz | bim |",
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>foo</th>
        \\<th>bar</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td>baz</td>
        \\<td>bim</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\
    );
    try expectHtml("| abc | defghi |\n:-: | -----------:\nbar | baz",
        \\<table>
        \\<thead>
        \\<tr>
        \\<th align="center">abc</th>
        \\<th align="right">defghi</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td align="center">bar</td>
        \\<td align="right">baz</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\
    );
    try expectHtml("| f\\|oo  |\n| ------ |\n| b `\\|` az |\n| b **\\|** im |",
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>f|oo</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td>b <code>|</code> az</td>
        \\</tr>
        \\<tr>
        \\<td>b <strong>|</strong> im</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\
    );
    try expectHtml("| abc | def |\n| --- | --- |\n| bar | baz |\n> bar",
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>abc</th>
        \\<th>def</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td>bar</td>
        \\<td>baz</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\<blockquote>
        \\<p>bar</p>
        \\</blockquote>
        \\
    );
    try expectHtml("| abc | def |\n| --- | --- |\n| bar |\n| bar | baz | boo |\n\nafter",
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>abc</th>
        \\<th>def</th>
        \\</tr>
        \\</thead>
        \\<tbody>
        \\<tr>
        \\<td>bar</td>
        \\<td></td>
        \\</tr>
        \\<tr>
        \\<td>bar</td>
        \\<td>baz</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\<p>after</p>
        \\
    );
    try expectHtml("| abc | def |\n| --- |\n| bar |", "<p>| abc | def |\n| --- |\n| bar |</p>\n");
    try expectHtml("| abc | def |\n| --- | --- |",
        \\<table>
        \\<thead>
        \\<tr>
        \\<th>abc</th>
        \\<th>def</th>
        \\</tr>
        \\</thead>
        \\</table>
        \\
    );
}

test "task lists, strikethrough and extended autolinks" {
    try expectHtml("- [ ] foo\n- [x] bar", "<ul>\n<li><input disabled=\"\" type=\"checkbox\"> foo</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> bar</li>\n</ul>\n");
    try expectHtml("- [x] foo\n  - [ ] bar\n  - [x] baz\n- [ ] bim", "<ul>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> foo\n<ul>\n<li><input disabled=\"\" type=\"checkbox\"> bar</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> baz</li>\n</ul>\n</li>\n<li><input disabled=\"\" type=\"checkbox\"> bim</li>\n</ul>\n");
    try expectHtml("- [y] no", "<ul>\n<li>[y] no</li>\n</ul>\n");
    try expectHtml("~~Hi~~ Hello, ~there~ world!", "<p><del>Hi</del> Hello, <del>there</del> world!</p>\n");
    try expectHtml("This ~~has a\n\nnew paragraph~~.", "<p>This ~~has a</p>\n<p>new paragraph~~.</p>\n");
    try expectHtml("This will ~~~not~~~ strike.", "<p>This will ~~~not~~~ strike.</p>\n");
    try expectHtml("www.commonmark.org", "<p><a href=\"http://www.commonmark.org\">www.commonmark.org</a></p>\n");
    try expectHtml("Visit www.commonmark.org/help for more information.", "<p>Visit <a href=\"http://www.commonmark.org/help\">www.commonmark.org/help</a> for more information.</p>\n");
    try expectHtml("Visit www.commonmark.org.\n\nVisit www.commonmark.org/a.b.", "<p>Visit <a href=\"http://www.commonmark.org\">www.commonmark.org</a>.</p>\n<p>Visit <a href=\"http://www.commonmark.org/a.b\">www.commonmark.org/a.b</a>.</p>\n");
    try expectHtml("www.google.com/search?q=Markup+(business)))", "<p><a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a>))</p>\n");
    try expectHtml("www.google.com/search?q=commonmark&hl;", "<p><a href=\"http://www.google.com/search?q=commonmark\">www.google.com/search?q=commonmark</a>&amp;hl;</p>\n");
    try expectHtml("(https://example.com/a) and http://x.org", "<p>(<a href=\"https://example.com/a\">https://example.com/a</a>) and <a href=\"http://x.org\">http://x.org</a></p>\n");
    try expectHtml("foo@bar.baz", "<p><a href=\"mailto:foo@bar.baz\">foo@bar.baz</a></p>\n");
    try expectHtml("a.b-c_d@a.b.", "<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a>.</p>\n");
    try expectHtml("www.", "<p>www.</p>\n");
}

test "tree shape and limits" {
    const tree = try md.parse("# Title\n\n- [x] done *now*\n\n```zig\nconst a = 1;\n```\n", storage.buffers());
    const root = tree.root();
    try std.testing.expectEqual(md.Kind.document, root.kind);
    var children = tree.children(0);
    const heading = tree.get(children.next().?);
    try std.testing.expectEqual(md.Kind.heading, heading.kind);
    try std.testing.expectEqual(@as(u8, 1), heading.level);
    const list = tree.get(children.next().?);
    try std.testing.expect(list.tight);
    const item = tree.get(list.first_child);
    try std.testing.expectEqual(md.Task.checked, item.task);
    var plain: [64]u8 = undefined;
    try std.testing.expectEqualStrings("done now", tree.plainText(list.first_child, &plain));
    const code = tree.get(children.next().?);
    try std.testing.expectEqual(md.Kind.code_block, code.kind);
    try std.testing.expectEqualStrings("zig", code.url);
    try std.testing.expectEqualStrings("const a = 1;\n", code.text);
    try std.testing.expectEqual(@as(u32, 4), code.line);
    try std.testing.expect(children.next() == null);

    var small: md.Storage(4, 64) = .{};
    try std.testing.expectError(error.TooManyNodes, md.parse("a\n\nb\n\nc\n\nd", small.buffers()));
    var tiny: md.Storage(64, 4) = .{};
    try std.testing.expectError(error.TextFull, md.parse("hello world", tiny.buffers()));
    try std.testing.expectError(error.InvalidText, md.parse("\xff", storage.buffers()));

    // Nesting past the limit stays literal instead of failing.
    const deep = &@as([40]u8, @splat('>')) ++ " x";
    var out: [8192]u8 = undefined;
    const html = try render(deep, &out);
    try std.testing.expectEqual(@as(usize, md.max_depth), std.mem.count(u8, html, "<blockquote>"));
    const emphasis = &@as([300 * "*a ".len]u8, @bitCast(@as([300]["*a ".len]u8, @splat("*a ".*)))) ++ "b" ++ &@as([300]u8, @splat('*'));
    _ = try render(emphasis, &out);
    const brackets = &@as([200]u8, @splat('[')) ++ "x" ++ &@as([200]u8, @splat(']'));
    _ = try render(brackets, &out);
}
