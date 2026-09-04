# Phase 29A — Tab responsiveness and scratch UI

Status: **Implemented; independent review pending**

## Product decision

Duckpad's primary surface is an unlimited scratch-document tab set. Tab titles
must display their complete names without an ellipsis. Tabs continue to wrap
across rows at the visible viewport width; a single title wider than the
viewport keeps its intrinsic width and the tab strip exposes horizontal
scrolling rather than shortening the title.

The saved Workspace browser is no longer part of the default product surface.
Its sidebar, File/View menu commands, shortcuts, and folder-drop entry point
are hidden. Internal storage and use-case types remain temporarily for recovery
compatibility and do not constitute a visible Workspace feature.

## Responsiveness correction

Two independent synchronous costs made a click among dozens of tabs feel
delayed:

- activation waited for the complete durable session write before publishing
  the new active document;
- every active-tab change reloaded all collection items.

Activation now publishes the reversible view-state transition before the
durable write. A failed write restores the authoritative previous selection
and emits the existing typed retry event. The tab strip handles an active-tab
change by replacing and reloading only the previous and current snapshots,
then bringing the selected item back into horizontal view and its vertical
center. It does not rebuild the remaining tab items.

Hover tracking uses the visible bounds of each reused tab view. An inactive
hover changes only that item's background, border, and close affordance;
selection remains visually immediate while persistence is pending. Reused
items reset hover state and callbacks.

## Verification

Focused Debug validation covers:

- complete long-title geometry with no ellipsis and horizontal overflow;
- a presented live window that preserves the full document width, scrolls
  horizontally, and brings a newly selected short tab back onscreen;
- local enter/exit hover affordances;
- a 500-tab active change with two item reloads, zero full reloads, and a
  50-millisecond interaction budget;
- selection of the 25th tab in a 50-tab session while the persistence commit is
  deliberately blocked, proving the editor/tab selection updates first;
- persistence-failure rollback to the previous authoritative selection;
- absence of Workspace menu commands and a single visible editor pane.

The focused Application and AppKit Presentation run passes 79/79 tests in both
Debug and Release. The complete Application target passes 114/114 in Debug,
and all 114 Presentation tests pass in isolated Debug and Release helpers. A
single-process all-module Swift test remains unsuitable as release evidence on
the current macOS runner because the long-lived AppKit helper can exit with
signal 11 while unrelated suites are concurrent.

The packaged native Release performance gate passes all five budgets: warm
launch 453.153 ms, typing p95 0.02225 ms, complete 100 MiB open 1031.37 ms,
200-tab reflow p95 0.002041 ms, and bounded 2,000-file folder search 291.930583
ms. Static package/signature verification runs as part of that gate.

## Boundaries

Open tabs remain unlimited. The 100-entry maximum applies only to recently
closed/history state. Macros stay intentionally excluded. No README is added,
the ignored Notepad++ reference tree is not versioned, and user-owned local
documentation/vendor-script edits are outside this slice.
