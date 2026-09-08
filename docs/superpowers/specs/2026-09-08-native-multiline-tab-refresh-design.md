# Native Multiline Tabs and Incremental Insertion Design

Status: **Approved by the user on 2026-09-08**

## Goal

Make Duckpad's document strip behave like Notepad++'s Windows multiline tab
control while retaining Duckpad's explicit product constraints: complete tab
titles, no tab-strip scrollbar, compact connected rows, and no whole-strip
refresh when a new document is created.

## Reference behavior

Notepad++ creates the Windows common-control class `WC_TABCONTROL` and enables
`TCS_MULTILINE` for horizontal multiline tabs. It does not opt into
`TCS_RAGGEDRIGHT`, so the platform control uses its default multiline row
justification. Microsoft's `TCS_RIGHTJUSTIFY` documentation describes the
observable rule: once a tab control has multiple rows, tab widths are expanded
so each row fills the control.

The Windows common-control implementation itself is proprietary and cannot be
linked into a macOS process. Duckpad will therefore use a clean-room Swift
implementation based on the documented contract, the Notepad++ call site, and
compatibility implementations only as behavioral evidence. No Windows DLL,
Wine runtime, GPL component, or package dependency is copied or shipped.

## Layout contract

- A single row keeps every tab's measured intrinsic width. Unused trailing
  space remains empty; the strip does not initially stretch to 100 percent.
- Wrapping begins only when the complete measured widths no longer fit one
  row.
- Once wrapped, contiguous tabs are distributed across rows as evenly as the
  full-title widths allow. For equal-width tabs, row counts differ by at most
  one, with fuller rows first.
- Every multiline row receives its positive remaining width evenly across its
  tabs so the row reaches the viewport edge.
- Widths are never reduced below the measured title width or the existing
  minimum tab width. A single title wider than the viewport remains wider than
  the viewport rather than truncating.
- Source order, zero inter-tab gaps, row height, drag/drop indexing,
  accessibility, and the absence of visible or operable tab scrollers remain
  unchanged.

The layout remains a pure calculation. AppKit's collection layout consumes the
result and continues caching frames and row ranges for bounded visible-item
queries.

## Incremental insertion contract

`WorkspaceChangeKind.tabInserted(index:)` is authoritative only when the new
snapshot is exactly the old ordered tab list plus one item at that index. In
that case `MultilineTabStripView` will:

1. update its data source and ID cache;
2. insert the one measured width into the collection-layout cache;
3. call `NSCollectionView.insertItems(at:)` for the new item;
4. synchronize active selection and reload only an existing tab whose active
   appearance changed; and
5. update the hidden keyboard-only document switcher exactly once.

Any malformed or out-of-order insertion safely falls back to the existing full
snapshot apply. This keeps recovery/reset correctness while removing the normal
new-document flash.

In two-group mode, reconciliation still decides which focused group owns the
new tab, but only that group's strip receives the insertion. The unaffected
group remains untouched. Existing group topology, focus, and editor routing
remain authoritative.

## Editor-view stability

The Scintilla group adapter treats redisplaying the same buffer in the same
host as an idempotent update. It refreshes descriptor/input/language state but
does not remove and re-add the already attached native view. A genuine buffer
or group change still follows the existing attachment path.

This closes the second visible-refresh source: controller routing and the
normal editor binding may both describe the selected buffer during a structural
workspace event, but duplicate descriptions no longer reparent the native
editor view.

## Framework and dependency decision

AppKit remains the shell for this feature. Neither `NSTabView` nor SwiftUI
`TabView` implements Notepad++-style multiline document rows. A SwiftUI rewrite
would still require a custom layout and would wrap the existing AppKit
Scintilla view, menus, drag/drop, IME, accessibility, and split view. It would
add lifecycle risk without removing the custom work.

SwiftUI remains suitable for isolated future surfaces such as settings or
onboarding through `NSHostingView`. The document workspace stays AppKit and no
new dependency is introduced.

## Validation

- Pure layout tests cover natural single-row widths, balanced multiline rows,
  row justification, variable-width safety, exact fit, and oversized titles.
- Hosted AppKit tests prove a valid insertion avoids `reloadData`, updates one
  collection item, preserves selection, and keeps scrollers disabled.
- Editor-group controller tests prove only the focused strip changes when a
  new tab is inserted in split mode.
- Scintilla adapter tests prove same-buffer redisplay preserves the attached
  native view and first responder.
- Focused suites, the full serial test suite, debug/release builds, diff checks,
  and the existing headless smoke path run before delivery.
- Independent code review is required before the commit and repeated on the
  exact committed candidate before push.
