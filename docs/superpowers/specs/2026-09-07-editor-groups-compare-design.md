# Editor Groups and Open-Document Compare Design

Status: **Approved by the user on 2026-09-07; implementation planned**

## Goal

Make Duckpad's split workflow useful for real editing: an open tab can be
dragged to the right or bottom edge to create a second editor group, each
group keeps its own visible tab and editor view, and any two open documents
can be compared in a read-only, line-aligned view with synchronized scrolling.

The result remains a lightweight two-group editor. It does not grow into an
IDE workspace model, source-control client, merge tool, or extension host.

## Product boundary

This phase supports at most two editor groups in one window. A group split is
either side by side or stacked. Normal drag moves a tab; Option-drag clones a
reference to the same document into the destination group. A tab may therefore
appear once in each group, but there is still only one document, buffer,
revision, dirty flag, save target, and recovery journal.

The existing View > Split Editor Right/Down commands continue to create
Scintilla's same-document shared-undo split inside the focused editor. Group
creation is a separate tab-drag action, so existing shortcuts and recovery
archives retain their meaning. Entering group mode temporarily suspends any
internal split, including split state recovered later for an inactive or
recently restored buffer, without deleting its stored orientation or secondary
view state. Leaving group mode restores the focused buffer's suspended split.
Internal split commands remain disabled while two groups are open, preventing
ambiguous four-pane UI without losing recovery metadata.

Group layout is window UI state in this phase. It is reconciled against the
durable session but is not written into `ScratchSession`: reopening restores
all documents and every existing per-buffer editor recovery state, then starts
with one group. This preserves backward and forward recovery compatibility
without changing the durable session schema. Persisting group placement is a
separate feature, not hidden inside document recovery.

Compare takes immutable snapshots of two currently open buffers. It is
read-only and does not change either document, selection, revision, dirty
state, Undo, recovery state, or group layout. Editing, applying hunks,
three-way merge, SCM integration, directory compare, intra-line token diff,
and persistent compare sessions are outside this phase.

No dependency is added. Duckpad uses its existing Scintilla editor, AppKit,
and a bounded in-process line diff.

## Chosen architecture

### One routed Scintilla adapter

Extend the existing `ScintillaEditorAdapter` to own group routing alongside its
current buffer store. It remains the one application editor dependency, the one
edit publisher, and the one recovery journal owner. Existing file, search,
language, extension, intelligence, command, and recovery use cases therefore
retain their current dependency and never learn about AppKit group views.

The adapter's stable primary root continues to host its current internal split
when only one group exists. It also exposes one stable secondary group host for
composition. In group mode the adapter reparents its existing primary and
secondary editor hosts into the two group panes and suppresses internal-split
restoration. On group close it returns the primary host to the original root
and restores the focused buffer's preserved internal-split state.

`EditorGroupRoutingPort` is view-free: it contains only group identifiers,
buffer assignment, focus, and split-suspension behavior. The concrete
`ScintillaEditorAdapter` separately exposes its AppKit primary root and
secondary group host. `DuckpadApp`, which already imports both adapter and
Presentation targets, injects those two `NSView` values into
`DuckpadWindowController`. No AppKit type crosses into DuckpadApplication.

For different documents, each group displays the buffer's existing native
Scintilla view. For an Option-drag clone, the destination view calls the
existing `shareDocument(with:)` bridge operation, so both views use the same
native Scintilla document and Undo history. The views retain independent caret,
selection, wrapping, zoom, and scroll state. An edit or Undo/Redo from either
view enters the adapter's single `onEdit` acceptance path exactly once; after
acceptance the adapter synchronizes only the peer view's revision metadata.
It never reloads an accepted edit through `install`, never empties the peer's
Undo buffer, and appends only one recovery delta.

Group-only peer state is transient and is never encoded as
`secondaryViewState`. The adapter records one canonical owning group for each
buffer; cloning retains the source as owner, while a real move transfers
ownership. During group mode, recovery capture refreshes anchor, caret, scroll,
wrap, display, bookmark, fold, and zoom state from that owner's current native
view. It separately preserves only a legitimate suspended internal
`splitOrientation` and its `secondaryViewState`, never substituting the clone
peer's caret or scroll state. A buffer first installed while group mode is
active gets an unsplit canonical state from its owning view. Startup recovery
and recently-closed restoration that install an internal-split state during
group mode preserve its orientation/secondary fields without rendering it.
Autosave, termination recovery, and group close therefore retain current owner
view changes, cannot mis-encode a group clone as an internal split, and cannot
erase a previously suspended split. Leaving group mode restores the refreshed
canonical primary state plus any preserved internal secondary state.

Shared routing identifiers (`EditorGroupID` and orientation) live in
`DuckpadApplication`, which both Presentation and `DuckpadEditorAdapter` may
import. The adapter conforms to a narrow `EditorGroupRoutingPort` with group
activation, buffer assignment, reversible internal-split suspension, and one
focus callback. Presentation-only membership snapshots,
drop operations, and pasteboard payloads stay in DuckpadPresentation.

### Window-local group layout

Create one focused `EditorGroupLayoutModel` in Presentation. It owns:

- primary and optional secondary membership, each ordered by the canonical
  workspace tab order;
- one selected tab per group;
- the focused group; and
- the right/down split orientation.

The model consumes `WorkspaceSnapshot` values and never owns document data.
On startup every tab belongs to primary. New tabs enter the focused group.
Closed tabs disappear from both groups. If a group becomes empty it collapses;
remaining tabs normalize into primary. A normal edge drop is rejected when it
would leave the source group empty. Option-drag is therefore the one-tab path
to a useful split.

When a tab is already cloned into the destination, another Option-drop is
rejected as a no-op. A normal move removes only the source reference, leaving
the destination's existing reference. If that empties a group, the layout
collapses and normalizes the remaining destination into primary. Membership is
always unique within each group.

Global `ScratchSession.activeTabID` continues to identify the command/save
target. The group model separately marks each group's selected tab for visual
selection. Focusing an editor or selecting a tab updates the focused group,
then activates that group's selected tab through the existing workspace use
case. Every `WorkspaceChange` reconciles routing before
`EditorBindingUseCase.render`: if the active tab belongs to exactly one group,
that group becomes focused; if it is cloned into both, the current focused
group wins; if it is newly opened and belongs to neither, it is inserted into
the current focused group. This same rule covers the document switcher,
search-result navigation, file open, Save All traversal, close/save replacement,
and recovery-driven activation. Commands, title, language, symbols, and
extensions therefore retain one source of truth even for programmatic changes.

### Group view and drag contract

Create an `EditorGroupWorkspaceView` that owns the two-pane `NSSplitView`, one
`MultilineTabStripView` per visible group, and the corresponding editor host.
The current primary tab strip remains the primary strip; a secondary strip is
created only while split. Each pane is a small vertical stack: its tabs above
its editor. The workspace sidebar remains outside this split.

The tab pasteboard payload becomes a versioned local value containing the tab
ID and source group. Collection drops still reorder within a strip. While a
tab drag enters an unsplit editor area, right and bottom edge zones appear.
Dropping on a zone requests move or clone according to the drag operation;
Option advertises `.copy`, otherwise `.move`. The overlay uses the macOS
accent color, a quiet translucent fill, and a clear divider preview. It adds
no cards, gradients, or persistent chrome.

Keyboard/VoiceOver alternatives live in the tab context menu and native View
menu: Move/Clone Active Tab to Group Right/Down, Focus Other Group, and Close
Editor Group. Commands validate against the same layout rules as drag/drop.
Drop zones and group tab collections have explicit accessibility labels.

### Open-document compare

Create an application-level `OpenDocumentComparisonUseCase`. It enumerates
eligible open tabs, captures the active/left and selected/right buffer through
`EditorPort`, verifies that each immutable UTF-8 snapshot is at most the
existing 32 MiB comparison limit, and returns a neutral
`OpenDocumentComparison` value. It rejects the same tab, missing/stale
snapshots, or an oversized input without mutating workspace state.

Presentation provides `Compare with Open Document…` in the View menu and tab
context menu. A native picker excludes the source tab and shows titles plus
paths where needed. With fewer than two open tabs the command is disabled.

The comparison panel contains two equal read-only monospaced panes. A bounded
line aligner produces equal-length rows classified as unchanged, inserted,
deleted, or replaced. Blank placeholders preserve alignment. Changed rows
use semantic system colors and textual `+`, `-`, or `~` markers, so meaning is
not color-only. Line numbers always refer to the corresponding source.

The capture boundary allows at most 32 MiB and 50,000 logical lines per side.
The aligner trims a common prefix/suffix, then uses Myers' shortest-edit-path
algorithm for the remaining lines with a two-million-step work ceiling and a
100,000 aligned-row ceiling. It stores compact source line ranges and row kinds,
not copied attributed strings per row. If either ceiling is reached, the
unmatched middle becomes one replaced block; if even that cannot fit the row
budget, capture fails with a typed complexity error. The renderer builds one
flat attributed string per side and applies attributes to contiguous changed
ranges, bounded by the accepted input and row limits. Construction above a
small synchronous threshold runs in a cancellable utility task, and a stale
result cannot present after either tab closes or changes revision.

Both text views use the same fixed-pitch font, disable wrapping, and preserve
one fixed-height visual row per aligned row. Their scroll views observe bounds
changes and mirror the normalized vertical position under a reentrancy guard,
including exact top and bottom clamping after resize. Horizontal scrolling
stays independent. Closing the sheet cancels pending work and discards all
compare state.

The existing external-file-conflict Compare is moved onto the same aligned
panel model, preserving its conflict loop while replacing positional line
highlighting with the shared renderer and synchronized scrolling.

## Data flow

### Drag to split

1. A tab drag publishes its tab ID and source group.
2. `EditorGroupWorkspaceView` validates the right/bottom edge and move/copy
   operation with `EditorGroupLayoutModel`.
3. The controller captures the current source snapshot, mutates only the
   window-local layout, tells `ScintillaEditorAdapter` the new ownership,
   and activates the destination group/tab.
4. The existing workspace change renders through the routing adapter into the
   destination child while the source child remains visible.
5. Subsequent focus changes reactivate that group's selection before commands
   run. Edits continue through the existing single workspace edit callback.

### Compare

1. The controller identifies the active source tab and asks the presenter for
   one other open tab.
2. `OpenDocumentComparisonUseCase` captures and validates both exact buffer
   revisions without activating either tab.
3. The line aligner builds bounded, equal-row presentation data off the main
   actor when the input is nontrivial.
4. The native sheet presents read-only panes and synchronized vertical scroll.
5. Dismissal returns focus to the previously focused editor group.

## Failure and lifecycle behavior

- Unknown, closed, duplicated-source, or stale compare selections fail with a
  typed error and use the existing non-destructive failure presentation.
- The 32 MiB and 50,000-line limits apply independently to both compare sides;
  aligned output is capped at 100,000 rows and two million diff steps.
- A failed drag validation changes neither tab order nor group layout.
- Re-copying an existing destination reference is rejected; moving that same
  cloned reference removes the source and applies normal empty-group collapse.
- Closing a cloned tab removes that logical tab from the session and therefore
  both visual groups, matching Duckpad's current one-tab/one-document contract.
- Closing the secondary group moves its unique tabs back to primary; it never
  closes documents or prompts for unsaved changes.
- Window teardown clears focus/edit callbacks and invalidates both Scintilla
  children exactly once.
- Older recovery archives decode unchanged. New work writes the same session
  and editor-recovery schema as before.

## Verification

Implementation follows red-green-refactor. Automated coverage must prove:

- layout move/clone, one-tab rejection, independent selections, focus routing,
  close normalization, insertion/removal reconciliation, and orientation;
- versioned pasteboard parsing, Option-copy vs move, edge-zone validation,
  within-group reorder, cross-group drop, duplicate-copy rejection,
  cloned-reference move/removal and empty-group collapse, and accessibility;
- routed editor install/display/snapshot/retire/input/focus behavior, one native
  shared document and Undo history for clones, edit/Undo/Redo from both clone
  views, no duplicate workspace edit or recovery delta, correct command port
  routing, save/recovery after alternating edits, and callback cleanup;
- reversible internal-split suspension for the current buffer, inactive
  recovered buffers, startup recovery, and recently-closed restoration;
- autosave and termination recovery during a group-only clone never encode its
  transient peer as `secondaryViewState`, while a suspended legitimate internal
  split round-trips exactly and current canonical-owner caret/scroll/bookmark/
  fold/display changes made in group mode remain recoverable;
- existing Scintilla internal split and recovery tests remain unchanged;
- compare candidate filtering, exact-revision capture, same-tab/stale/size/line
  and complexity failures, line alignment including empty files and trailing
  newlines, newline-dense/pathological inputs, cancellation and stale-result
  suppression, bounded fallback, semantic markers, no wrapping, long unequal
  lines, resize/top/bottom clamping, and synchronized vertical scrolling;
- native menu/context actions, command validation, focus restoration, and
  external-conflict Compare reuse;
- workspace, file, search, language, extension, recovery, presentation, and
  editor adapter regression suites; production build and relevant smoke paths;
  and
- final `git diff --check` plus an independent whole-branch review with zero
  Critical, Important, or Minor findings before push.
