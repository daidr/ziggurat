//! HTML for a parsed tree in the conventional CommonMark and GitHub
//! output form. Text, attributes and raw HTML from the source are
//! escaped; destinations are percent-encoded where needed.
const std = @import("std");
const md = @import("root.zig");

const Writer = std.Io.Writer;

pub fn write(tree: md.Tree, writer: *Writer) Writer.Error!void {
    var out: Out = .{ .w = writer };
    var image_depth: usize = 0;
    var body_open = false;
    var walker = tree.walk(0);
    while (walker.next()) |event| {
        const node = tree.get(event.index);
        const entering = event.entering;
        if (image_depth > 0) {
            switch (node.kind) {
                .image => if (entering) {
                    image_depth += 1;
                } else {
                    image_depth -= 1;
                    if (image_depth == 0) try imageEnd(&out, node);
                },
                .text, .code, .math => try out.escaped(node.text),
                .soft_break, .hard_break => try out.raw(" "),
                else => {},
            }
            continue;
        }
        switch (node.kind) {
            .document => {},
            .paragraph => if (!tight(tree, node)) {
                if (entering) {
                    try out.cr();
                    try out.raw("<p>");
                } else {
                    try out.raw("</p>");
                    try out.cr();
                }
            },
            .heading => {
                if (entering) try out.cr();
                if (entering) try out.print("<h{d}>", .{node.level}) else try out.print("</h{d}>\n", .{node.level});
            },
            .thematic_break => {
                try out.cr();
                try out.raw("<hr />\n");
            },
            .block_quote => {
                try out.cr();
                try out.raw(if (entering) "<blockquote>\n" else "</blockquote>\n");
            },
            .list => {
                try out.cr();
                if (!entering) {
                    try out.raw(if (node.ordered) "</ol>\n" else "</ul>\n");
                } else if (!node.ordered) {
                    try out.raw("<ul>\n");
                } else if (node.start != 1) {
                    try out.print("<ol start=\"{d}\">\n", .{node.start});
                } else try out.raw("<ol>\n");
            },
            .list_item => if (entering) {
                try out.cr();
                try out.raw("<li>");
                switch (node.task) {
                    .none => {},
                    .unchecked => try out.raw("<input disabled=\"\" type=\"checkbox\"> "),
                    .checked => try out.raw("<input checked=\"\" disabled=\"\" type=\"checkbox\"> "),
                }
            } else {
                try out.raw("</li>");
                try out.cr();
            },
            .code_block => {
                try out.cr();
                try out.raw("<pre><code");
                if (node.url.len > 0) {
                    try out.raw(" class=\"language-");
                    try out.escaped(node.url);
                    try out.raw("\"");
                }
                try out.raw(">");
                try out.escaped(node.text);
                try out.raw("</code></pre>\n");
            },
            .table => if (entering) {
                try out.cr();
                try out.raw("<table>\n");
                body_open = false;
            } else {
                if (body_open) try out.raw("</tbody>\n");
                try out.raw("</table>\n");
            },
            .table_row => if (entering) {
                if (node.header) {
                    try out.raw("<thead>\n");
                } else if (!body_open) {
                    try out.raw("<tbody>\n");
                    body_open = true;
                }
                try out.raw("<tr>\n");
            } else {
                try out.raw("</tr>\n");
                if (node.header) try out.raw("</thead>\n");
            },
            .table_cell => {
                const tag = if (node.header) "th" else "td";
                if (!entering) {
                    try out.print("</{s}>\n", .{tag});
                } else if (node.alignment == .none) {
                    try out.print("<{s}>", .{tag});
                } else try out.print("<{s} align=\"{s}\">", .{ tag, @tagName(node.alignment) });
            },
            .text => try out.escaped(node.text),
            .soft_break => try out.raw("\n"),
            .hard_break => try out.raw("<br />\n"),
            .emphasis => try out.raw(if (entering) "<em>" else "</em>"),
            .strong => try out.raw(if (entering) "<strong>" else "</strong>"),
            .strikethrough => try out.raw(if (entering) "<del>" else "</del>"),
            .code => {
                try out.raw("<code>");
                try out.escaped(node.text);
                try out.raw("</code>");
            },
            .math => {
                try out.raw(if (node.level == 1) "<span class=\"math math-display\">\\[" else "<span class=\"math math-inline\">\\(");
                try out.escaped(node.text);
                try out.raw(if (node.level == 1) "\\]</span>" else "\\)</span>");
            },
            .link => if (entering) {
                try out.raw("<a href=\"");
                try out.url(node.url);
                try out.raw("\"");
                if (node.title.len > 0) {
                    try out.raw(" title=\"");
                    try out.escaped(node.title);
                    try out.raw("\"");
                }
                try out.raw(">");
            } else try out.raw("</a>"),
            .image => if (entering) {
                try out.raw("<img src=\"");
                try out.url(node.url);
                try out.raw("\" alt=\"");
                if (node.first_child == md.none) try imageEnd(&out, node) else image_depth = 1;
            },
        }
    }
}

fn imageEnd(out: *Out, node: *const md.Node) Writer.Error!void {
    try out.raw("\"");
    if (node.title.len > 0) {
        try out.raw(" title=\"");
        try out.escaped(node.title);
        try out.raw("\"");
    }
    try out.raw(" />");
}

/// A paragraph directly inside an item of a tight list.
fn tight(tree: md.Tree, node: *const md.Node) bool {
    const item = tree.get(node.parent);
    return item.kind == .list_item and tree.get(item.parent).tight;
}

const Out = struct {
    w: *Writer,
    last: u8 = '\n',

    fn raw(self: *Out, bytes: []const u8) Writer.Error!void {
        if (bytes.len == 0) return;
        try self.w.writeAll(bytes);
        self.last = bytes[bytes.len - 1];
    }
    fn print(self: *Out, comptime format: []const u8, args: anytype) Writer.Error!void {
        var buffer: [64]u8 = undefined;
        try self.raw(std.fmt.bufPrint(&buffer, format, args) catch unreachable);
    }
    fn cr(self: *Out) Writer.Error!void {
        if (self.last != '\n') try self.raw("\n");
    }
    fn escaped(self: *Out, text: []const u8) Writer.Error!void {
        var start: usize = 0;
        for (text, 0..) |byte, index| {
            const replacement: []const u8 = switch (byte) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => continue,
            };
            try self.raw(text[start..index]);
            try self.raw(replacement);
            start = index + 1;
        }
        try self.raw(text[start..]);
    }
    fn url(self: *Out, text: []const u8) Writer.Error!void {
        for (text, 0..) |byte, index| {
            if (byte == '&') {
                try self.raw("&amp;");
            } else if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.!~*'();/?:@=+$,#", byte) != null) {
                try self.raw(&.{byte});
            } else if (byte == '%' and index + 2 < text.len and std.ascii.isHex(text[index + 1]) and std.ascii.isHex(text[index + 2])) {
                try self.raw("%");
            } else {
                try self.print("%{X:0>2}", .{byte});
            }
        }
    }
};
