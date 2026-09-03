# Phase 24 — Settings, themes, and accessibility

Status: **Implemented; independent review pending**

## User contract

Duckpad provides a native reusable Settings window from the application menu with the standard `Command-,` shortcut. Preferences are applied immediately after durable persistence and are shared by every open window. The first preference set covers application appearance plus the word-wrap and wrap-symbol defaults for newly created tabs.

Appearance can follow macOS or be forced to Light or Dark. Every document window observes effective-appearance changes, so the Scintilla palette is recalculated while the app is running. Increased-contrast colors continue to follow the macOS accessibility preference rather than being overridden by an app-specific theme.

Editor defaults affect only tabs created after the preference change. Existing tabs and recovered tabs retain their own per-buffer view state; changing a global default cannot silently rewrite a document's recovery state. The TextKit fallback supports word wrap and explicitly reports wrap symbols as unsupported, while the production Scintilla adapter supports both options.

## Persistence and failure behavior

The Domain module owns the versioned value model, Application owns asynchronous load/update policy and typed outcomes, Infrastructure stores canonical sorted-key JSON in a private atomic Application Support archive, and Presentation owns AppKit controls. This preserves inward dependency direction and keeps filesystem work off the main actor.

Missing settings load as defaults. A non-regular, oversized, unreadable, corrupt, or unsupported future archive produces a typed degraded state without rewriting the unknown storage. Updates normalize the schema version and complete an acknowledged atomic write before publication. The directory and archive use private permissions. If persistence fails, the live settings and controls roll back to their last authoritative values and the Settings window exposes a failure status.

## Native UI and accessibility

The window uses native popup and checkbox controls with stable accessibility identifiers and labels. Wrap-symbol controls remain visible but disabled while default wrapping is off, preserving discoverability without implying an active option. Explanatory text states that settings apply to new tabs and that High Contrast follows macOS.

Stable identifiers are:

- `duckpad.settings.appearance`
- `duckpad.settings.default-word-wrap`
- `duckpad.settings.default-wrap-markers`
- `duckpad.settings.status`

## Validation

- Application tests cover default load, schema normalization, corrupt and unsupported storage, publish ordering, and failed-save rollback.
- Infrastructure tests cover canonical round-trip, private permissions, corrupt/non-regular archives, and an actual failed atomic write in an isolated temporary directory.
- Presentation tests cover immediate updates, native control state, accessibility identifiers, and persistence-failure rollback.
- Scintilla tests prove that preference changes affect only subsequently created buffers.
- The complete native-menu test verifies `Command-,` and checks the whole shortcut surface for collisions.
- The initial independent review found three Majors: unacknowledged UserDefaults persistence/corruption, missing live Increase Contrast notification, and document-window ownership of the application Settings command. A first remediation closed the appearance and command-ownership defects but retained a path-read/publish uncertainty flaw and did not join accepted settings work during termination.
- Final remediation binds bounded reads to a no-follow file descriptor, validates the same descriptor snapshot, privately writes and fully syncs a replacement before descriptor-relative rename, syncs the directory, and distinguishes a pre-publish failure from post-publish durability uncertainty. Uncertain publication keeps the runtime on the visible new value with an explicit warning instead of rolling back to a value that restart would not load. The application termination coordinator synchronously owns every accepted settings task and joins it before its true reply; new updates are rejected once review begins.
- Final-remediation focused tests pass 14/14, including before/after-rename faults, symlink and oversized reads, uncertainty alignment, and cancellation-ignoring blocked settings save success/failure followed immediately by termination. The production composition smoke persists preferences to an isolated real archive, closes the last document window, opens Settings with no document target, creates a new window, and observes its authoritative wrap defaults. Exact-current Debug and Release each pass 333/333 tests. Independent re-review, exact receipt, commit, and push remain pending.

## Deliberate boundary

The settings surface does not introduce macro recording/playback. Localization catalogs and distributable signing/notarization evidence belong to the final release-readiness phase. README, the ignored Notepad++ checkout, and user-owned doc04/vendor-script changes are untouched.
