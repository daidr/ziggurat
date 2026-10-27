//! Rich text documents: attributed text in styled paragraphs, a document
//! with its selection, typing attributes and undo, the commands a toolbar
//! and the keyboard run on it, and codecs for HTML, RTF, Markdown and the
//! editor's own clipboard format. Pure Zig: the editor that shows and edits
//! a Document is `ziggurat_rich_text_editor`.
const text = @import("text.zig");

pub const Color = text.Color;
pub const Attributes = text.Attributes;
pub const Attachment = text.Attachment;
pub const ListKind = text.ListKind;
pub const Align = text.Align;
pub const ParagraphStyle = text.ParagraphStyle;
pub const Run = text.Run;
pub const Paragraph = text.Paragraph;
pub const Para = text.Para;
pub const AttrRun = text.AttrRun;
pub const Text = text.Text;
pub const RunIterator = text.RunIterator;
pub const RangeIterator = text.RangeIterator;
pub const object_replacement = text.object_replacement;
pub const object_replacement_utf8 = text.object_replacement_utf8;
pub const max_indent = text.max_indent;
pub const byteOfRune = text.byteOfRune;
pub const runeCount = text.runeCount;
pub const decodeAt = text.decodeAt;

const document = @import("document.zig");
pub const Document = document.Document;
pub const Edit = document.Edit;
pub const Selection = document.Selection;
pub const StepMode = document.StepMode;
pub const FormatState = document.FormatState;
pub const Formatting = document.Formatting;
pub const AttributeChanger = document.AttributeChanger;
pub const StyleChanger = document.StyleChanger;
pub const mapPosition = document.mapPosition;
pub const typingAttributesOf = document.typingAttributesOf;
pub const max_undo = document.max_undo;

pub const html = @import("html.zig");
pub const rtf = @import("rtf.zig");
pub const markdown = @import("markdown.zig");
pub const clip = @import("clip.zig");
pub const image_size = @import("image_size.zig");

/// The attributed text of HTML.
pub const parseHtml = html.parse;
/// The attributed text of Rich Text Format.
pub const parseRtf = rtf.parse;
/// The attributed text of Markdown.
pub const parseMarkdown = markdown.parse;
/// `t` as HTML, allocated.
pub const toHtml = html.html;
/// `t` as Markdown, allocated.
pub const toMarkdown = markdown.markdown;
/// `t` in the clipboard's JSON, allocated.
pub const toJson = clip.json;

test {
    _ = @import("tests.zig");
    _ = @import("codec_tests.zig");
    _ = image_size;
}
