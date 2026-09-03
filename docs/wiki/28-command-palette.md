# Phase 25A — Command palette and unified command registry

Status: **Implemented; independent review pending**

## User contract

`Shift-Command-P` opens one searchable palette for Duckpad commands. The palette
discovers actionable leaf commands from the current native main-menu tree, so
core commands, document/window commands, and enabled extension contributions
share the same execution surface. Results show their menu path and effective
shortcut and preserve menu traversal order when search rank is equal.

Search is case- and diacritic-insensitive, accepts multiple terms across command
title, menu path, and shortcut, and ranks exact/prefix title matches ahead of
path-only matches. Up/Down moves selection, Return executes, and Escape closes.
The palette command excludes itself to prevent recursive presentation.

## Command authority and safety

The registry retains the original `NSMenuItem` rather than copying a selector or
extension identifier into a second command model. Before the popover changes the
responder chain, Presentation resolves and weakly pins the effective target for
explicit and nil-target commands. It runs that target's `NSMenuItemValidation`
for display and again immediately before dispatch, exposes unavailable commands
as disabled, and sends the original item to the captured target through AppKit.
This preserves represented objects, extension identities, menu-state validation,
and termination admission checks without duplicating business rules or allowing
a command enabled only at presentation time to bypass its current state.

The palette observes its host window and dismisses on close. Window teardown and
termination review also dismiss it, and execution rechecks that workspace
interactions remain admitted. If enabled extension contributions rebuild the
main menu while the palette is visible, the current query is retained and the
registry is replaced immediately from the new menu. Popover animation follows
the macOS Reduce Motion preference. Search field, result table, result
availability, and qualified menu paths expose native accessibility metadata.

## Shortcut decision

`Shift-Command-P` belongs to the unified Command Palette. The previous language-
only popup remains available as **Language → Choose Language…** and from the
clickable language status control, but no longer consumes the global palette
shortcut. The complete menu collision test continues to require every non-empty
key equivalent/modifier tuple to be unique.

## Validation

- Registry tests prove core, extension, and native menu commands are discovered
  in one ordered surface while submenu headings, separators, and the palette
  command itself are excluded.
- Search tests cover multi-term title/path matching, shortcut lookup, stable rank,
  and preservation of the original represented-object-bearing menu item.
- Validation tests prove a disabled menu command cannot execute from the palette.
- Race tests disable a command after presentation and prove activation re-runs
  current validation. A nil-target fixture proves the pre-presentation responder
  is the exact dispatch target.
- Hosted tests prove live extension-menu refresh plus host-close and termination
  dismissal, and the animation policy is disabled when Reduce Motion is active.
- The native menu test proves exact `Shift-Command-P` ownership and global
  shortcut uniqueness.
- Clean scratch-path Debug and Release builds each pass all 340 tests after
  remediation.

## Deliberate boundary

Macro recording, playback, persistence, and repeat are deliberately excluded by
product decision and are not implemented by the command registry. `C9.F02`
therefore remains honestly Missing in parity evidence; it is not silently marked
Reviewed-N/A. Configurable shortcut editing remains a later non-P0 capability.
README, the ignored Notepad++ checkout, and user-owned doc04/vendor-script changes
remain untouched.
