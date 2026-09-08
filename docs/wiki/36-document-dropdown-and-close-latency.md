# Phase 29C — Document dropdown and immediate tab interaction

Status: **Close-latency behavior retained; visible dropdown and tab scrollers superseded by Phase 33**

## Current chrome correction

[Phase 33](38-editor-groups-compare-and-native-tabs.md) removes the visible
`Documents (N)` control, its reserved trailing width, and both visible tab
scrollers. **Tabs → Open Document…** and `Command-Shift-O` still open the same
searchable panel, now anchored to the tab-strip surface. Tabs are connected,
multi-row 27-point strips; every title uses its complete intrinsic width and is
never truncated or ellipsized, even when a legacy maximum width is supplied.
A single row preserves natural widths and unused trailing space. Once complete
natural widths require multiple rows, contiguous rows are balanced where
full-title minima allow and every multiline row distributes its positive slack.
Widths are never reduced below the complete title minimum. There is no row cap
or internal tab viewport: all rows in the 56- and 500-tab layouts contribute
their full content height, clip origin stays zero, and wheel, activation,
resize, or programmatic reflection cannot re-enable scrolling. This supersedes
the earlier ragged-right interpretation.

The immediate-close transaction, stable-`TabID` routing, active-editor focus,
hover-only close affordance, and last-tab scratch behavior documented below
remain current. References below to a visible dropdown, reserved width, or
overlay tab scrollbars describe the historical Phase 29C UI only.

## Historical Phase 29C chrome outcome

The historical Phase 29C crowded-tab chrome presented one explicit `Documents (N)` dropdown
instead of an unlabeled icon/count and a separate plus button. The dropdown
keeps the existing searchable open-document panel, keyboard navigation, dirty
and pinned state, and stable TabID activation. New scratch documents remain
available through the native File menu and Command-N.

The historical tab scroller used overlay scrollbars with fixed autohide behavior, disabled
elastic overscroll, consistent right spacing, and an inset scroll thumb. Hover
tracking is active whenever the pointer is over a tab, including inactive
windows, and now exposes a stronger accent background/border plus a 20-point
close target without moving the title.

## Immediate close transaction

A clean or explicitly discarded tab previously stayed visible until both the
ordered session write and close-recovery write completed. The workspace now
publishes a provisional removal first while retaining the editor buffer. The
tab strip applies that event with one `NSCollectionView.deleteItems` operation;
it does not rebuild every visible tab. Only the matching durable event retires
the editor buffer and makes the entry eligible for Restore Closed Tab.

The provisional session is also the command-routing authority, so Save, Close,
and other actions never target a hidden tab that differs from the one on screen.
Any older recovery debounce is cancelled synchronously, and new recovery
autosaves ignore the pending event. If either write fails, a reset event restores
the original session with the exact actionable retry token. Workspace transaction
serialization remains held until the commit or rollback finishes.

Removal events now use a collection-view structural delete instead of
`reloadData()`. Active-tab and edited-tab changes retain the existing bounded
item reload path. A valid `tabInserted(index:)` snapshot delta now updates the
data-source/width caches and calls `NSCollectionView.insertItems` exactly once;
an invalid index, count, or stable-ID order safely uses the authoritative full
snapshot. Reorder retains its conservative reconciliation path.

In editor-group mode, a valid insertion is translated from workspace position
to the receiving group's local index and only that strip changes. The other
strip is not reloaded or updated. Redisplaying the same buffer in the same
Scintilla host is idempotent, so the already attached native view and editor
focus remain stable while the new tab is reflected.

The current retained-item hover path resolves stable `TabID` through a
structural-change-time index map. Deleting an earlier tab therefore cannot
leave a reused item pointing at its creation-time index. At 500 tabs,
incremental configuration remains bounded: single update 1, persistence 0,
hover enter/exit 1 each, and active old/new 2.

## Focus and last-tab behavior

Successful new-document creation, tab activation, and close completion return
focus to the active editor. Closing the final tab still creates one empty
scratch document. This matches the immediate-editing Notepad++ model; an empty
`Create New Note` landing page is intentionally not introduced.

## Acceptance

- Historical Phase 29C acceptance exposed `Documents (64)` and contained no
  plus/add button; Phase 33 supersedes that visible control entirely.
- Hover tracking is `activeAlways`, changes the local visual affordance, and
  exposes the close target without reloading other items.
- A blocked durable close removes the tab from the visible workspace snapshot
  before the store is released, but does not retire its editor buffer early.
- A failed close restores the original tab and publishes one retryable failure.
- Pending and committed close events leave the collection at the exact count
  without a full reload or stale-layout warning.
- A valid insertion performs one native collection insertion; malformed deltas
  use the full-snapshot fallback. Split mode updates only the receiving group's
  local index.
- Command-N creates and activates a scratch tab and makes its editor the first
  responder; same-buffer/same-host redisplay does not detach that view or move
  focus.

The historical Phase 29C release validation passed the complete 119-test
Application target and the 52-test serialized AppKit-hosted suite. Its packaged
native performance gate also passed: warm ready 417.279 ms, typing p95
0.015958 ms, 100 MiB open
1011.250083 ms, 200-tab reflow p95 0.001917 ms, and folder search 282.666292
ms. The 64-tab structural close probe was separately bounded below 250 ms.
Those numbers remain a historical performance baseline. The current
multiline/insertion follow-up separately passes TabFlow 93/93, insertion 5/5,
editor-group commands 29/29, Scintilla groups 24/24, Language editor 56/56,
and the complete monolithic serial run at 653/653 tests in 12 suites. Debug and
Release builds pass. A fresh Universal bundle from remote-verified `ca97721`
passes hidden Finder/Open With, security-scope relaunch/save, extension/XPC,
and 50-tab multiline smoke with six rows.

## Boundaries

The hidden Workspace browser remains hidden. No README is created. The ignored
Notepad++ checkout and the user's unrelated foundation-document/vendor-script
changes remain outside this phase.
