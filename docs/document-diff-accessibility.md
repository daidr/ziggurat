# Editable Diff document accessibility

`ziggurat_document_diff_accessibility` is an optional Windows UIA companion for
`EditableSplit` and `EditableUnified`. It uses the existing two Documents and
Adapters. It owns native text/geometry snapshots, not another text buffer,
selection, undo history, native text client or comparison worker.

The original read-only `View`, AT-SPI and macOS accessibility are separate work.
Editable comparisons can opt into the bounded
typed controls and focus handoff below.
Unsupported platforms reject `Bridge.create` before allocation or retaining a
target. Identity drawing is the default; transformed or offset Frames require
the explicit affine mode below.

## Ownership and explicit preparation

Create the Diff coordinator first, then create the companion:

```zig
const bridge = try accessibility.Bridge.create(allocator, window,
    .{ .unified = unified }, .{});
try bridge.attachContext(&context);
```

Use `.split = split` for a split coordinator. The companion retains that
coordinator; `View.close` returns `ClientsAlive` until the companion is closed.
The inner document bridge retains both Adapters and native callbacks retain
independent native state. Close the companion before the coordinator and the
Adapters. App, Context while installed, and the supplied allocator cover these
operations. The final allocator free still holds the coordinator's client pin.
Late COM ranges/providers cannot call detached Zig objects.

After each explicit Diff preparation, prepare the companion outside paint:

```zig
try unified.prepare(bounds, parameters);
try bridge.prepare(.{ original_reader, modified_reader });
// In the Context draw callback:
try bridge.draw(frame, colors);
```

Readers borrow the complete source Documents at their current revisions. A
changed committed text needs its Reader; selection-only refresh can pass null.
`bridge.draw` records the prepared Diff and geometry together. Alternatively,
draw the same prepared Diff yourself and call `bridge.record(frame)` afterwards.
There is no drawing-time shaping, heap allocation or native geometry query.

`Options.accessibility.bytes` includes the companion shell and the inner
bridge's native/host staging ledger. Native mirrors, old and candidate geometry,
temporary copied cells/carets and MTA ranges use that explicit ceiling. Text
layout, Document snapshots and the Diff coordinator keep their own budgets.
The companion uses fixed 96-row/paragraph scratch and does not copy all Diff rows.

## One accepted coordinate space

Set both `.accessibility.affine_geometry = true` and a nonzero
`.affine_space_id` to opt into affine body input and geometry. Prepare the
Context transform workspace before recording. Draw or record the entire Diff
inside one transform/clip scope; both columns and their native geometry must
share it. After the first successful paint, install that exact capture with
`bridge.setCommittedSpace(try context.committedSpace(id))`. Repeat this explicit
installation after releasing and recreating the workspace. `syncNativeCaret`
uses the same accepted mapping for the existing native TextClient.

The companion owns one coordinate binding in the Diff budget. Its two fixed
POD records distinguish the accepted front from its candidate using the full
publication, source, candidate and workspace epoch/generation tuple. The native
geometry publisher checks that association before publishing. A failed frame
preserves the old successful front; a successful frame missing the matching
body record withdraws both native geometry and input authority. An overwritten
candidate cannot authorize a different frame. No drawing callback commits
Document edits, shapes text or allocates the coordinate records.

Pointer hit testing, selection, keyboard input, native read/change and caret
use the original Adapters and Prepared data. Authority is checked before and
after foreign work and again at Document/pair publication. An already committed
native Document edit followed by authority loss returns `superseded`; an
unrelated presentation error is reported once while the edit remains `applied`.
This prevents replay of a completed edit. Exhausted generations permanently
deny further publication and input while still permitting owner cleanup.

Affine mode accepts the existing typed `Controls` drawn by `bridge.draw` in the
body's exact transform, clip and offset scope. Custom auxiliary plans remain
unsupported. The bridge reads the actual pending semantic descriptors in one
bounded batch and verifies their original typed local rectangles. It rejects
nested scopes or inexact offset rebasing; clipped AABBs are never inverted.
Body and controls have the same forward/inverse matrices and complete Frame
stamp, but separate visible polygons, so a toolbar outside the body works.
One native publication replaces both text sources and the auxiliary plan under
one lock, then the sole lease accepts that exact front. A successful missing
auxiliary record removes only the controls; a missing body removes both.

Each affine queued auxiliary slot captures the native publication serial.
Changing Space in the same Diff epoch rejects the old action. Owner dispatch
also verifies the full lease stamp and generation before and after validation.
Focus resolves a full key in the accepted native plan, including its actual
Frame ID; a prepared bank cannot steal focus from a failed front. Pointer and
native focus handoffs recheck authorization before and after native focus.
`setContextPresented` carries its entering coordinate generation through the
same final guard used by all four paired projection branches.

This adds no second text, selection, undo or focus store. Once a View has opted in, withdrawing or
closing its binding keeps body input denied until an explicit new binding and
accepted front authorize it; it cannot silently return to identity coordinates.
`clearCommittedSpace` withdraws authority before unbinding both clients.
`close` closes native ownership first and then the coordinate binding. If a
callback keeps unbinding pending, retain the Bridge and retry close at a safe
point; business methods are already Closed and retired native owners are never
closed twice. Context and View storage cover every such retry.

## Two source identities

By default the root contains `Original` and `Modified` complete-document children. Names
are configurable and copied by native construction. Each TextPattern range uses
its own Document's global UTF-16 offsets. Cross-source range comparisons fail.
There is no concatenated "unified document" whose offsets could be applied to B.

In split mode both sources remain selectable and focusable. In unified mode A
is read-only, unselectable and unfocusable. Only actual A-only deleted paragraphs
get A geometry; common A paragraphs remain available as full logical text but
have no visible rectangles. B alone owns editable input. During composition the
comparison projection is suspended; hidden A has no geometry and composing
overlay bytes are not substituted into the committed-text mirror.

Cells and caret stops come from the same Adapter Prepared data as drawing.
`RangeFromPoint` on a deleted row returns a true degenerate A range; it cannot
change or invent a B offset. Empty documents and terminal line feeds retain the
document bridge's genuine caret/line behavior. Degenerate bounding rectangles
remain an empty array.

## Publication and actions

`copyPresentation` copies source rows into caller storage only after checking
capacity, current revisions, projection and comparison identity. Its non-wrapping
epoch is independent of statistics. Epoch exhaustion rejects preparation before
changing the prior presentation.

The companion prepares both native geometry candidates, then records their epoch
in the Frame. Only the Context's successful-front hook publishes both sources
and the action epoch under the same native lock. Failed Frames keep the old
front and native geometry. An incomplete successful Frame withdraws geometry
and action authorization. Text changes independently make old text ranges
unavailable; old rectangles are never paired with new text.

Native owner actions are bounded accepted posts. The native queue captures the
successful presentation epoch, checks it again when taking the action, and the
owner checks the coordinator, both source revisions, window, disabled/modal and
composition state before acting. Default standalone document bridges retain
epoch-zero behavior; this companion explicitly enables presentation epochs.

Focus, Select/AddToSelection/RemoveFromSelection and ScrollIntoView route through
the coordinator. Unified A cannot acquire an input client. Either Document's
composition blocks pair actions. Selection expansion can prepare derived folds
before the sole Document mutation; that presentation step can independently
fail without changing selection. The final Document commit guard rechecks the
window/peer after candidate allocations. `selectPresented` returns a
`SelectionOutcome`: `changed` reports selection commitment and an optional
`presentation_error` reports later layout failure. A committed mutation must not
be retried. Scroll alignment uses the shared source paragraph row.

`Options.changed` is an owner-thread notification during an accepted action.
Its context remains stable through callback return. Queue explicit host work to
prepare the companion again; calling its `prepare` or `close` synchronously from
that callback returns `Busy`. `needsPrepare` exposes that responsibility. No
timer, hidden subscription or worker rebuilds the presentation. A queued UIA
method returning `S_OK` means accepted work; later failures go to diagnostics.
A hidden native window can reject system focus even after coordinator binding.

## Explicit controls under the same root

`Options.accessibility.auxiliary` explicitly enables a bounded third subtree,
alongside the complete A/B documents. Its default is null: ordinary bridges do
not allocate auxiliary banks or providers. This slice requires two sources,
presentation epochs, identity geometry and UI accessibility enabled at build
time. It does not merge another Window provider or all Context widgets.

Outside paint, call `bridge.prepareAuxiliary(.{ .nodes = nodes })` after
`bridge.prepare`. A node supplies a nonzero Frame ID, parent Frame ID, UTF-8 name,
and complete `auxiliary.Key`: namespace, current comparison serial, item,
kind and variant. Every field participates in the native RuntimeId, preserving
all 64-bit components. Kinds are group, invoke and disclosure; these fix the
provider's interface set. A disclosure also supplies its current expanded state.
The first node is the explicit group root; all other parents precede children.
IDs and tuple keys are unique. The host owns their identity and business values.
The namespace identifies the owning control set and must not be recycled while
providers for that identity can remain alive.
Use a new Frame ID when its semantic identity changes; do not reuse a pointer
press identity for another comparison item.

Preparation is the only label/key/pattern authority. In the draw callback, draw
the real controls with `Frame.semantic` and `Frame.buttonWithOptions` under that
group, then call `bridge.recordAuxiliary(frame)`. For a disclosure, draw its
current visual state and record a group semantic node with the planned name.
Recording verifies the exact subtree, Frame IDs, roles, labels and parents;
extra/missing nodes or unsupported value/pattern state reject the frame. It
copies only numeric bounds, visibility, enabled and focus flags into preallocated
scratch. No Frame, Tree, name slice or drawing command is retained. This does not
infer a button from text or manufacture a business revert control.

The successful-front hook publishes A/B geometry, epoch, auxiliary plan and its
numeric geometry under one native lock. Failed frames retain the entire old
front. A successful frame without a matching auxiliary record withdraws that
subtree; it cannot place old action keys at new bounds. Updating a pending plan
does not expose it early. MTA navigation, hit testing and properties read only
native snapshots. Auxiliary nodes have the same fragment root, with no separate
HWND host provider and no fabricated document offsets. SetFocus is supported
only for an explicitly focusable plan node with `AuxiliaryHandler.focus`;
ordinary plans retain the not-supported default.

`AuxiliaryHandler.validate` and `call` run on the owner thread through the same
16 accepted-action slots as text actions. `call` receives a typed key and either
invoke or an explicit desired expanded boolean. The companion checks the
comparison, epoch, both source revisions/composition and Window state, in
addition to native queue/take checks. The handler context remains stable through
callback return; synchronous close or prepare returns Busy. An accepted UIA
method is not a promise that a later stale action will execute. The host remains
responsible for business mutations and explicit subsequent preparation.

## Typed comparison controls and focus

The optional caller-owned `controls.Controls` workspace derives real hunk
buttons and per-source context-header controls. Keep its address stable from
Bridge creation through close, and do not copy or reset it while bound. Its
namespace and monotonically consumed Frame IDs must not overlap other controls
in the same Context. IDs never wrap or become reusable after a failed candidate.

```zig
var controls = try accessibility.controls.Controls.init(0x44494646, 10000, .{});
const bridge = try accessibility.Bridge.create(allocator, window,
    .{ .split = split }, .{ .controls = &controls });
try bridge.attachContext(&context);
try bridge.prepare(.{ original_reader, modified_reader });
try bridge.prepareControls(.{
    .bounds = control_subtree_bounds,
    .hunks = &.{.{ .index = visible_hunk, .original_to_modified = .{
        .bounds = explicit_button_bounds, .name = "Use original",
    } }},
});
// draw: bridge.draw(frame, colors) records text and these actual controls.
// on_input: bridge.handleEvent(event, parameters) runs before direct Diff input.
// on_action: bridge.controlAction(id) returns null for an unrelated control.
```

Use that single input route rather than additionally forwarding an event to the
underlying View. The helper leaves pointer capture, release, Tab/Shift+Tab and
activation with Context.Input. Before a control can focus, the coordinator's
`blurPresented(epoch)` revokes its physical TextClient; before body input or UIA
body focus it clears Context control focus. A disabled control still occludes
the body. Composition prevents this handoff. Tab from the body enters controls;
subsequent navigation stays within the existing Context controls. This is not a
general cross-region focus manager.

Callers that integrate their own controls can use `Context.hitControl`,
`focusControl` and `blurControls`. `Window.hasTextClient` reports physical
ownership even while disabled or modal-blocked. `focusControl` rejects that
ownership, missing accepted IDs and disabled/stopping windows before and after
native focus; nested focus is Busy, and a reentrant blur cancels the outer
handoff. A failed handoff may leave no focus, but never restores an already
revoked client. Native focus denial is an error, not a claim of OS activation.
An unhandled command shortcut may still invoke its application action without
acquiring control focus; a range shortcut that would steal focus is rejected.

`controlAction` resolves only the successful native front's full key and epoch,
never the pending control bank. Pointer/keyboard and UIA Invoke/ExpandCollapse
use the same typed coordinator methods. `revertPresented` validates the peer,
comparison, composition and enabled/window state at Document's final commit
guard, after candidate allocations, and creates one undo entry. Unified mode
accepts only original-to-modified. `setContextPresented` uses the paired layout's
final prepared callback before either fold publishes. A committed text/fold
change followed by presentation failure is returned as `changed=true` with
`presentation_error`, rather than a retryable edit error.

Changes require explicit comparison/Reader/layout preparation afterwards.
The optional `changed` callback runs while the companion is Busy; post host
work instead of preparing synchronously there. Reentrant native focus loss only
marks preparation required; it does not reenter a live Document/pair transaction.

Limits default to 16 visible hunks and 16 visible context regions, with a hard
65-node workspace and two 4096-byte label banks. The host supplies toolbar/button
bounds; headers use the exact two prepared gutter rectangles, never a combined
hit region across the column gap. Whole fixed workspace size is deducted from
`Options.accessibility.bytes` and included in stats, alongside the existing
native/old/candidate ledger. Graph/ID checks remain bounded O(n²). No paint-time
allocation, shaping, comparison or extra document/focus store is introduced.
`Options.controls=null` creates no workspace; manual auxiliary plans remain
available in identity mode. Normal Bridge, native State and action-slot records
gain no persistent fields in this slice. Explicit auxiliary owners each gain
one nullable pointer (host and native); identity auxiliary configuration creates
no new allocation block. The affine configuration additionally allocates one
host common mapping and one native common mapping/authority/16-slot serial
record. On the measured 64-bit Zig host the common host record is 4536 bytes;
the compiled Windows x64 native record is 2400 bytes: one 2216-byte Mapping,
one 48-byte Publication, 128 bytes of serials, active flag and alignment. Native
State and its persistent action slots remain 2912 and 64 bytes respectively.
The explicit native Auxiliary owner is 32 bytes. Source mapping staging
also stores two scope Refs. These records and allocator headers are charged to
the existing byte limit. Native action/accepted output structs carry temporary
publication copies; those are not fields added to each persistent action slot.
Affine scratch lives in a separate non-inlined helper, so the identity recording
path does not reserve its 128-Rect batch or Mapping on the stack.

Limits are 1–128 nodes and 1–32768 UTF-8 label bytes (defaults 128/4096), subject
also to the Frame's 128-node total including its window root. Host scratch,
copied labels, immutable native plans/providers, current geometry and concurrent
old/candidate plans share the existing byte ledger. Preparation costs bounded
node/label copies; graph/identity checks and Frame subtree export are O(n²) for
at most 128 nodes. Drawing allocates no heap/native objects. MTA getters may
allocate their returned BSTR/SAFEARRAY as documented for ordinary providers.
Close first clears business ingress; deferred native cleanup explicitly removes
the published plan and releases its provider refs, breaking the State/plan
ownership cycle before final State release. Unpublished/replaced plans release
independently. External providers keep only closed native State; their QI set and
tuple RuntimeId remain fixed while methods return element unavailable.

## Verification

`zig build smoke-document-diff-accessibility -Daccessibility=true` exercises real
native COM providers from an MTA against split and unified sources: complete
Unicode text, distinct range identities, deleted-source point offsets, hidden
common text, coordinator selection/focus/scroll, old queued epochs, failed
Frames, composition, allocation failure and late close. It includes a final
allocator free that attempts to close the retained coordinator, and a Document
candidate allocator that closes the window before a queued multi-selection
can commit. The auxiliary slice additionally verifies real drawn button/group
nodes, MTA Invoke/ExpandCollapse, old epoch rejection, disabled state,
failed/missing records, allocation sweeps and queued App shutdown. Strict C/UBSan
provider tests cover single-root navigation, full-width RuntimeIds, partial
provider construction rollback, unpublished/replaced plans, unchanged QI after
removal, and final MTA Release with ledger zero. Ordinary document UIA tests remain separate regression coverage.
The controls fixture also runs split/unified first-click actions, both split
revert directions and single undo/redo, real queued Tab/Shift+Tab/Space, MTA
SetFocus and actual context nodes. Document allocator disable/close/quit rejects
text publication; Adapter candidate disable rejects both fold publications.
Failed frames, candidate OOM, stale comparison, disabled controls and composition
retain their stated transaction/ownership boundaries with final resources zero.
These checks do not establish visual quality or support for the pending areas
listed above.

`zig build smoke-affine-document-diff -Daccessibility=true` adds real Windows
UIA rectangle/point/caret queries from an MTA and split/unified native TextClient
input. Linux runs the shared-coordinate/GTK seam without claiming an AT-SPI
document provider. It checks failed/missing/overwritten records, workspace
replacement, peer/commit guards, composition, observer withdrawal and generation
exhaustion, presentation OOM, final-free rebind and callback-delayed close.
Teardown asserts native/text owners return to zero. These hidden checks do not
establish visual quality.

`zig build smoke-affine-diff-controls -Daccessibility=true` is the separate
Windows typed-control target. Its expected oracles cover explicit affine
matrices, outside-body toolbar bounds, precise parent clips and offset/scope
rejection, failed-front focus, OOM preparation, same-epoch queued actions,
allocation/free generation replacement, MTA Invoke/ExpandCollapse, pointer and
Tab/Space activation, and single undo. Compilation and Linux pure tests do not
establish that this Windows native target has passed.
