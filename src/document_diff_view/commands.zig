const editing = @import("ziggurat_document_editor");
const Side = @import("view.zig").Side;

pub const Command = editing.Command;

/// Text and selection ownership can commit before presentation fails. A
/// returned value is never permission to repeat an already committed command.
pub const Outcome = struct {
    side: Side,
    text_changed: bool,
    selection_changed: bool,
    changed: bool,
    committed_revision: ?u64,
    observed_revision: u64,
    index_required: bool,
    stale_after_commit: bool,
    presentation_error: ?anyerror = null,

    pub fn from(side: Side, value: editing.CommandOutcome) Outcome {
        return .{
            .side = side,
            .text_changed = value.text_changed,
            .selection_changed = value.selection_changed,
            .changed = value.changed,
            .committed_revision = value.committed_revision,
            .observed_revision = value.observed_revision,
            .index_required = value.index_required,
            .stale_after_commit = value.stale_after_commit,
            .presentation_error = value.post_commit_error,
        };
    }
};
