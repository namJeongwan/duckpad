# Phase 13 — Recently Closed Tab Restoration

- **Status:** Approved, committed, audited, and pushed to `origin/main`; history-cap extension in Phase 14
- **Owner/agent:** `/root` direct investigator and builder
- **Last updated:** 2026-09-03
- **Related:** [Product philosophy and parity](01-product-philosophy-and-parity.md), [Session recovery](07-session-recovery.md), [Multiline tabs](08-multiline-tabs.md)

## User outcome

**Tabs → Undo Close Tab** restores the most recently closed tab with
`Command-Shift-T`. The command is disabled until a restorable tab exists and
uses a bounded LIFO stack per live workspace. The Phase 13 delivery shipped 20
entries; Phase 14 raises the current product policy to 100 entries without
changing restore ordering or durability semantics.

Restoration preserves the stable tab/document/buffer identities, prior visual
position within the pinned or ordinary group, title, pin state, file binding,
language override, dirty flag, revision, UTF-8 text, selection, caret, scroll,
word-wrap, and wrap-symbol state. A dirty tab deliberately closed with Discard
can therefore still be recovered from the recent stack without weakening the
explicit close confirmation gate.

Closing the final tab still creates an immediate scratch document. Undo Close
Tab replaces that automatic document only while it remains untouched and
unbound; once the user edits or saves it, both documents are retained.

## Durability and lifecycle

The close enters the recent stack only after session metadata and the ordinary
crash-recovery close archive both commit successfully. Restore installs the
captured editor checkpoint, persists the reconstructed session, and commits a
recovery archive containing the restored bytes before publishing the tab to the
UI. A failed restore removes the temporary editor installation, keeps the stack
entry, and exposes the existing typed Retry action.

An accepted `Command-Shift-T` task is registered synchronously with the window.
Termination closes interaction admission and joins that task before dirty-tab
review and final recovery flush, preventing a restored tab from appearing after
termination approval.

The recent stack is intentionally process-local in this slice. Normal open-tab
crash recovery remains durable across relaunch; a persistent cross-relaunch
recent-history browser and missing-file/permission presentation remain the
separate C7 recent-files follow-up.

## Architecture

- Domain's `ClosedTabState` contains document metadata only and restores it
  while enforcing stable identity, unique binding, and pinned-prefix invariants.
- `ScratchWorkspaceUseCase` owns the bounded LIFO policy and the durable
  close/restore transaction. It never owns live editor text.
- `EditorBindingUseCase` supplies narrow capture/install/retire closures over
  `EditorPort`, keeping Scintilla and AppKit outside Domain and Application.
- Presentation owns the native menu selector, exact macOS shortcut, validation,
  and termination-task admission.

## Validation

- Domain coverage fixes stable identity, original ordering, language override,
  dirty flag, and revision restoration.
- Application coverage restores dirty Unicode bytes, retries failed persistence
  without consuming the stack, and distinguishes untouched from edited
  automatic replacement scratches.
- Recovery integration verifies restored bytes are durable before UI
  publication.
- AppKit coverage verifies the exact `Command-Shift-T` chord, complete-menu
  shortcut uniqueness, disabled/enabled state, selector routing, and termination
  joining a blocked accepted restore.
- Full Debug and Release suites each pass 215/215 tests. The Release build emits
  only the existing SwiftPM convenience-symlink warning after linking succeeds.
- README files and the ignored Notepad++ reference remain outside this change.
  The pre-existing `docs/wiki/04-implementation-foundation.md` edit and
  `scripts/vendor_scintilla_5_6_6.sh` remain preserved and excluded.

## Commit evidence

- Candidate ID: `fadd89f20b4ced4dca8b90c0d3a1dcfb479c7c42ce4f072f244ca5ddb6fe557b`
- Independent review: approved — 0 Blocker, 0 Major, 0 Minor
- Local receipt SHA-256: `9344041b85d0577a17fcf3fdb03c2f46d0e79456ac8aed08750e65ce3205df2d`
- Commit: `8d7ecca5b20f9ff9714cdb2bb9cd470db0e41b99`
- Delivery: `origin/main`
