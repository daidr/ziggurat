//! The languages the highlighter knows: how to tokenize, comment and match
//! the brackets of each, found by file name or by a name as fenced code
//! blocks give it.
const std = @import("std");
const syntax = @import("root.zig");
const lex = @import("lexer.zig");
const lexers = @import("lexers.zig");

const TokenKind = syntax.TokenKind;
const Tokenizer = syntax.Tokenizer;
const Lexer = lex.Lexer;
const LexString = lex.LexString;
const words = lex.words;

/// An opening and a closing text, as ( and ), that an editor matches,
/// closes as the opening is typed, and wraps a selection in.
pub const BracketPair = struct {
    open: []const u8,
    close: []const u8,
    /// Kinds of tokens in which typing `open` does not close it, as a quote
    /// typed inside a string.
    not_in: []const TokenKind = &.{},
};

/// What an editor knows of the language of its text.
pub const Language = struct {
    name: []const u8,
    /// Find the language of a file, as ".go" or "Makefile" (`forFile`).
    extensions: []const []const u8 = &.{},
    filenames: []const []const u8 = &.{},
    /// Starts a comment to the end of the line, as "//"; toggling comments
    /// uses it first, then `block_comment`.
    line_comment: []const u8 = "",
    block_comment: [2][]const u8 = .{ "", "" },
    /// Matched and highlighted at the caret; `auto_close` pairs are closed
    /// as they are typed and wrap the selection.
    brackets: []const BracketPair = &c_brackets,
    auto_close: []const BracketPair = &.{},
    /// Characters other than letters, digits and _ that words hold, as -
    /// in CSS.
    word_chars: []const u8 = "",
    /// The indentation the language's files usually have.
    tab_size: u8 = 4,
    hard_tabs: bool = false,
    /// Highlights the text a line at a time; null for plain text.
    tokenizer: ?Tokenizer = null,
};

const c_brackets = [_]BracketPair{ .{ .open = "(", .close = ")" }, .{ .open = "[", .close = "]" }, .{ .open = "{", .close = "}" } };
const not_in_text = [_]TokenKind{ .string, .comment };

fn autoClose(comptime quotes: []const []const u8) [3 + quotes.len]BracketPair {
    var out: [3 + quotes.len]BracketPair = undefined;
    out[0..3].* = c_brackets;
    for (quotes, 0..) |quote, i| out[3 + i] = .{ .open = quote, .close = quote, .not_in = &not_in_text };
    return out;
}
fn cString(comptime quote: []const u8) LexString {
    return .{ .open = quote, .close = quote, .escape = '\\' };
}
const c_operators = "+-*/%=&|^!<>~?:@#";
const slash_comments = [_][]const u8{"//"};
const c_block = [_][2][]const u8{.{ "/*", "*/" }};
const hash_comments = [_][]const u8{"#"};

const auto_dq = autoClose(&.{"\""});
const auto_dq_sq = autoClose(&.{ "\"", "'" });
const auto_dq_sq_bt = autoClose(&.{ "\"", "'", "`" });

// Go.
const go_lexer = Lexer{
    .line_comments = &slash_comments,
    .block_comments = &c_block,
    .strings = &.{ cString("\""), cString("'"), .{ .open = "`", .close = "`", .multiline = true } },
    .words = words(.{
        .keyword,  "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        .type,     "any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr",
        .constant, "true false nil iota",
        .function, "append cap clear close complex copy delete imag len make max min new panic print println real recover",
    }),
    .calls = true,
    .operators = c_operators,
};
pub const go = Language{ .name = "Go", .extensions = &.{".go"}, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq_bt, .tab_size = 4, .hard_tabs = true, .tokenizer = go_lexer.tokenizer() };

// JavaScript and TypeScript.
const js_words_spec = .{
    .keyword,  "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield as",
    .constant, "true false null undefined NaN Infinity",
    .type,     "Array Boolean Date Error Function JSON Map Math Number Object Promise Proxy Reflect RegExp Set String Symbol WeakMap WeakSet BigInt console window document globalThis",
};
const js_strings = [_]LexString{ cString("\""), cString("'"), .{ .open = "`", .close = "`", .escape = '\\', .multiline = true, .interp_open = "${", .interp_close = "}" } };
const js_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &js_strings, .words = words(js_words_spec), .ident_chars = "$", .calls = true, .capital_types = true, .regexps = true, .decorator = '@', .operators = c_operators };
pub const javascript = Language{ .name = "JavaScript", .extensions = &.{ ".js", ".mjs", ".cjs", ".jsx" }, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq_bt, .word_chars = "$", .tab_size = 2, .tokenizer = js_lexer.tokenizer() };
const ts_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &js_strings, .words = words(js_words_spec ++ .{
    .keyword, "abstract declare enum implements interface keyof namespace private protected public readonly type infer is satisfies override module",
    .type,    "any boolean never number object string symbol unknown void bigint",
}), .ident_chars = "$", .calls = true, .capital_types = true, .regexps = true, .decorator = '@', .operators = c_operators };
pub const typescript = Language{ .name = "TypeScript", .extensions = &.{ ".ts", ".mts", ".cts", ".tsx" }, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq_bt, .word_chars = "$", .tab_size = 2, .tokenizer = ts_lexer.tokenizer() };

// JSON.
const json_lexer = lexers.Json{ .lexer = .{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &.{ cString("\""), cString("'") }, .words = words(.{ .constant, "true false null" }), .operators = ":" } };
pub const json = Language{ .name = "JSON", .extensions = &.{ ".json", ".jsonc", ".json5", ".webmanifest" }, .filenames = &.{ ".babelrc", ".eslintrc", "tsconfig.json" }, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq, .tab_size = 2, .tokenizer = json_lexer.tokenizer() };

// Python: every string prefix with every quote.
const python_strings = blk: {
    const prefixes = [_][]const u8{ "", "r", "R", "b", "B", "u", "U", "f", "F", "rb", "br", "Rb", "bR", "fr", "rf", "Fr", "rF" };
    const quotes = [_][]const u8{ "\"\"\"", "'''", "\"", "'" };
    var list: [prefixes.len * quotes.len]LexString = undefined;
    for (prefixes, 0..) |prefix, p| {
        const raw = std.mem.indexOfAny(u8, prefix, "rR") != null;
        const formatted = std.mem.indexOfAny(u8, prefix, "fF") != null;
        for (quotes, 0..) |quote, q| {
            list[p * quotes.len + q] = .{
                .open = quote,
                .close = quote,
                .prefix = prefix,
                .multiline = quote.len == 3,
                .escape = if (raw) 0 else '\\',
                .interp_open = if (formatted) "{" else "",
                .interp_close = if (formatted) "}" else "",
            };
        }
    }
    break :blk list;
};
const python_lexer = Lexer{ .line_comments = &hash_comments, .strings = &python_strings, .words = words(.{
    .keyword,  "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
    .constant, "True False None NotImplemented Ellipsis __name__ __file__",
    .type,     "int float str bytes bool list dict set tuple object type complex frozenset bytearray range Exception",
    .function, "print len open isinstance super self cls",
}), .calls = true, .capital_types = true, .decorator = '@', .operators = c_operators };
pub const python = Language{ .name = "Python", .extensions = &.{ ".py", ".pyi", ".pyw" }, .filenames = &.{ "SConstruct", "SConscript" }, .line_comment = "#", .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = python_lexer.tokenizer() };

// Rust.
const rust_lexer = Lexer{
    .line_comments = &slash_comments,
    .block_comments = &c_block,
    .nest_comments = true,
    .strings = &.{
        .{ .open = "\"", .close = "\"", .escape = '\\', .multiline = true },
        .{ .open = "\"", .close = "\"", .prefix = "b", .escape = '\\', .multiline = true },
        .{ .open = "#\"", .close = "\"#", .prefix = "r", .multiline = true },
        .{ .open = "\"", .close = "\"", .prefix = "r", .multiline = true },
        .{ .open = "'", .close = "'", .escape = '\\' },
    },
    .words = words(.{
        .keyword,  "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while yield",
        .type,     "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box",
        .constant, "true false None Some Ok Err",
    }),
    .calls = true,
    .capital_types = true,
    .decorator = '#',
    .operators = c_operators,
};
pub const rust = Language{ .name = "Rust", .extensions = &.{".rs"}, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq, .tab_size = 4, .tokenizer = rust_lexer.tokenizer() };

// C and C++.
const c_words_spec = .{
    .keyword,  "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Bool _Generic _Noreturn _Static_assert _Thread_local",
    .type,     "char double float int long short signed unsigned void size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t bool FILE",
    .constant, "NULL true false",
};
const c_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &.{ cString("\""), cString("'") }, .words = words(c_words_spec), .calls = true, .directives = true, .operators = c_operators };
pub const c = Language{ .name = "C", .extensions = &.{ ".c", ".h" }, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = c_lexer.tokenizer() };
const cpp_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &.{ cString("\""), cString("'"), .{ .open = "R\"(", .close = ")\"", .multiline = true } }, .words = words(c_words_spec ++ .{
    .keyword,  "alignas alignof and asm catch class concept consteval constexpr constinit co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual xor override final @interface @implementation @end @property self",
    .type,     "wchar_t char8_t char16_t char32_t std string vector map",
    .constant, "nullptr nil YES NO",
}), .calls = true, .capital_types = true, .directives = true, .operators = c_operators };
pub const cpp = Language{ .name = "C++", .extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".ino", ".mm", ".m" }, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = cpp_lexer.tokenizer() };

// Java, Kotlin, Swift, C#.
const java_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &.{ .{ .open = "\"\"\"", .close = "\"\"\"", .escape = '\\', .multiline = true }, cString("\""), cString("'") }, .words = words(.{
    .keyword,  "abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while var record sealed permits yield",
    .type,     "boolean byte char double float int long short void String Object Integer",
    .constant, "true false null",
}), .calls = true, .capital_types = true, .decorator = '@', .operators = c_operators };
pub const java = Language{ .name = "Java", .extensions = &.{".java"}, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = java_lexer.tokenizer() };
const kotlin_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .nest_comments = true, .strings = &.{
    .{ .open = "\"\"\"", .close = "\"\"\"", .multiline = true, .interp_open = "${", .interp_close = "}", .dollar = true },
    .{ .open = "\"", .close = "\"", .escape = '\\', .interp_open = "${", .interp_close = "}", .dollar = true },
    cString("'"),
}, .words = words(.{
    .keyword,  "as break class continue do else for fun if in interface is object package return super this throw try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg",
    .constant, "true false null",
    .type,     "Any Boolean Byte Char Double Float Int Long Nothing Short String Unit",
}), .calls = true, .capital_types = true, .decorator = '@', .operators = c_operators };
pub const kotlin = Language{ .name = "Kotlin", .extensions = &.{ ".kt", ".kts" }, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = kotlin_lexer.tokenizer() };
const swift_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .nest_comments = true, .strings = &.{ .{ .open = "\"\"\"", .close = "\"\"\"", .escape = '\\', .multiline = true }, cString("\"") }, .words = words(.{
    .keyword,  "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws some any self Self super actor nonisolated isolated mutating nonmutating override weak unowned lazy final required convenience",
    .constant, "true false nil",
    .type,     "Int Double Float String Bool Character Array Dictionary Set Optional Void",
}), .calls = true, .capital_types = true, .decorator = '@', .directives = true, .operators = c_operators };
pub const swift = Language{ .name = "Swift", .extensions = &.{".swift"}, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq, .tab_size = 4, .tokenizer = swift_lexer.tokenizer() };
const csharp_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &.{
    .{ .open = "@\"", .close = "\"", .multiline = true },
    .{ .open = "$\"", .close = "\"", .escape = '\\', .interp_open = "{", .interp_close = "}" },
    cString("\""),
    cString("'"),
}, .words = words(.{
    .keyword,  "abstract as base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual volatile while async await var get set init record when where yield",
    .type,     "bool byte char decimal double float int long object sbyte short string uint ulong ushort void dynamic",
    .constant, "true false null",
}), .calls = true, .capital_types = true, .directives = true, .operators = c_operators };
pub const csharp = Language{ .name = "C#", .extensions = &.{ ".cs", ".csx" }, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = csharp_lexer.tokenizer() };

// Shell, YAML, TOML, SQL.
const shell_lexer = Lexer{ .line_comments = &hash_comments, .strings = &.{
    .{ .open = "\"", .close = "\"", .escape = '\\', .multiline = true, .dollar = true },
    .{ .open = "'", .close = "'", .multiline = true },
    .{ .open = "`", .close = "`", .escape = '\\' },
}, .words = words(.{
    .keyword,  "if then else elif fi case esac for select while until do done in function time coproc return exit break continue local export declare readonly unset shift source alias eval exec set trap",
    .function, "echo printf cd pwd test read mkdir rm cp mv ls cat grep sed awk find xargs sudo chmod chown curl git go bun npm",
}), .ident_chars = "-", .variables = true, .operators = "|&;<>=!*?" };
pub const shell = Language{ .name = "Shell", .extensions = &.{ ".sh", ".bash", ".zsh", ".fish", ".ksh", ".command" }, .filenames = &.{ ".bashrc", ".zshrc", ".profile", ".bash_profile", "PKGBUILD", ".envrc" }, .line_comment = "#", .auto_close = &auto_dq_sq_bt, .tab_size = 2, .tokenizer = shell_lexer.tokenizer() };
const yaml_lexer = Lexer{ .line_comments = &hash_comments, .strings = &.{ cString("\""), .{ .open = "'", .close = "'" } }, .words = words(.{ .constant, "true false null yes no on off True False Null ~" }), .keys = true, .ident_chars = "-./", .operators = "|>-*&!?:" };
pub const yaml = Language{ .name = "YAML", .extensions = &.{ ".yaml", ".yml" }, .filenames = &.{".clang-format"}, .line_comment = "#", .auto_close = &auto_dq_sq, .tab_size = 2, .tokenizer = yaml_lexer.tokenizer() };
const toml_lexer = lexers.Toml{ .lexer = .{ .line_comments = &.{ "#", ";" }, .strings = &.{
    .{ .open = "\"\"\"", .close = "\"\"\"", .escape = '\\', .multiline = true },
    .{ .open = "'''", .close = "'''", .multiline = true },
    cString("\""),
    .{ .open = "'", .close = "'" },
}, .words = words(.{ .constant, "true false" }), .ident_chars = "-.", .operators = "=" } };
pub const toml = Language{ .name = "TOML", .extensions = &.{ ".toml", ".ini", ".cfg", ".conf", ".properties", ".editorconfig" }, .filenames = &.{ "Cargo.lock", ".gitconfig", ".npmrc" }, .line_comment = "#", .auto_close = &auto_dq_sq, .tab_size = 2, .tokenizer = toml_lexer.tokenizer() };
const sql_lexer = Lexer{ .line_comments = &.{"--"}, .block_comments = &c_block, .fold_case = true, .strings = &.{
    .{ .open = "'", .close = "'", .multiline = true },
    .{ .open = "\"", .close = "\"", .kind = .variable },
    .{ .open = "`", .close = "`", .kind = .variable },
}, .words = words(.{
    .keyword,  "select from where and or not insert into values update set delete create table drop alter add column index view as on join left right inner outer full cross group by order having limit offset union all distinct case when then else end is null in exists between like primary key foreign references default unique check constraint begin commit rollback transaction if returning with recursive asc desc trigger function procedure replace temporary temp database schema grant revoke cascade conflict do nothing using natural explain analyze pragma vacuum",
    .type,     "int integer bigint smallint tinyint real float double decimal numeric text varchar char boolean bool date time timestamp blob json jsonb uuid serial",
    .constant, "true false null",
}), .calls = true, .operators = "+-*/%=<>!|" };
pub const sql = Language{ .name = "SQL", .extensions = &.{".sql"}, .line_comment = "--", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .tab_size = 2, .tokenizer = sql_lexer.tokenizer() };

// Ruby, Lua, PHP.
const ruby_lexer = Lexer{ .line_comments = &hash_comments, .strings = &.{
    .{ .open = "\"", .close = "\"", .escape = '\\', .multiline = true, .interp_open = "#{", .interp_close = "}" },
    .{ .open = "'", .close = "'", .escape = '\\', .multiline = true },
}, .words = words(.{
    .keyword,  "alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer private protected public",
    .constant, "true false nil",
}), .ident_chars = "?!", .calls = true, .capital_types = true, .operators = c_operators };
pub const ruby = Language{ .name = "Ruby", .extensions = &.{ ".rb", ".rake", ".gemspec" }, .filenames = &.{ "Gemfile", "Rakefile", "Podfile", "Fastfile" }, .line_comment = "#", .auto_close = &auto_dq_sq, .tab_size = 2, .tokenizer = ruby_lexer.tokenizer() };
const lua_lexer = Lexer{ .line_comments = &.{"--"}, .block_comments = &.{.{ "--[[", "]]" }}, .strings = &.{ .{ .open = "[[", .close = "]]", .multiline = true }, cString("\""), cString("'") }, .words = words(.{
    .keyword,  "and break do else elseif end for function goto if in local not or repeat return then until while",
    .constant, "true false nil",
}), .calls = true, .operators = "+-*/%^#=<>~.:" };
pub const lua = Language{ .name = "Lua", .extensions = &.{".lua"}, .line_comment = "--", .block_comment = .{ "--[[", "]]" }, .auto_close = &auto_dq_sq, .tab_size = 2, .tokenizer = lua_lexer.tokenizer() };
const php_lexer = Lexer{ .line_comments = &.{ "//", "#" }, .block_comments = &c_block, .strings = &.{
    .{ .open = "\"", .close = "\"", .escape = '\\', .multiline = true, .dollar = true },
    .{ .open = "'", .close = "'", .escape = '\\', .multiline = true },
}, .words = words(.{
    .keyword,  "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield",
    .constant, "true false null TRUE FALSE NULL",
}), .calls = true, .capital_types = true, .variables = true, .operators = c_operators };
pub const php = Language{ .name = "PHP", .extensions = &.{".php"}, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = php_lexer.tokenizer() };

// Styles and markup.
pub const css = Language{ .name = "CSS", .extensions = &.{ ".css", ".scss", ".less", ".sass", ".pcss" }, .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq_sq, .word_chars = "-", .tab_size = 2, .tokenizer = lexers.css };
const html_brackets = [_]BracketPair{ .{ .open = "<", .close = ">" }, .{ .open = "(", .close = ")" }, .{ .open = "[", .close = "]" }, .{ .open = "{", .close = "}" } };
/// HTML's tokenizer highlights the scripts and styles inside it.
const html_markup = lexers.Markup{ .html = true, .script = js_lexer.tokenizer(), .style = lexers.css };
pub const html = Language{ .name = "HTML", .extensions = &.{ ".html", ".htm", ".xhtml", ".vue", ".svelte" }, .block_comment = .{ "<!--", "-->" }, .brackets = &html_brackets, .auto_close = &auto_dq_sq, .word_chars = "-", .tab_size = 2, .tokenizer = html_markup.tokenizer() };
const xml_markup = lexers.Markup{};
pub const xml = Language{ .name = "XML", .extensions = &.{ ".xml", ".svg", ".plist", ".xsd", ".xsl", ".rss", ".atom", ".csproj", ".storyboard", ".xib" }, .block_comment = .{ "<!--", "-->" }, .brackets = &.{.{ .open = "<", .close = ">" }}, .auto_close = &auto_dq_sq, .word_chars = "-:", .tab_size = 2, .tokenizer = xml_markup.tokenizer() };
pub const markdown = Language{ .name = "Markdown", .extensions = &.{ ".md", ".markdown", ".mdx", ".mkd" }, .filenames = &.{ "README", "CHANGELOG" }, .block_comment = .{ "<!--", "-->" }, .auto_close = &(c_brackets ++ [_]BracketPair{.{ .open = "`", .close = "`", .not_in = &not_in_text }}), .tab_size = 2, .tokenizer = lexers.markdown };
pub const diff = Language{ .name = "Diff", .extensions = &.{ ".diff", ".patch", ".rej" }, .tab_size = 4, .tokenizer = lexers.diff };

// Build and interface files.
const dockerfile_lexer = Lexer{ .line_comments = &hash_comments, .strings = &.{ .{ .open = "\"", .close = "\"", .escape = '\\', .dollar = true }, .{ .open = "'", .close = "'" } }, .words = words(.{ .keyword, "FROM AS RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL" }), .variables = true, .ident_chars = "-", .operators = "=&|;<>" };
pub const dockerfile = Language{ .name = "Dockerfile", .extensions = &.{".dockerfile"}, .filenames = &.{ "Dockerfile", "Containerfile" }, .line_comment = "#", .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = dockerfile_lexer.tokenizer() };
const makefile_lexer = Lexer{ .line_comments = &hash_comments, .strings = &.{ .{ .open = "\"", .close = "\"", .escape = '\\', .dollar = true }, .{ .open = "'", .close = "'" } }, .words = words(.{ .keyword, "ifeq ifneq ifdef ifndef else endif include define endef export override .PHONY" }), .variables = true, .keys = true, .ident_chars = "-./", .operators = "=:?+!@" };
pub const makefile = Language{ .name = "Makefile", .extensions = &.{ ".mk", ".mak" }, .filenames = &.{ "Makefile", "makefile", "GNUmakefile" }, .line_comment = "#", .auto_close = &auto_dq_sq, .tab_size = 4, .hard_tabs = true, .tokenizer = makefile_lexer.tokenizer() };
const protobuf_lexer = Lexer{ .line_comments = &slash_comments, .block_comments = &c_block, .strings = &.{ cString("\""), cString("'") }, .words = words(.{
    .keyword,  "syntax package import option message enum service rpc returns repeated optional required oneof map reserved extend extensions to max stream public weak",
    .type,     "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes",
    .constant, "true false",
}), .capital_types = true, .operators = "=<>" };
pub const protobuf = Language{ .name = "Protobuf", .extensions = &.{".proto"}, .line_comment = "//", .block_comment = .{ "/*", "*/" }, .auto_close = &auto_dq, .tab_size = 2, .tokenizer = protobuf_lexer.tokenizer() };

// Zig: \\ starts a multiline string line that runs to the end of the line.
const zig_lexer = Lexer{ .line_comments = &slash_comments, .strings = &.{ cString("\""), cString("'"), .{ .open = "\\\\", .close = "\x00" } }, .words = words(.{
    .keyword,  "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while",
    .type,     "i8 u8 i16 u16 i32 u32 i64 u64 i128 u128 isize usize f16 f32 f64 f80 f128 bool void noreturn type anyerror comptime_int comptime_float",
    .constant, "true false null undefined",
}), .calls = true, .capital_types = true, .decorator = '@', .operators = c_operators };
pub const zig = Language{ .name = "Zig", .extensions = &.{ ".zig", ".zon" }, .line_comment = "//", .auto_close = &auto_dq_sq, .tab_size = 4, .tokenizer = zig_lexer.tokenizer() };

/// Every known language, in the order lookups try them.
pub const all = [_]*const Language{ &go, &javascript, &typescript, &json, &python, &rust, &c, &cpp, &java, &kotlin, &swift, &csharp, &shell, &yaml, &toml, &sql, &ruby, &lua, &php, &css, &html, &xml, &markdown, &diff, &dockerfile, &makefile, &protobuf, &zig };

/// The language of a file by its name, as "main.go" or "Makefile", or null.
/// A full file name match wins over an extension.
pub fn forFile(filename: []const u8) ?*const Language {
    var start: usize = 0;
    for (filename, 0..) |ch, i| if (ch == '/' or ch == '\\') {
        start = i + 1;
    };
    const base = filename[start..];
    for (all) |language| for (language.filenames) |name| if (std.mem.eql(u8, name, base)) return language;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const extension = base[dot..];
    for (all) |language| for (language.extensions) |candidate| if (std.ascii.eqlIgnoreCase(candidate, extension)) return language;
    return null;
}

/// The language known by a name, as "Go", "TypeScript" or "tsx", ignoring
/// case: its name, an extension without the dot, or a usual alias, as
/// fenced code blocks name them.
pub fn named(input: []const u8) ?*const Language {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 32) return null;
    var buffer: [32]u8 = undefined;
    const name = alias(std.ascii.lowerString(&buffer, trimmed));
    for (all) |language| {
        if (std.ascii.eqlIgnoreCase(language.name, name)) return language;
        for (language.extensions) |extension| if (std.mem.eql(u8, extension[1..], name)) return language;
    }
    return null;
}

/// The name a usual alias stands for.
fn alias(name: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const []const u8 }{
        .{ "go", &.{"golang"} },
        .{ "javascript", &.{ "js", "node", "mjs", "cjs" } },
        .{ "typescript", &.{"ts"} },
        .{ "python", &.{ "py", "python3" } },
        .{ "shell", &.{ "sh", "bash", "zsh", "console", "shellscript", "fish" } },
        .{ "yaml", &.{"yml"} },
        .{ "markdown", &.{"md"} },
        .{ "rust", &.{"rs"} },
        .{ "c++", &.{ "cpp", "cc", "cxx", "objc", "objective-c", "objectivec" } },
        .{ "c#", &.{ "cs", "csharp" } },
        .{ "kotlin", &.{"kt"} },
        .{ "ruby", &.{"rb"} },
        .{ "diff", &.{ "patch", "udiff" } },
        .{ "dockerfile", &.{"docker"} },
        .{ "makefile", &.{ "make", "mk" } },
        .{ "xml", &.{ "svg", "plist" } },
        .{ "json", &.{ "jsonc", "json5" } },
        .{ "sql", &.{ "postgres", "postgresql", "mysql", "sqlite", "plsql" } },
        .{ "toml", &.{ "ini", "cfg", "conf" } },
        .{ "protobuf", &.{"proto"} },
        .{ "css", &.{ "scss", "less" } },
    };
    for (table) |entry| for (entry[1]) |other| if (std.mem.eql(u8, other, name)) return entry[0];
    return name;
}
