# Side-by-side document comparison

`ziggurat_document_diff_view` is an optional module using two existing
`ziggurat_document.Document` objects and their `ziggurat_document_editor.Adapter`
objects. It provides a side-by-side comparison, shared vertical alignment,
bounded visible text preparation, hunk navigation, and atomic hunk revert.
The Documents remain the only text, selection and undo authorities. `View` is
the read-only comparison surface described below. `EditableSplit` additionally
coordinates the two existing Adapters for editing; it does not create another
text buffer or history. `EditableUnified` presents deletions as read-only ghost
rows while only the modified source accepts edits. Both editable surfaces also
display optional bounded intraline results and opt-in paired context folding.
An optional [document accessibility companion](document-diff-accessibility.md)
provides identity-coordinate full-document semantics for the editable surfaces.
The original read-only `View` continues to display whole-line decoration and is
not yet covered by that companion.

## Pair requests and explicit delivery

Create a stable `Inbox` with `Inbox.create(allocator, .{ .a = a, .b = b }, limits)`.
It retains both Documents. `InboxLimits` defaults to two physical jobs, at most
8192 result hunks and 16 MiB of old-plus-candidate result storage; the hard
pending limit is eight. Result storage counts both line-hunk and optional
intraline backing arrays, including unused capacity. Snapshot roots use the
Document's separate allocation budget.
`begin()` captures two persistent Snapshots, borrows their Readers and returns a
`Job` containing its pair-specific `Ticket` and cancellation flag. It starts no
worker. A host may compare directly or send the Job to an explicitly managed
worker:

```zig
var result = try diff.compare(worker_allocator, job.a, job.b, .{
    .cancellation = job.cancellation,
});
try job.release();
// Deliver {job.ticket, result} through an explicit owner-thread task.
```

For line and intraline results from the same Job, compute both before releasing
its Readers, then deliver both owners together:

```zig
var details = try viewing.intraline.compare(worker_allocator, job.a, job.b,
    &result, .{ .cancellation = job.cancellation });
try job.release();
// On the owner, after explicit delivery:
try inbox.publishDetailed(job.ticket, &result, &details);
_ = try inbox.finish(job.ticket);
```

The host owns both values until publication succeeds and must deinitialize both
after any rejected delivery. `publishDetailed` validates both captured stamps,
ordered paired line/byte ranges and the receiving total byte limit, then clones
both source Snapshots. It moves both results without allocation/callback between
the moves, and only then releases the previous display. A moved empty details
result is rejected too. Plain `publish` remains available and installs no details.
The Result fields are immutable metadata after construction; callers must not
forge backing slices or change ranges while comparison/publication uses them.

Keep each result associated with the exact Job which produced it. A Result's
numeric document versions alone do not establish source identity. The Inbox
checks its own identity, slot generation, serial, captured full versions and
current text versions before accepting a delivery. The immutable model Result
must come from comparing the Job's two Readers in their original order.

`Job.release()` releases both Readers and is the worker's final access to its
physical slot. Do not use the Job's Readers or cancellation pointer afterward.
Reader release is not delivery acknowledgement: the stable Inbox, Ticket and
host delivery context must still live until the owner handles the result and
calls `finish(ticket)`. `close()` returns `JobsAlive` until every accepted job is
finished, including a released worker whose successful `App.post` is queued.
Do not call `finish` before that queued task has discharged its responsibility.
If posting fails, the host keeps ownership, joins its worker explicitly, disposes
the result and finishes on the owner thread. The Inbox neither joins nor retries
posts. A copied stale Ticket/Job can be checked only while its Inbox still lives;
none of these handles makes a freed Inbox pointer safe.

`publish(ticket, &result)` moves the Result only on success and retains its own
two Snapshot roots for later revert. Failed publication leaves caller ownership
and the previous display intact. It validates the receiving Inbox's result
budget independently of the producer's budget. A moved Result is rejected even
if its captured versions match a later job. `Full` or allocation failure in
`begin` preserves the current request. A successful new `begin` cancels the old
logical request; cancellation never returns a physical slot early. `stop()`
closes request/publication ingress, cancels jobs and drops the displayed result;
workers still require release and owner finish. Existing Views must close before
the Inbox can close.

Full revisions include selection and composition changes. Publication matches
the full captured versions to the original Job, but checks only current committed
text versions and byte lengths, so caret movement does not rerun comparison.
An actual text edit, undo or redo makes the displayed comparison stale.

## Preparation, drawing and input

Create `View` with an explicit allocator, Inbox, matching pair of Adapters, text
Engine, Window and `Limits`. The View retains its Inbox and both Adapters; it
does not install Content or an input client. The host installs its ordinary UI
Context once and calls:

```zig
try view.prepare(bounds, parameters); // explicit input/layout phase
try view.draw(frame, bounds, .{});    // replay only
```

Forward relevant input through `view.handleEvent(event, bounds, parameters)` in
the host's input callback. It handles wheel scrolling inside the bounds, Up/Down
and Page Up/Down scrolling, F7/Shift+F7 hunk navigation, clicking changed rows,
the header revert button, and Ctrl+Enter to copy the selected original hunk into
the modified Document. It returns false for ordinary text/IME events. While
either Document has active composition, preparation/drawing/revert explicitly
reject it and keyboard handling yields to the host. Resume after cancel, or
request a fresh comparison after commit.

`revert(hunk, .a_to_b)` or `.b_to_a` reads only that source byte range from the
retained Snapshot, checks both current text versions and the target's full
revision, then commits once through `Adapter.replaceMany`. One Adapter undo
reverts the whole hunk operation. Source bytes and the temporary copy have an
explicit `revert_bytes` limit. A failed copy/allocation/version check does not
edit the Document. After a successful text edit, the host must compare and publish
again; drawing stale ranges is rejected. Direct external Document modifications
also require the existing Adapter's explicit `reindex()` contract before that
Adapter can edit again.

All View and Inbox owner operations run on their creation thread. Window scopes
cover native preparation, drawing and revert; teardown holds an App lifetime
scope. Reentrant owner mutation/close returns `Busy`, and resources referenced
by a recorded Frame return `ResourceInUse`. The host must keep App, Window handle
storage, Engine and all allocators valid through close and all accepted delivery
tasks. Cached Layouts make early Engine close fail with `LayoutsAlive`; before
any Layout exists, the host must still ensure the Engine outlives the View.

`Parameters.version` is an explicit style generation. Font, wrapping width,
font direction, bounds and scale changes are detected; changes to the estimated
row height reseed metadata without forcing otherwise reusable native layouts.
Only selection changes use the allocation-free prepare fast path. `draw` accepts
only the exact prepared bounds, scale, current full revisions and comparison
serial. Failed preparation leaves the old owning resources/index intact and
requires a successful retry before drawing; explicit scroll/navigation requests
remain pending. No shaping, file read, worker start or allocation occurs in draw.

## Alignment and limits

The model counts actual LF-containing records: an empty document has no records,
and a final LF does not create an additional comparison row. This differs from
the Document's extra terminal caret line. CRLF and source byte ranges are kept
exact. A hunk pairs its corresponding source records by index; surplus records
get a blank cell on the opposite side. The aligned row height is the larger of
the two complete native paragraph heights, rounded upward to 1/64 DIP. Both sides
therefore begin at the same y even when one wraps more than the other.

Global construction uses compact hunk segments and dense integer height/Fenwick
arrays. It reads no document lines and does no shaping: O(H + R) construction,
O(R + H) retained metadata, O(log R) height updates and scroll lookup, O(log H)
aligned row-to-source lookup. Hunk navigation currently scans O(H) segment
metadata. Heights of unvisited rows are estimates; scrolling extent is refined
as visible paragraphs are measured. Source selection/caret geometry remains the
responsibility of the ordinary Adapter. The comparison surface has no second
selection model.

## Editable split coordination

`EditableSplit.create(allocator,inbox,a,b,window,limits)` uses the same pair
identity and retained comparison Snapshots. It retains both Adapters and the
Inbox; it neither installs Content again nor creates text Layouts of its own.
The host forwards input through `handleEvent` and calls explicit `prepare`
before `draw`. `focus(.a)` / `.b` chooses which existing Adapter binds the
Window's single native TextClient. Pointer input in a column changes that
choice; each Adapter keeps its own Document selection and undo stack.
Creation rejects an already bound client, installed projection or native observer rather
than silently taking another coordinator's policy. Close unbinds its focused
client, revokes its observer tokens, clears its Plans, then releases its clients.
Focus loss may cancel composition through native unbind without a separate text
event; the focus update still prepares both sides before the next paint. The
logical column is retained so a later focus event can bind it again.

Editable alignment uses `document_editor.projectPair`: only visible whole
paragraphs are measured, their larger native height is rounded up to 1/64 DIP,
and a sparse Plan adds padding or insertion gaps. Both candidate Adapters are
published together. The base paragraph trees keep real text heights; the
aligned Fenwick index is separate display metadata. Per-source integer anchors
place the same display row on both sides without measuring all preceding
paragraphs. Native caret, hit testing, selection, visual keyboard navigation
and candidate geometry use those same Adapter placements. Blank cells contain
no copyable text. The terminal empty Document caret line remains a native caret
line, not an invented comparison record.

Typing or hunk revert changes the ordinary Document through its Adapter. The
comparison then becomes stale; `comparison_required` is true and the panes use
ordinary identity layouts without old hunk colors until the host publishes a
fresh request. Hunk revert uses the retained source Snapshot and one target
`replaceMany`, so one target undo reverses it. F7/Shift+F7 and Ctrl+Enter are
presentation commands; ordinary editing is forwarded to the focused Adapter.
Direct native surrounding/reconversion changes also synchronously notify the
coordinator through each Adapter's single explicit native observer. This path
publishes both presentations without waiting for paint. A native edit whose
own layout failed still notifies it; the original edit error is preserved even
if the observer subsequently repairs layout.
The coordinator owns that single native-observer slot. A separate completion/
diagnostic presentation must explicitly join the same host update sequence;
independently registering another observer is rejected. This owner does not
silently fan out native changes or claim that arbitrary stacked presentations
are updated automatically.

### Active source, actual caret and current hunk

`EditableSplit` and `EditableUnified` provide allocation-free owner queries:

```zig
const side = try view.activeSide();
const cursor = try view.cursor();
const current = try view.currentHunk();
```

The split active source is the last successfully bound editor side, initially
B. Blur to a toolbar and window focus loss retain that source; rejected focus
does not change it. Publication follows successful native binding and caret
synchronization. Unified always uses B; clicking a removed A ghost does not
invent an A editing caret. `Info.focused` continues to describe the coordinator's
binding policy, whereas `activeSide` also retains the source after
`blurPresented` withdraws that binding.

`CursorInfo` contains `side`, `byte_offset`, `line`, `utf16_column`, `revision`
and `text_version`. It reads the original Document's primary selection caret,
including a reverse or multiple selection. Offsets are UTF-8 bytes; line and
column are zero-based LF logical-line and UTF-16 coordinates. A preceding CR
remains source text; supplementary scalars consume two UTF-16 units. These are
not visual bidi/wrapped coordinates or grapheme columns. The query works before
layout, after selection-only changes, and for offscreen or folded source text;
it does not reveal, focus, scroll, shape or prepare either Adapter.

`HunkPosition{serial,side,index,inside}` uses the current fresh Inbox display
and the actual source caret line. Nonempty ranges are half open. A zero-line
source range belongs to its insertion-boundary logical line; at EOF without a
final LF, that boundary belongs to the Document's existing last caret line,
rather than a fabricated record after it. Empty Documents still have a real
caret line 0 even though their comparison contains zero records. Equal effective
starts, including several boundaries folded onto that EOF line, prefer the last
item in result order. Before the first hunk, or with no hunks, index is null and
inside is false; between or after hunks it is the last preceding item with
inside false, unless the line is one of its nonempty cells or its zero-line
point. The effective starts remain ordered for validated disjoint source ranges.

This is separate from `Info.selected_hunk`: F7/navigation and ghost/control
selection can change the manual hunk and viewport without moving the Document
caret. Queries do not synchronize or replace that choice. The returned serial
identifies the comparison used for the query; it is not a retained pointer or
permission to queue a later edit. Use the existing stamped presentation actions
for mutation, or re-query after the comparison changes. Generic semantic command
routing and find presentation are separate pending capabilities.

Cursor and hunk queries return CompositionActive while either source is in IME
composition; activeSide remains available. A stale or absent comparison returns
ComparisonRequired from currentHunk, while cursor still reports current source
text. Window/App closure or Inbox stop returns Closed. WrongThread and Busy
are checked before querying state; allocator/native reentry into an in-progress
coordinator operation cannot observe a half-published active source. The original
read-only `View` has no active editing source and does not expose these queries.

Active lookup is O(1); source position uses persistent Document prefix queries
and bounded leaf scans; hunk lookup is O(log H). There is no per-query storage,
visible-row search, whole-document scan, native call or extra shaping. Existing
Document/Inbox ownership bounds the borrowed metadata. `smoke-diff-caret` covers
both editable modes, native binding/blur, primary/reverse selections, UTF-16,
CRLF/empty/EOF boundaries, ghost versus manual selection, wrap/fold/scroll,
allocation-denied repeated queries, reentry, wrong thread, IME/stale/stop/close
and resource cleanup. Pure tests compare binary lookup with an independent
linear oracle, lock equal-boundary behavior and count at most 17 comparisons
for 65536 hunks. These checks do not establish visual quality or complete the
pending command/find capabilities.

When either side has a preedit, `composition_identity` is true and both sides
temporarily use identity geometry. The shared comparison anchor is retained,
but its committed line mapping is not applied to the preedit overlay. Cancel
can restore the same stamped comparison; commit requires another comparison.
The host must not draw the old comparison if preparation fails after an edit:
the edit has already committed and must not be resent.

Editable limits are separate from the read-only View limits: defaults are
262144 rows, 16 MiB index metadata, 128 MiB total requested bytes, 96 visible
rows, 8192 sparse Plan entries, 1024 intraline rectangles and a 1 MiB revert copy.
The hard intraline rectangle limit is 8192. Requested bytes include old plus
candidate index/Plans/marks and temporary records/copies/rectangle scratch. Documents,
Snapshots/results and the Adapters' native Layout/Prepared reservations retain
their own explicit budgets. `stats()` reports live/peak requested bytes and
successful layout updates; it does not call those numbers native memory or a
body-shaping count. Draw only replays the two prepared Adapters and cached row
decoration. With paired context disabled, collapsed application paragraphs
return `FoldedDocument`; open application fold definitions are allowed. Paired
context instead requires both application fold slots empty and owns its own
aligned layer. Ordinary Adapter limits and Frame command/resource
capacities still apply; an oversized frame fails instead of truncating rows.
An individual aligned row is limited to 1000000 DIP. Geometry is virtualized by
whole paragraphs, not by arbitrary fragments of a single enormous paragraph.

If pair construction fails before publication, neither layout is installed.
After a committed pair result, the coordinator first receives the installed
Plan ownership even when an old-resource allocator callback has invalidated the
document/window. It then requires preparation again; it does not free an
installed candidate on an error path. This does not promise rollback of foreign
business callbacks.

## Bounded intraline differences

`intraline.compare(allocator,reader_a,reader_b,&line_result,options)` is a pure,
optional worker operation. It uses the same ordered Job Readers and full captured
stamps as the line result. Inside each hunk, changed records pair strictly by
ordinal position up to the shorter side; surplus records keep only whole-line
decoration. It does not infer matching lines from similarity scores. Each pair
includes its actual terminator: CR, LF, CRLF, embedded NUL and a final newline
are neither normalized nor dropped.

The model decodes Unicode scalars, removes exact common scalar prefixes/suffixes,
and computes a minimal insertion/deletion script for the remaining middle using
an exact LCS table. Equal-cost alternatives delete first. Returned `Span` values
carry hunk ordinal, both source line IDs and half-open original UTF-8 byte ranges.
They never split a scalar. They can split a grapheme, including a combining mark
or a component of a ZWJ emoji; the pure model does not claim to shape graphemes.

Default limits are 16 MiB requested working/output bytes, 16384 bytes and 8192
scalars per paired record, 4096 pairs, 4096 output spans, 2097152 cumulative table
cells and 33554432 cumulative work units per comparison. Work charges hunk/pair
visits, source bytes, decoded scalars, common prefix/suffix scalars and table cells. Cells use
four bytes each and count across all pairs, while one pair's scratch is released
before the next. Output growth includes old and candidate storage at its peak.
The already-owned line result and any previous display are separate from this
producer budget; the receiving Inbox also enforces its combined peak limit.
Hard caps and checked arithmetic bound every allocation. `CellLimitExceeded`,
`WorkLimitExceeded`, `CapacityExceeded`, cancellation and OOM return no partial
result. Cancellation is checked before reads, allocations/work phases and each
DP row; unchecked inner work is bounded by a record scan/copy or one DP row. Result ownership
uses `isOwned`/`take`/`deinit`, including zero-span results.

During explicit editable `prepare`, only visible source rows query the existing
Adapter range geometry. Scalar ranges expand to complete cached grapheme advance
cells and preserve all bidi islands. Empty ranges and terminator-only ranges
without advance cells use the same source's cached caret rectangle. A deleted
ghost's ranges and caret always belong to A; they never acquire a B offset.
There is no native shaping or allocation in these geometry queries. Prepared
rectangles are clipped to their source viewport and retained by comparison serial
and both Adapter projection versions. Selection changes through the owning Adapter reuse them without
new geometry queries. Scroll, wrap, DPI, style and other projection changes rebuild
them. `intralineRects(caller_buffer)` copies the prepared rectangles;
`stats().intraline_rectangles` and `intraline_queries` expose retained count and
attempted range-query count. Draw paints them using `deleted_detail`/`added_detail`
before the same already-prepared text and ordinary selection/caret decoration.
It neither diffs strings nor shapes text, and does not replay text once per mark.

If either side composes, both sides switch to identity and hide intraline marks.
Cancel can restore the same committed result; commit, undo and redo invalidate
its text stamp until another comparison is published. Rectangle capacity/OOM
after paired layout publication leaves those installed Plan responsibilities
owned by the coordinator and returns a layout error. The host must retry prepare;
it must not resend an edit or assume the published pair was rolled back. Old plus
candidate marks and scratch are counted in the coordinator's requested-byte
budget. Old-mark destruction runs only after adoption of the new owner, under
Window/App lifetime pins; a destructor closing the host invalidates drawing.

## Editable unified presentation

`EditableUnified.create(allocator,inbox,a,b,window,limits)` uses the same pair,
budgets and owning coordinator as the split surface. Its `prepare`, `draw`,
`rowInfo`, `info`, `stats`, `scrollBy`, `navigate` and `handleEvent` contracts are
the same. `focus()` binds only modified Adapter B. `revert(hunk)` copies original
A into B; it has no reverse-direction editing action. Original A is read-only
for this surface, while the host may still explicitly change it and compare
again. It never installs a second TextClient or copies either Document/history.

The unified index orders common records, then all deleted A records and all
added B records for each hunk, followed by the next common range. `rowInfo`
has `b=null` for a removed ghost; such a row has no modified-document byte
offset. A ghost click selects the hunk and leaves B's selection/revision alone.
Ordinary text/selection/dragging/visual keys and IME use B's existing projected
Adapter. Arrow navigation skips ghost rows, and Page/reveal use its real gaps.
Typing into an initially empty B works even when the entire visible surface
consists of ghosts; it invalidates the comparison and shows B's identity layout.

Both Adapters prepare at the same full width. B's Plan reserves gaps for removed
rows; A's reserves gaps for added rows. B is replayed normally once. A is replayed
once through `Adapter.drawParagraphs(frame,bounds,sorted_source_ids,color)`, which
merges the bounded ghost IDs with the already prepared paragraph placements.
It reuses the exact Prepared resources and clips, emits no A selection/IME/caret
marks, and neither shapes nor allocates. It does not replay a full pane once per
ghost. The filter accepts at most 768 strictly increasing real source paragraph
indices and requires a current projected layout. Invalid indices poison the
Frame under the ordinary failure/reset contract.

The unified metadata builder temporarily expands each model hunk into deletion
and addition descriptors, then reuses the same integer height/Fenwick owner.
Both scratch and retained metadata count against `index_bytes` at their peak,
as well as the coordinator's old-plus-candidate byte budget. Construction is
O(H + U), retained metadata O(H + U), and scroll/height updates O(log U), where U
counts unified display records; it reads no source lines or text. Real paragraph
measurement remains bounded to explicit visible/prefetched prepare work. Changes
to width/DPI/style rebuild the appropriate metadata and native candidates; draw
only replays them. If B composes, the view temporarily displays only B identity
and hides ghosts; cancel restores the same comparison, commit requires a new one.
Application-owned fold layers cannot be combined with this presentation. The
paired context layer below reserves the same Adapters' empty fold slots.

Only explicit prepare queries and shapes bounded whole visible/prefetched source
paragraphs. A batch never splits a paragraph or a grapheme, and uses the existing
native bidi/wrap implementation. Bounded warm batches may remain cached. Coverage
is prepared for the visible source viewport and replayed in row clips, allowing
alignment padding without reshaping text. A single enormous paragraph can exceed
the paragraph/native-layout limit and is rejected; this is not horizontal text
virtualization. Native text-engine input restrictions, including embedded NUL,
still apply even though the pure diff model accepts such bytes.

Defaults are 262144 aligned rows, 16 MiB of index metadata, 48 visible rows,
12 native batches, at most 16 paragraphs/16 KiB per prospective batch, 64 KiB per
paragraph and 1 MiB per revert. Hard limits are 2097152 rows, 96 visible rows,
24 batches and 32 paragraphs per batch. A first paragraph can exceed the soft
batch-byte target, up to the explicit paragraph cap. Exceeding row/batch/paragraph
or visible-row budgets fails explicitly rather than drawing a truncated result.
`Limits.bytes` defaults to 512 MiB and covers old plus candidate index, text cache,
temporary revert copy and conservative native reservations. Each native Layout
reserves its Engine hard 4 MiB bound; each Prepared reserves its configured byte
limit, so reservation is intentionally larger than measured live native memory.
Documents, model results/Snapshots and host Adapters have their own budgets.
`stats()` reports these reservations and attempted body-shaping batches/bytes,
including work from failed prepare. Headers use separate small native Layouts.
Their owning resources are shared between old and candidate views when the font
generation, scale and header height match; origin changes only affect replay.
`header_layouts` and `header_prepared` count native header construction attempts
(including failures), and `header_reuses` counts retained header resources.
Warm scrolling performs neither body shaping nor header Layout/Prepared creation;
visible body coverage is still explicitly prepared for its updated viewport.

## Paired context folding

`EditableSplit` and `EditableUnified` support `setContext(?ContextOptions)`;
call explicit `prepare` after changing this desired configuration. Null disables
the layer. Defaults retain three real common source records on each side of a
common segment and collapse an interior only when it contains at least four
records. Changed rows and unified A ghosts are never hidden by this policy.
The header is the last retained real source line before the hidden range; no
synthetic text, B offset, text buffer or undo record is introduced. A 12 DIP
gutter is reserved while the option is enabled.

The layer owns a generation token for each Adapter's otherwise empty fold slot.
Existing application fold definitions cause `FoldOwnerConflict`; the layer
neither clears nor steals them. Both Adapters remain the only fold/selection/
TextClient authorities. Ordinary visual navigation skips their hidden bodies.
Placing any caret inside a collapsed body returns `CaretInsideFold` before
changing Document selection. `reveal(side, source_byte_position)` on split, or
`reveal(source_byte_position)` on unified B, expands the corresponding paired
region and scrolls it into view without changing selection. The host can then
select through the same Adapter. Closing the view revokes both tokens without
allocation; nonempty revoked indexes require the Adapter's next explicit
prepare/reindex. Token copies are meaningful only while that Adapter lives.

`contextRegions(caller_buffer)` copies only prepared visible header records,
including `ContextKey{serial,id}`, original A/B hidden line ranges, collapsed
state and optional header rectangles. A key is scoped to this Inbox comparison;
a newly received comparison invalidates old keys even if bytes match. Context
configuration changes can remove regions. `setContextCollapsed(key, bool)` is
an explicit synchronous prepare transaction. Native clicks on the prepared
gutter call the same operation; collapse fails if it would hide a live caret.
No diff, shape, allocation or scan of all regions occurs during draw.

One candidate transaction constructs the context metadata, filtered row/Fenwick
index, both folded roots, native visible layouts, paired Plans and exact
intraline marks. Both Adapters stay Busy. Candidate errors, including native
layout, marker-capacity and allocation errors, precede both publications and
preserve the installed folds, Plans and viewport. Both pure ownership swaps
occur before releasing old resources. Foreign destructors can subsequently
change a Document or close the host; installed ownership remains the view's,
and it reports stale/closed presentation until a valid prepare.
Unknown external Document modifications still cross the separate explicit
reindex boundary; they cannot be undone by this presentation transaction.

Any active composition temporarily clears both derived fold layers, uses both
identity layouts and hides comparison decorations. Its shorter overlay uses
overlay coordinates rather than the original committed selection. Cancel can
restore retained region choices under the same text stamps; text commit/undo/
redo invalidates the comparison and old derived ranges. A fresh comparison
constructs new default regions. Disabling context also clears both layers in
the same candidate transaction before revoking their tokens.

`ContextOptions` defaults to 4096 regions, 2097152 raw rows and 1 MiB per context
metadata owner; hard limits are 65536 regions, 2097152 rows and 64 MiB. It owns
compact common-region/visible-segment records, not source bytes. Construction
and toggle clone/rebuild cost O(F), with binary raw/visible lookup O(log F).
The coordinator explicitly rebuilds the aligned raw and filtered height arrays
in O(R + F + H), where R is comparison rows and H hunk segments; it does not
read/shape every source line. Base plus candidate height arrays count against
`index_bytes`; retained old owners, candidates, both fold definitions, Plans,
native reservations, marks and scratch also count against the coordinator's
`Limits.bytes` (128 MiB by default for editable surfaces). Adapter and Engine
budgets remain independent. Full-document text semantics are supplied only by
the separate [optional companion](document-diff-accessibility.md); a visible
excerpt is not represented as the complete Document. Hunk/fold semantic controls
and the original read-only surface remain outside that companion's first slice.

## Typed owner commands

`EditableSplit.run(command, selection_scratch)` and
`EditableUnified.run(command, selection_scratch)` accept the typed `Command`
union: `undo`, `redo`, `select_all`, `set_selection` and
`replace_selections`. Replacement text is borrowed and immutable until return.
They operate on the last successfully active source, retain that source after
toolbar blur, and do not acquire native focus or change manual hunk selection.
Unified commands always target B; A ghost rows remain read-only. The original
read-only comparison surface does not expose this entry point.

Scratch is exclusive through return and needs **twice the current canonical
Document selection count**. This is independent of semantic-control capacity.
An insufficient slice fails before candidate preparation or mutation. The two
halves capture canonical before/after selections, including direction, order
and primary. An undo restoring a different number of selections does not need
larger post-commit scratch. Replacement preserves Document's multi-selection
rules and commits one text transaction and one undo entry.

`CommandOutcome.text_changed` means the committed text publication stamp
advanced, including an identical-byte replacement. It does not scan the whole
text to compare bytes. `selection_changed` compares exact canonical selection
values and primary; `changed` is their union. `committed_revision` is captured
immediately after the sole Document transaction, before Adapter metadata
reclamation. `observed_revision` is read again after presentation work. Thus an
allocator callback that independently edits the source after commit produces
`stale_after_commit` and `index_required`, without losing the original receipt.

The owner gate checks both source revisions, composition, active source,
window/application/inbox lifetime, and disabled/modal state. The target gate
joins the existing native-input gate in **one** final Document commit guard.
An error before publication leaves the command uncommitted. Once publication
occurred, subsequent layout/native/owner errors return an outcome with
`presentation_error`; they are not retryable command errors. A presentation
failure preserves its original error even if a later check also detects stale
or closed state. Hosts should repair/reprepare presentation and request a new
comparison as required, rather than replay an already committed command.

`Adapter.runCommand(command, gate, selection_scratch)` exposes the same typed
transaction to another explicit owner. The gate's callback/context stay stable
through return, run on the owner thread, and must not allocate or query the
busy target Document/Adapter. The Adapter checks the target revision itself;
the callback supplies the owner's remaining policy. A native caller can hold
`beginNativeInput` around this operation without installing a second guard.
The final outcome also rechecks that native scope after foreign cleanup:
application quit or a revoked/disabled/modal text client after commit becomes
`post_commit_error` and `stale_after_commit`, with the committed receipt intact.
The command adds no default heap owner, worker, search index or paint-time work.
Existing explicit Document/Adapter candidate, history and presentation budgets
still apply. Preparing visible layouts can allocate and shape; scratch capture
and outcome comparison are O(S) for S selections and allocate nothing.

The broader command vocabulary remains a separate slice.

## Explicit literal Find

`Find.create(allocator, coordinator, limits)` is an opt-in owner for bounded
literal searches. Pass an editable split owner, or a unified owner's
`coordinator()`. Creating a normal comparison does not create a Find, queue,
search index or worker. The coordinator remains pinned until Find's final
foreign allocator free returns. App and coordinator must outlive Find; do not
copy the owning pointer's storage or use tickets after its close.

`begin(pattern, options)` runs on the owner thread. It copies and validates a
nonempty UTF-8 pattern, captures one immutable Document Snapshot/Reader and the
current source stamp, then returns a linear `find.Work`. It does not shape or
scan the body. The default query limit is 4096 bytes, with an explicit hard
limit of 65536. Prefix storage is `P * @sizeOf(usize)` for P pattern bytes.
The pattern remains valid and unchanged through begin's allocator callbacks;
after return the caller can release it. Snapshot capture also copies O(S)
canonical selection metadata under Document's budget, while retaining its
committed root without copying the body.
The default two physical slots can be configured from one to eight. A new
success cancels the prior current query; Full, invalid input, failed allocation
or stale capture leaves that query and its physical responsibility intact.

The host transfers Work to one explicit worker. `Work.prepare()` performs the
existing search Iterator's O(P) prefix preparation, without allocation. Its
`preparation_work` reports a conservative **3P charge**, not an exact measured
comparison count: each prefix position has at most one successful `while`
comparison and one final `if` comparison, and failed comparisons that decrease
the prefix length cannot outnumber earlier increases. UTF-8 validation, query
copy and bounded Reader/tree bookkeeping are separate O(P) or bounded costs;
this charge is not a CPU-time limit. `Work.step(max_comparisons)` then performs
at most that many actual scan comparisons, including prefix fallback, and
returns yielded or complete. One step returns after a found occurrence rather
than starting a new allowance for the next match. The total `limits.work`
deducts 3P plus the Iterator's accumulated actual scan comparisons; exhaustion
returns WorkLimit. Zero-comparison EOF publication still validates cancellation
and the Reader lease. `progress()` belongs to the same exclusive worker.
Preparation checks cancellation at its bounded phase boundaries; scan steps
also use the Iterator's periodic cancellation checks.

Next starts its Reader cursor at the captured selection end, rather than
rescanning an unrelated prefix. Only if no eligible match exists does wrapping
scan the required beginning range, including up to P-1 bytes across that
boundary. Previous scans `[0, selection.start)` and returns its last eligible
match immediately at that range end; it does not continue through an unrelated
suffix. Only an empty eligible set enables its wrap scan. Wrap endpoints round
outward to UTF-8 scalar boundaries by at most three bytes and still filter the
original byte boundary. `Document.search.Iterator.restart(range)` seeks the
same Reader without rebuilding the prefix, preserves actual comparisons and
cumulative scanned bytes, and leaves the iterator unchanged on rejection.
The absolute `next_byte` can jump at restart, while scanned bytes remain
cumulative. Seeking/endpoint validation walks the bounded Reader tree and does
not build another index. A previous search still has linear worst-case work
in its necessary prefix; a wrap can also visit a full document.

Options select next/previous, wrapping, and exact or ASCII-insensitive matching.
ASCII-insensitive mode folds only ASCII letters; other UTF-8 bytes remain exact.
Occurrences overlap. Next chooses the first match whose start is at or after
the captured selection end. Previous chooses the last match whose end is at or
before the captured selection start. With wrapping it uses the first or last
occurrence if that eligible set is empty. Thus previous `aa` in `aaa` at caret
3 selects `[1,3)`. A wrap may return the sole occurrence again. Regex, locale
case folding, whole-word filtering and Find UI are outside this API.

After completion, cancellation or a worker error, `Work.release()` relinquishes
the Reader and is the worker's final shared-memory access. A failed release
retains its responsibility for retry; copying Work never creates another
worker/release permission. Each atomic authorization combines a nonwrapping
serial and phase, so an old Work copy cannot authorize a newly reused slot.
Release does not reuse a slot or acknowledge an accepted delivery.

The host posts its own stable context through `App.post`. Full or Closed leaves
that context, ticket and retry/disposal responsibility with the caller. After
an accepted task's last use, the owner calls `finish(ticket)`. A released but
unfinished ticket keeps the physical slot occupied even after cancellation.
`finish` can also dispose of an abandoned result without applying it; a
WorkerRunning or ReadersAlive error retains responsibility. Once finish starts,
a temporarily blocked Snapshot close cannot make that result applicable again.
The host must not finish or free a context while its accepted task is pending.

`apply(ticket, selection_scratch)` is owner-only and only accepts a released,
current result once. It returns null for no match, or the existing command
outcome for a selection. Scratch is the existing explicit 2S selection capacity,
not the number of matches. The source stamp includes coordinator identity,
mode, last active side, nonwrapping successful acquisition generation, both
Document revisions/text versions and primary selection. Acquisition means the
Adapter has successfully bound the live native text client: it changes the
last source and generation even if the following caret presentation reports an
error. That error does not undo the native binding or preserve the old source
authorization. Generation exhaustion is rejected before unbinding either side.
A-B-A focus changes, selection away-and-back, IME begin/cancel and equal-text
edits invalidate an old
result. Blur preserves the last source. Unified search always targets B; ghost
A text never acquires B edit offsets.

The full stamp is rechecked under the coordinator's same busy gate that spans
command preparation, its final Document guard and all presentation cleanup.
Foreign allocator callbacks cannot reacquire the source between those checks.
Independent target/peer edits, active composition, disable/modal state, stop or
close are rejected by the existing owner/native gates. A match selects original
UTF-8 byte boundaries; cursor/IME positions still come from Document's UTF-16
mapping. The existing selection path reveals folded source rows. Search
creates no text-history entry or second selection authority. The fold reveal
and Document mutation retain their existing separate presentation contracts;
this API does not claim a cross-domain fold/text rollback transaction.

Once the selection commits, later allocation, layout, peer edit or close errors
remain in the returned committed outcome. The ticket is consumed, and repeating
it returns AlreadyApplied. Pre-commit rejection leaves it unconsumed, although a
stale source can never become fresh by returning to equal content. No-match
application also consumes the ticket once without changing the Document.

`stop()` is explicit, idempotent and nonblocking: it seals ingress and requests
cancellation, without joining workers or waiting for UI tasks. The host calls it
from its own shutdown/Stop participant, joins or otherwise retires its workers,
and lets all accepted posts execute once before finishing their tickets.
`close()` returns JobsAlive until every ticket is finished. Owner finish/cancel/
stop/close remain available under teardown scopes after application stop;
begin/apply reject a stopping or closed App/Window. Find never keeps a zero-window
application running implicitly. A reentrant owner operation returns Busy and
can be retried after the enclosing operation returns.

`limits.bytes` is the total requested-byte bound for Find/physical-pool metadata,
slots, owned queries and prefix buffers, including concurrent old/candidate
buffers. Its default is 256 KiB and hard limit is 64 MiB. `stats()` reports their
actual current and successful-allocation peak bytes. Document Snapshot nodes,
copied selections and Reader slots stay in the Document's own explicit budgets;
native Adapter/layout allocations retain their separate budgets. Those costs
are not disguised as part of the Find byte bound. Each pending slot pins one
immutable root; no body copy or additional full-text index is created.

## Verification

`zig build test-document-diff-view` covers paired physical delivery lifetime,
cancellation/full/stale generations, result moves, receiving budgets, worker
snapshot isolation, allocation failure and Fenwick/linear-oracle boundaries.
`zig build smoke-document-diff-view` exercises actual native text/pixels, one-sided
wrapping/blank alignment, empty and terminal-LF cases, queued worker delivery,
native keyboard/pointer/wheel input, atomic revert and undo, 100000-row bounded
visible shaping/scroll, IME rejection, failed Frame and close with zero retained
text/native resources. Run the Linux target under an isolated X server; the
fixture also checks physical-pixel mapping at `GDK_SCALE=2`. These automated
checks establish runtime behavior, not visual design quality.

The same target imports `document_diff_editable_smoke.zig`,
`document_diff_editable_edges.zig`, `document_projection_commit_smoke.zig` and
`document_native_observer_smoke.zig`. They cover editable native keys/pointer/
characters, aligned caret/hit/pixels, actual IMM document-feed/reconversion and
candidate coordinates, GTK surrounding deletion without a UI text event,
composition focus loss/cancel, 1000-line reveal, 16 allocation failure offsets,
empty/terminal-LF/trailing insertion ranges, one-undo revert, and owner-context
release after a close allocator callback. Old-Prepared destruction also changes
the document or closes a window after publication to verify committed outcomes.
These checks exercise native APIs; they do not establish every installed
language engine or TSF behavior.

`document_diff_unified_smoke.zig` also runs in that target: native deleted/added
pixels and glyphs, read-only ghost clicks, sole B binding/edit/undo, visual keys
across ghosts, resize/caret alignment, a bounded 200-row deletion against empty
B, multiple hunk revert, composition identity/cancel, failed filter/Frame and
close. The pure target adds a 300-model independent linear unified-record oracle,
fractional Fenwick checks, move rejection and every metadata allocation failure.

`intraline_test.zig` adds 512 random scalar-sequence comparisons against an
independent prefix-DP distance and byte-reconstruction oracle, Unicode/CRLF/NUL
cases, common-prefix/suffix reduction, cumulative work/cells, every allocation
failure, output growth and cancellation after DP allocation. Inbox tests cover
atomic dual moves, narrower receiving peak budgets and a worker finishing from
immutable Readers after owner edits. The same native target additionally runs
`document_diff_intraline_smoke.zig`: both editable modes draw actual highlight
pixels, full combining/emoji graphemes, multiple bidi islands and an empty-side
caret. It checks selection-only retention, no draw shaping/query work, IME
hide/cancel/commit, undo, marks OOM after pair publication, old-mark release
closing the host, failed Frames and final zero native/text resources.

`context_index_test.zig` adds linear visibility/height/source oracles, 250 random
toggle/reveal steps per display mode, all metadata allocation failures and a
100000-common-row metadata bound. `document_fold_pair_smoke.zig` and
`document_diff_context_smoke.zig` run in the same native target. They check
paired fold/layout publication, candidate Prepared geometry versus published
geometry, rejecting/closing candidate callbacks, both-side allocator failures,
marker capacity before publication, actual gutter pixels/clicks and native
keys across hidden text, caret refusal/reveal, shorter/multiline composition,
edit/undo/stale keys, application-slot conflicts, no-allocation token revoke,
failed Frames and final zero resources.

`zig build benchmark-document-diff-view -Doptimize=ReleaseSafe` excludes document
creation and comparison/setup. It measures first prepare for 10000/100000 records,
64 selection-only updates and prepares, then 64 warm alternating +20/-20 DIP
scroll updates. These are CPU layout/update times; replay, upload and native
presentation are excluded. Body batch counts and header Layout/Prepared attempt
counts are reported separately, alongside header retention and conservative
peak reservations. Local samples taken alongside other builds describe that
machine/run and are not an isolated performance baseline.

`zig build smoke-diff-commands` runs hidden native editable split/unified
commands, toolbar blur, actual UTF-16/CRLF selection coordinates, multiple
selections with one undo, composing/disabled/stopped rejection and caller
scratch limits. It injects allocator callbacks before Document publication and
after commit, including independent target/peer edits, window close and app
quit; committed results retain the original receipt and native owners release
only after the command's window scope exits. The pure Adapter target checks
exact selection capture, different restored selection counts and an explicitly
configured 97-selection Document. The native target walks the reached
Document/Adapter/presentation allocation sites to the first uninjected success;
pre-commit errors preserve text, selection and owned Document bytes, while
post-commit OOM returns the receipt and remains one undo. It verifies zero
tracked text/native owners and stable warmed Windows GDI/USER counts.
Direct Adapter tests combine an explicit native scope with a permissive owner
callback, then disable before/after commit or quit after
commit, proving the native gate remains independent of the Diff owner policy.

Affine body input can explicitly borrow `acquireCoordinates(space_id)`. The
Windows document companion manages that borrow when its affine option is set;
other publishers must supply the same successful-front association and retire
their publication borrow before closing it. Attach the Context, record the
whole prepared body in its one capture scope, then install its accepted Space.
The binding's two fixed records and lease are charged to the existing View byte
budget. This changes fixed owner metadata; it does not add a per-frame
allocation, second text model, worker, shaping pass or geometry query.

Direct `handleEvent` borrows the accepted coordinate generation for that input
call. Pointer mapping, native binding, final Document guards and all four paired
projection paths check it independently of auxiliary action epochs. Composition
keeps its existing identity projection without bypassing the coordinate gate.
Programmatic preparation can still rebuild a candidate before the next accepted
front. After opting in, retiring the coordinate binding cannot restore a DIP
input fallback. Close withdraws the entrance before unbinding; callback-delayed
unbinding and publisher retirement must complete before freeing the binding.

The Windows companion can draw typed revert/context Controls in that same
scope. It publishes their actual local rectangles and a separate common visible
polygon with both text sources and the same sole lease. The body capture does
not clip an outside-body toolbar. `setContextPresented` captures the entering
coordinate generation before candidate work and requires that exact generation
at the paired final guard, including replacement by another valid generation
with the same numeric Frame stamp. Typed action outcome/undo ownership remains
with the existing View and Documents; custom nested affine auxiliary trees are
still rejected by the companion.

`zig build smoke-diff-find` runs split/unified hidden native Find with an
explicit worker and actual App.post. It covers Full without ownership transfer,
once-only accepted delivery, Closed during shutdown, successful source
acquisition A-B-A and a successful bind followed by rejected caret geometry,
selection and IME ABA, blur, disable, folded-source reveal, peer changes before
commit and an independent edit after commit. Construction
callbacks close/quit at each Find/pool allocation and immediately release the
entire owner host in on_closed; candidate cleanup retains its pins through the
last foreign free. Pure tests include 512 independent overlapping linear
direction oracles, dense one-byte matches, prefix fallback, small work budgets
near either end of a large body, strict step counts, allocation failure,
Reader/finish retries and stale Work copies after physical-slot reuse.
