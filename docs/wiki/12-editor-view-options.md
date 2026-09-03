# Phase 9 — Editor view options

> Status: **Implemented; independent re-review pending**
> Owner/builder: `/root`
> Last updated: 2026-09-03
> Parity scope: `C2.F12` editor word wrap and wrap-marker display

## User outcome

Duckpad's native **View** menu exposes **Word Wrap** and **Show Wrap Symbols**.
Word wrap is enabled for a new scratch tab, may be changed independently for
each tab, and is restored with that tab after relaunch. Wrap symbols use
Scintilla's start/end visual markers and do not alter document bytes, revision,
dirty state, undo history, or language styling.

The `NSTextView` fallback supports word-wrap switching and horizontal scrolling
but deliberately disables the wrap-symbol menu item because it cannot render
the same Scintilla markers. The production composition uses Scintilla.

## Architecture and persistence

- `EditorViewOptionsPort` is an Application-owned boundary. Presentation sends
  user intent through it without exposing Scintilla messages or AppKit layout
  policy to Domain/Application.
- `ScintillaEditorAdapter` maps the port to `SCI_SETWRAPMODE` and
  `SCI_SETWRAPVISUALFLAGS`. Each buffer owns its own `EditorViewState`.
- `SessionRecoveryUseCase.editorViewStateDidChange()` schedules recovery even
  though no workspace/document revision changes.
- `wrapMarkerVisible` is an additive recovery field. Custom decoding defaults
  the field to `false` for archives written before Phase 9.
- Menu validation derives checkmarks from the active editor every time, so tab
  changes cannot leave stale UI state.
- View actions and validation require a ready workspace, an active buffer, and
  no termination review, so provisional restore state cannot accept a change
  that recovery intentionally ignores or later overwrites.

No Notepad++ source file was copied, modified, staged, or used as a build input.
This slice implements one frozen baseline feature; it does not claim the 90%
release gate or the remaining display/settings parity.

## Acceptance evidence

- Legacy view-state JSON decodes with hidden wrap symbols and new state
  round-trips.
- View-only changes schedule a recovery generation without a text edit.
- Real Scintilla buffers keep independent wrap/marker state and restore it from
  recovery without advancing document revision.
- The fallback editor keeps per-buffer word wrap, restores it, and exposes its
  lack of marker support to menu validation.
- The native menu publishes both selectors, reflects active state, and disables
  unsupported marker rendering.
- Delayed startup and termination-review tests prove view commands stay disabled
  and inert until changes are durable and actionable again.

Focused and full validation results are recorded in the Phase 9 entry of the
wiki index before candidate freeze. Independent review and an exact signed
receipt remain mandatory before commit.

Builder validation after P9-01 remediation: the focused startup/termination
regressions pass 2/2, and the complete debug and release suites pass 189/189
each. Pre-remediation supporting evidence also includes focused
view/recovery/menu plus close-race tests 7/7, close-retry repetition 10/10,
empty-scratch debug 188/188, and macOS 13 x86_64 release build/link.

## Agent work log

- **Investigator/builder:** `/root`, acting directly after the user's request to
  stop adding implementation agents.
- **Decision:** extend the already persisted per-buffer wrap state instead of
  creating a second preferences authority; keep the marker state in the same
  recovery value and make its schema addition backward compatible.
- **Incidental hardening:** full-suite stress exposed an old test that attempted
  its newest edit while the prior edit's persistence transaction could still be
  active. The UI close Task is now awaitable by tests, and the test drains the
  earlier persistence boundary before asserting the synchronous accepted edit;
  rejected input is never treated as if polling could restore it.
- **P9-01 remediation:** `/root` directly added identical startup, active-buffer,
  and termination-review admission checks to validation and actions, with
  delayed-restore and blocked-termination regression coverage. Independent
  re-review remains mandatory before staging.
- **Explicit non-scope:** zoom, visible whitespace/EOL/control characters,
  minimap, settings UI, baseline score/evidence signatures, README, and the
  ignored Notepad++ reference checkout.
