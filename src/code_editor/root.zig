pub const results = @import("results.zig");
pub const Kind = results.Kind;
pub const Completion = results.Completion;
pub const Continuation = results.Continuation;
pub const Insertion = results.Insertion;
pub const Hover = results.Hover;
pub const Diagnostic = results.Diagnostic;
pub const Severity = results.Severity;
pub const OwnedResult = results.OwnedResult;
pub const ResultLimits = results.Limits;
pub const requests = @import("broker.zig");
/// Explicit request/result owner; invalidateAll revokes one service epoch
/// without ending physical Job responsibility or stopping ordinary editing.
pub const Broker = requests.Broker;
pub const Job = requests.Job;
pub const Ticket = requests.Ticket;
pub const Limits = requests.Limits;
pub const presentation = @import("presenter.zig");
pub const Presenter = presentation.Presenter;
pub const SnippetPolicy = presentation.SnippetPolicy;
pub const CompletionOutcome = presentation.CompletionOutcome;
pub const CompletionChoice = presentation.CompletionChoice;
pub const CompletionRefinement = presentation.CompletionRefinement;
pub const CompletionDetailsOptions = presentation.CompletionDetailsOptions;
pub const snippets = @import("snippet.zig");
/// Line tokenizers, languages, token themes, bracket matching and word
/// searches, without native dependencies.
pub const syntax = @import("ziggurat_code_syntax");
pub const highlight = @import("highlight.zig");
pub const Highlighting = highlight.Highlighting;
pub const DocumentLines = highlight.DocumentLines;
pub const multicursor = @import("multicursor.zig");
pub const MultiCursor = multicursor.Commands;
pub const git_gutter = @import("git_gutter.zig");
pub const GitGutter = git_gutter.GitGutter;

test {
    _ = results;
    _ = requests;
    _ = snippets;
    _ = @import("completion_details.zig");
    _ = @import("editing_tests.zig");
}
