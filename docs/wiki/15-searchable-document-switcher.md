# Phase 12 — Searchable Open Document Switcher

- **Status:** Phase 12 delivered; launch chrome updated by Phase 33
- **Owner/agent:** `/root` direct investigator and builder
- **Last updated:** 2026-09-03
- **Related:** [Multiline tab workspace](08-multiline-tabs.md), [Workspace chrome](14-workspace-chrome-and-document-dropdown.md), [Editor groups and native tabs](38-editor-groups-compare-and-native-tabs.md)

## Current launch path

The searchable panel remains the open-document escape hatch, but
[Phase 33](38-editor-groups-compare-and-native-tabs.md) removes its visible
`Documents (N)` launcher and the tab-strip width reserved for that control.
Choose **Tabs → Open Document…** or press `Command-Shift-O`; the panel now
anchors to the tab-strip surface. Its search, keyboard navigation, stable-`TabID`
activation, bounded incremental updates, accessibility, and lifecycle gate are
unchanged.

## Historical Phase 12 goal

The Phase 11 dropdown made every open document discoverable, but a flat native
menu becomes slow to scan long before the multiline tab bar reaches its tested
500-tab range. This phase turns the same chrome control into a searchable,
keyboard-first document switcher without moving document authority into UI.

## Phase 12 behavior retained by the current panel

- In the Phase 12 interface, clicking Open Documents or choosing **Tabs → Open
  Document…** opened a native transient popover. The visible button is now
  superseded; `Command-Shift-O` remains the collision-tested shortcut.
- Search matches title and full path, ignores case and diacritics, supports
  whitespace-separated terms, and ranks exact title, title prefix, title
  containment, then path containment while preserving visual-order ties.
- Rows show scratch/file/pinned state, edited state, full path or an explicit
  unsaved-scratch description, and semantic accessibility labels.
- The active document is selected initially. Up/Down changes selection, Return
  activates the exact stable `TabID`, and Escape dismisses the switcher.
- Empty results have a visible state and cannot accidentally activate a stale
  row. The footer reports either the open count or filtered/total count.
- The popover height adapts for small tab counts and caps at six visible rows.
  Larger result sets scroll without expanding the workspace chrome.
- Startup and termination admission uses the existing workspace interaction
  gate. Locking chrome immediately drops the popover and both queued and direct
  activation callbacks remain inert.

## Architecture and scope

`DocumentSwitcherSearch`, `DocumentSwitcherPanel`, and the button integration
remain in Presentation. Their only mutation output is `TabID`; activation still
passes through `DuckpadWindowController` to `ScratchWorkspaceUseCase`, which
owns persistence, active-document state, recovery, and failure publication.
Search never reads editor text or mutates document bytes, revision, dirty state,
selection, undo, file binding, language, or recovery data.

Macros and macro recording are deliberately outside Duckpad's product scope per
the user decision. This feature is document navigation, not action recording or
automation.

## Validation

- Focused tests cover title/path/multi-term/diacritic matching, stable identity,
  active initial selection, keyboard movement, empty results, popover lifecycle,
  shortcut collision, and termination interaction lock.
- A 5,000-tab filtered query completes within the 250 ms interaction budget on
  the development machine.
- Full Debug and clean-scratch Release suites each pass 205/205 tests. The only
  build warnings are pre-existing deprecations in vendored Scintilla Cocoa.
- README files and the ignored Notepad++ reference remain outside this change.
  The pre-existing unstaged Phase 1 documentation and old vendor script remain
  preserved and excluded.

## Delivery policy update

The user created `https://github.com/namJeongwan/duckpad.git` on 2026-09-03 and
explicitly authorized continuous delivery to `main`. Verified local commits are
therefore pushed to the exact `origin/main` after local review, receipt, commit,
and audit complete. Force-push and Notepad++ reference publication remain out of
scope.

## Commit evidence

- Candidate ID: `6abff1057e9ba839321934c1c8340d7bef73ac2b373bbaba0262c7f50140c3f9`
- Independent review: approved — 0 Blocker, 0 Major, 0 Minor
- Local receipt SHA-256: `8e2d42817b6ea8c3e573da448f8730f5978024f6a8f63f7a99d2c0fdf992d22a`
- Commit: `5f816e0249951e65598551c428ef4f9fccd2aa72`
- Delivery: `origin/main`

## Resolved follow-up

Phase 33 removes title truncation entirely. Short and long titles use their
complete intrinsic width, hidden affordances do not compress the filename, and
rows wrap only between complete tab items when the next item no longer fits.
Rows do not stretch their items to consume unused width, so a small tab set
keeps a normal trailing area. Tab row caps and the internal viewport are
removed: 56 and 500 tabs expose their full content height, both scrollers and
their chrome stay suppressed, and wheel/activation/programmatic clip movement
stays at origin zero. The switcher remains a fast independent navigation route
rather than a workaround for hidden tab rows.
