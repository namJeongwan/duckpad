# Phase 33 — Editor groups, open-document Compare, and native tab chrome

Status: **Complete — reviewed source is audited, pushed, and smoke-validated**

## Outcome

Duckpad now supports a lightweight, two-group editing workflow. Dragging a tab
to the editor's right or bottom edge creates a second editor group. Each group
has its own selected tab and Scintilla host, so two different open documents can
remain visible and editable at once. A normal drag moves the tab reference;
Option-drag copies the reference into the other group without copying the
document, revision, dirty state, save target, or recovery journal.

Any open document can also be compared with another through **View → Compare
with Open Document…** or a tab's context menu. Compare captures immutable text
and revision snapshots without activating the chosen document, aligns the two
inputs in a read-only native panel, and restores focus to the initiating editor
group after the panel is dismissed.

The window keeps the standard macOS application menu and adds one slim command
bar above the entire editor-group workspace. Its File, Edit, Search, View,
Format, Language, Tabs, Extensions, and Window entries remain typed
`NSPopUpButton` controls backed by the exact original `NSMenu` objects. Their
manual presentation path anchors each menu's content top immediately below the
command bar. Menu identity/tree, supermenu attachment, targets, selectors,
shortcuts, hidden and checked state, and AppKit validation therefore continue
to have one authority.

## Editor groups and tab movement

`EditorGroupLayoutModel` owns only window-local presentation state:

- primary and optional secondary group membership in canonical workspace order;
- one selected tab per group and one focused group; and
- a side-by-side or stacked group orientation.

The model fully reconciles structural and reset workspace publications. Stable
tab metadata, buffer edits, persistence, and cache-valid active selection use
bounded incremental paths; invalid cache state falls back to the full
reconcile. New documents enter the focused group, closed documents disappear
from both groups, duplicate membership inside one group is rejected, and an
empty group collapses into one normalized primary group. Closing the secondary
group moves its unique tab references back to primary; it does not close
documents or prompt for unsaved changes.

`ScintillaEditorAdapter` remains Duckpad's single application-facing editor
port and revision publisher. Its group router selects one stable native host per
visible group, assigns the chosen buffer, and forwards native focus to the
window controller. Distinct documents use distinct Scintilla views. A cloned
tab shares the same native Scintilla document and Undo history while retaining
independent caret, selection, wrap, zoom, and scroll state. Accepted edits still
cross the workspace revision boundary exactly once.

The versioned local drag payload carries the stable tab ID and source group.
Drops within one strip reorder tabs. Cross-group drops move or Option-copy the
reference. When only one group is visible, the right and bottom editor edges
expose accessible Split targets; invalid, duplicate-copy, third-group, and
last-unique-source operations make no state change. The same rules validate the
View menu and tab-context alternatives for Move/Clone Right or Down, Focus
Other Editor Group, and Close Editor Group.

Group placement is deliberately not added to the recovery schema. A relaunch
restores documents and existing per-document editor state, then starts with one
group. Window teardown cancels pending activation and removes group, focus,
drag, and editor callbacks.

## Two different kinds of split

Editor groups do not replace [Phase 19 shared-document split
editing](22-split-editing.md):

| Workflow | What is visible | Ownership and Undo | Persistence |
| --- | --- | --- | --- |
| Editor group | Usually a different open document in each group; an Option-drag clone is also allowed | One routed Scintilla host per group; each document retains one buffer/revision, and a clone shares its native document and Undo history | Group placement is window-local and starts unsplit after relaunch |
| Split Editor Right/Down | The same active document in two panes inside its focused editor | Two Scintilla views share one native document and one Undo history | Existing per-buffer split orientation and secondary view state remain recoverable |

To prevent an ambiguous four-pane layout, entering group mode temporarily
suspends the existing internal editor split without deleting its recovery
metadata. Internal Split commands are disabled while two groups are open. When
the editor group closes, the focused buffer's suspended internal split is
restored.

## Open-document Compare

The picker excludes the source document. Duplicate titles are disambiguated
with paths, and the command is disabled when no second open document exists.
`OpenDocumentComparisonUseCase` captures both exact buffer snapshots through
the existing editor port without activation, display, focus, or mutation. It
then rechecks the captured revisions before presentation.

Each captured side has these independent input limits:

- 32 MiB of UTF-8 text;
- 50,000 logical lines, with CRLF counted once and standalone CR or LF counted
  once.

The comparison as a whole is bounded to 2,000,000 Myers
shortest-edit-path steps and 100,000 aligned output rows.

The aligner trims common prefixes and suffixes and retains compact source line
ranges. If the Myers work ceiling is reached, the unmatched middle becomes a
bounded replacement block; if the row limit cannot hold even that fallback,
Compare fails with a typed complexity error. Large work runs in a cancellable
utility-priority task. Closing or changing either document, starting a newer
Compare, dismissing its UI, or tearing down the window cancels or suppresses a
stale result.

The panel renders one flat attributed string per side and batches contiguous
changed ranges. Both panes are selectable but read-only, use the same
fixed-pitch font and fixed visual row height, and disable wrapping. Blank rows
preserve alignment. Textual `+`, `-`, and `~` markers supplement semantic
insert/delete/replace colors so the result is not color-only. Vertical scroll
positions mirror by normalized progress with exact end clamping after resize;
horizontal scrolling stays independent.

External-file-conflict Compare now uses this same aligner and panel instead of
its former positional line renderer. Its original conflict loop remains
unchanged: comparison does not save, reload, overwrite, clear dirty state, or
consume the unresolved conflict.

## Native command and tab chrome

The visible `Documents (N)` control and its reserved trailing width are gone.
Open-document navigation remains available through **Tabs → Open Document…**
and `Command-Shift-O`; it presents the same searchable, keyboard-first panel,
anchored to the tab-strip surface. Search, stable-ID activation, incremental updates,
dirty/pinned metadata, and termination admission remain intact.

Tabs are compact, connected 27-point strips rather than separated rounded
cards. The active tab visually joins the editor and uses the system accent
underline; inactive and hovered states use semantic AppKit colors. Dirty and
pin state remain visible and accessible, while the close affordance appears
only for the active or hovered tab. At 500 tabs, incremental configuration is
bounded to the known affected items: single update 1, persistence 0, hover
enter/exit 1 each, and active old/new 2. A stable `TabID`→current-index map keeps
a retained item's hover/close behavior correct after an earlier deletion.

Tab titles are never truncated, abbreviated, ellipsized, or shrunk by a legacy
maximum width. Each item measures the complete filename at its intrinsic width,
and wrapping occurs only between whole tab items when the next item no longer
fits. Remaining row width is intentionally left available instead of being
distributed across the row. Title-side whitespace is halved while fixed
pin/dirty/close hit targets remain stable.

There is no tab row cap or internal viewport. All rows contribute their full
content height, including 56- and 500-tab layouts. Horizontal and vertical
scrollers remain disabled, and wheel input, activation, resize, or programmatic
clip movement leaves the clip origin at zero. AppKit-owned scrollers remain
attached for lifecycle safety but are noninteractive, visually suppressed, and
hidden from accessibility. **Open Document…** remains a
keyboard-first navigation option, not a workaround for clipped tab rows.
Editor and Compare content scrolling are unaffected by this tab-chrome rule.

The command bar uses a focused `NSPopUpButton` subclass to retain the public
control contract while replacing only AppKit's automatic first-row alignment.
Mouse, keyboard, accessibility press, and `AXShowMenu` all call native
`NSMenu.popUp(positioning:at:in:)` with no positioning item and a point one
point below the bar, so the menu starts below the trigger instead of aligning
its first row over the bar. AppKit popup tracking and per-control tracking areas
provide distinct open/hover feedback in both Aqua and Dark Aqua. Teardown or
menu reapply restores the original root-item/supermenu attachment and every
menu item's visibility.

Drag reorder, edge Split, cross-group move/copy, Compare, context menus,
middle-click close, keyboard navigation, bounded incremental updates,
VoiceOver labels/actions, and live appearance updates all remain available.
No dependency, parser, language server, background indexer, or IDE-scale
service was added.

## Pinned Notepad++ parity evidence

The ignored local Notepad++ tree is pinned at
`dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248` and was read only:

- `notepad-plus-plus/PowerEditor/src/ScintillaComponent/DocTabView.cpp:72-96`
  inserts the complete compact filename into each native tab item.
- `notepad-plus-plus/PowerEditor/src/ScintillaComponent/DocTabView.cpp:196-238`
  updates the complete label and escapes ampersands so native measurement
  retains the literal filename.
- `notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp:260-310`
  enables multiline tabs without opting into fixed-width/right-justified tab
  styles, preserving content-measured widths until another row is needed.
- `notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp:700-805`
  separates single-line wheel scrolling from multiline behavior and explicitly
  avoids scrolling the multiline tab mode.
- `notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp:1420-1815`
  draws selected/inactive/hover, close, pin, and full single-line label states
  without an ellipsis drawing flag.

Duckpad translates those workflow semantics into Swift/AppKit: inviolable
intrinsic full-title widths, item-boundary multi-row wrapping only on overflow,
ordinary trailing room, pinned zero-origin/no-scroll behavior, connected semantic
colors, system accent, native `NSMenu` dropdowns, and accessibility. It does not
copy Win32 owner-drawing or the legacy Windows visual style. The ignored
reference tree was not modified or included in any feature commit.

## Validation and delivery state

Task 6 focused validation passed 21/21 Compare tests, 38/38 file-command tests,
19/19 editor-group command tests, and 75/75 tab-flow tests. Task 7's combined
command-bar, tab, controller, drag, Split, Compare, accessibility, performance,
and teardown gate passed 130 related tests.

Real packaged UI inspection then exposed synchronous focus recursion on **View
→ Move Active Tab to Group Right**: programmatic focus synchronously published
the already-focused group and re-entered render/focus until stack exhaustion.
Task 9 commit `9ecdd588` rejects that no-state-change callback at the controller
transition boundary. Its deterministic synchronous-focus regression and full
`EditorGroupCommandTests` pass 21/21; Compare 21/21, AppKit-hosted 72/72,
workspace 16/16, Scintilla group 23/23, Debug/Release builds, and independent
review at 0 Critical / 0 Important / 0 Minor also pass.

Task 10 commit `cfb6329` verifies the final Notepad++-faithful chrome: layout
7/7, command bar 5/5, AppKit-hosted 77/77, workspace 16/16, Compare 21/21, and
Scintilla group 23/23 pass. Cumulative review then found a native-move source
editor routing hole and O(n) group reconciliation/full reload during ordinary
500-tab activation. Commit `c0a0083` restores the surviving source selection
after reparenting and uses validated group/workspace index caches for normal
edit, activation, direct click, and cloned-tab focus paths. Only the affected
group's old/current items, display route, border, and accessibility focus state
change; an invalid cache retains the authoritative full-render fallback.

The final focused gates pass editor-group commands 27/27, TabFlow/AppKit 85/85,
layout model 15/15, workspace 16/16, Compare 21/21, and Scintilla groups 23/23.

The 2026-09-08 popup-anchor follow-up fixes a screenshot-confirmed regression
where `NSPopUpButton` aligned Language's first `Auto` row over the command bar
despite its preferred-edge hint. The explicit native-menu call now anchors the
menu content directly below the bar. A headless `NSMenu` presentation spy
captures the nil positioning item, exact anchor point, and command-bar view.
Typed popup, native Space-key, and `AXShowMenu` paths share that presentation
route, while disabled controls cannot dispatch it. The command-bar suite passes
9/9 and the full serial suite exits 0.
The full serial suite (`swift test --no-parallel`) exits 0 across 640 discovered
tests, and Debug and Release builds pass. Independent review reports 0 Critical
/ 0 Important / 0 Minor.

On 2026-09-07 the user explicitly selected a non-interactive packaged smoke as
the final gate instead of a locked-screen manual UI rerun. A fresh native
`.app` built from the reviewed current source passes bundle/resource/XPC/signature
verification and the complete Finder/Open With, two-launch security-scoped
bookmark recovery/save, extension, and XPC-isolation smoke. The first attempt
had targeted a stale 2026-09-03 bundle that did not contain the current
security-scope smoke entry point; rebuilding from current source removed that
validation-artifact mismatch. It was not a product-code failure.

No pixel-by-pixel visual inspection is claimed. Drag reorder, right/down Split,
cross-group move/Option-copy, group focus/close, and Compare are closed by their
focused AppKit, command, drag, and Compare suites together with the successful
current-source packaged smoke, which is the user-approved completion boundary.

The default parallel whole-suite run still receives AppKit `signal 11`. That
same process-global instability is an established baseline; it is not recorded
as a pass and does not replace the successful serial suite.

Implementation commits through `c0a0083` and the existing documentation at
`c517cc8` have independent 0/0/0 reviews and local commit audits. A final
cumulative pre-push review also reports 0/0/0, and that source/history is
remote-verified on `origin/feature/editor-groups-compare`. The fresh package and
smoke above ran afterward from that exact source. This paragraph does not claim
that the current three-document closeout has already been reviewed, audited, or
pushed.

## 2026-09-08 intrinsic-width and Language-menu follow-up

The earlier Task 10 wording that described exact row-wide justification was an
incorrect interpretation of the target behavior. The current layout keeps each
tab at its full measured filename width and wraps only when the next complete
item would exceed the row. Four short tabs therefore occupy only their required
width; they do not stretch to 100%. Surrounding title whitespace is reduced by
half without shrinking the pin, dirty, or close affordance slots.

The window Language control and status Language control now share one compact
native builder. Auto and Plain Text stay direct, repeated initials use alphabet
submenus, singleton initials stay direct, and the root remains bounded while all
78 definitions retain exactly one action leaf. This is an `NSMenu` hierarchy,
not a custom popup, parser, indexer, or new dependency.

RED tests captured the previous equal-width stretching and flat 78-item menu.
The focused intrinsic/wrap, compact-padding, no-scroller-chrome, and menu
identity/cardinality tests now pass. Nonvisible AppKit integration additionally
passes the native right/down drag-Split suite 16/16, Compare command suite
10/10, and Compare panel suite 10/10. A packaged screen check confirmed direct
intrinsic-width tabs, overflow-only row creation, no tab scroller chrome, the
bounded Language hierarchy, and exactly one selected tab; all disposable test
apps and their isolated data were removed from the workspace afterward.
