# Phase 29C — Document dropdown and immediate tab interaction

Status: **Implemented; independent review pending**

## Outcome

The crowded-tab chrome now presents one explicit `Documents (N)` dropdown
instead of an unlabeled icon/count and a separate plus button. The dropdown
keeps the existing searchable open-document panel, keyboard navigation, dirty
and pinned state, and stable TabID activation. New scratch documents remain
available through the native File menu and Command-N.

The tab scroller uses overlay scrollbars with fixed autohide behavior, disabled
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
item reload path. Insert and reorder keep the conservative full reconciliation
path because AppKit cannot safely animate those transitions while a concurrent
Restore Closed Tab operation changes editor ownership.

## Focus and last-tab behavior

Successful new-document creation, tab activation, and close completion return
focus to the active editor. Closing the final tab still creates one empty
scratch document. This matches the immediate-editing Notepad++ model; an empty
`Create New Note` landing page is intentionally not introduced.

## Acceptance

- 64-tab chrome exposes `Documents (64)` and contains no plus/add button.
- Hover tracking is `activeAlways`, changes the local visual affordance, and
  exposes the close target without reloading other items.
- A blocked durable close removes the tab from the visible workspace snapshot
  before the store is released, but does not retire its editor buffer early.
- A failed close restores the original tab and publishes one retryable failure.
- Pending and committed close events leave the collection at the exact count
  without a full reload or stale-layout warning.
- Command-N creates and activates a scratch tab and makes its editor the first
  responder.

Release validation passes the complete 119-test Application target and the
52-test serialized AppKit-hosted suite. The packaged native performance gate
also passes: warm ready 417.279 ms, typing p95 0.015958 ms, 100 MiB open
1011.250083 ms, 200-tab reflow p95 0.001917 ms, and folder search 282.666292
ms. The 64-tab structural close probe is separately bounded below 250 ms.

## Boundaries

The hidden Workspace browser remains hidden. No README is created. The ignored
Notepad++ checkout and the user's unrelated foundation-document/vendor-script
changes remain outside this phase.
