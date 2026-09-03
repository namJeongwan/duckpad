# Phase 12 — Searchable Open Document Switcher

- **Status:** Implemented; independent review pending
- **Owner/agent:** `/root` direct investigator and builder
- **Last updated:** 2026-09-03
- **Related:** [Multiline tab workspace](08-multiline-tabs.md), [Workspace chrome](14-workspace-chrome-and-document-dropdown.md), [Standard shortcuts](13-standard-editing-shortcuts.md)

## Goal

The Phase 11 dropdown made every open document discoverable, but a flat native
menu becomes slow to scan long before the multiline tab bar reaches its tested
500-tab range. This phase turns the same chrome control into a searchable,
keyboard-first document switcher without moving document authority into UI.

## Implemented behavior

- Clicking Open Documents or choosing **Tabs → Open Document…** opens a native
  transient popover. `Command-Shift-O` is the collision-tested shortcut.
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

- Candidate ID: pending exact stage freeze
- Independent review: pending
- Local receipt: pending
- Commit: pending
