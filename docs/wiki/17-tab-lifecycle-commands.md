# Phase 14 — Tab Lifecycle Commands

- **Status:** Implemented; independent review pending
- **Owner/agent:** `/root` direct investigator and builder
- **Last updated:** 2026-09-03
- **Related:** [Multiline tabs](08-multiline-tabs.md), [Recently closed tabs](16-recently-closed-tabs.md)

## User outcome

Duckpad now keeps up to 100 process-local recently closed tabs for
**Tabs → Undo Close Tab** (`Command-Shift-T`). This is a restore-history limit,
not a limit on simultaneously open tabs.

The Tabs menu and every tab's context menu expose the remaining bulk lifecycle
commands: Close All, Close Others, Close to Left, Close to Right, Close
Unchanged, and Close Unpinned. Main-menu bulk commands intentionally have no
default shortcut because macOS has no broadly established chord for them and a
made-up default would increase collision risk. They remain keyboard reachable
through the native menu search and full keyboard access.

## Stable scope and data safety

- A command captures exact `TabID` targets in visual order at admission time.
- Pinned tabs are excluded from implicit bulk targets; an explicit single-tab
  Close remains available for a pinned tab.
- Close Unchanged selects only clean, unpinned buffers. Dirty state is read from
  Domain metadata rather than inferred from tab decoration.
- Dirty targets pass through the same serialized Save/Cancel/Discard review as
  `Command-W`, window close, and application termination. A cancellation or
  failure stops the remaining batch without reopening tabs already durably
  closed.
- Every successfully closed target enters the same bounded recent-close LIFO,
  so bulk mistakes remain recoverable with repeated `Command-Shift-T` up to the
  100-entry policy.

## Lifecycle and architecture

`ScratchWorkspaceUseCase` owns scope computation and recent-history policy.
Presentation maps native menu/context actions to stable scopes and retains each
accepted close task until it finishes. Termination first disables new workspace
interaction, joins accepted New/Close/Undo-Close work, then performs dirty
review and final recovery flush. This prevents a queued bulk close from
publishing after termination approval.

No editor bytes, undo state, file binding, language metadata, or recovery state
are mutated while merely computing a scope. The existing close transaction is
the sole mutation path.

## Validation

- The 101-close fixture proves oldest eviction at exactly 100 entries and
  restores the remaining entries in LIFO order.
- Scope acceptance covers pinned, clean, dirty, left, right, current, other,
  all, unchanged, and unpinned membership by stable identity.
- AppKit acceptance verifies every main-menu selector, the deliberate absence
  of new shortcuts, whole-menu shortcut uniqueness, and disabled empty scopes.
- A blocked persistence test proves termination cannot finish before an
  already accepted close transaction settles.
- Focused remediation 8/8 and full Debug/Release 221/221 pass. A pre-existing headless
  Scintilla assertion compared the asynchronously settling first-visible-line
  coordinate as if it were document mutation; the acceptance now continues to
  require exact text, revision, selection, horizontal offset, wrap state, and
  recovery bytes while excluding only that volatile layout coordinate.
  Independent review is required before candidate freeze.

## Deferred from this slice

Custom tab rename, persistent recent history across relaunch, missing-file
presentation, and tab move/clone across split views remain later roadmap work.
The multiline-tab title/padding rebalance remains the explicit TODO in
[Phase 12](15-searchable-document-switcher.md#follow-up-todo).

## Commit evidence

- Candidate ID: pending exact stage freeze
- Independent review: pending
- Local receipt: pending
- Commit: pending
