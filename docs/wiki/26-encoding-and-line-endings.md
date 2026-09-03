# Phase 23 — Encoding and line-ending controls

Status: **Approved, committed, and pushed**

## User contract

Duckpad exposes the durable text format instead of hiding it behind Save As. The Format menu and the status bar provide UTF-8 with or without BOM, UTF-16 little- or big-endian with or without BOM, and LF, CRLF, or CR conversion commands. The status control shows the active file's exact encoding/BOM and line-ending metadata, including mixed or no-EOL input.

Encoding and line-ending commands intentionally have no default shortcuts, avoiding collisions with editing, search, tabs, symbols, and macOS system commands. The status control opens the same native menu as the menu bar. Checked menu items always come from the active tab's authoritative `FileBinding`, not cached view state.

## Open and conversion behavior

Format > Open Using Encoding allows an explicit UTF-8, UTF-16 LE, or UTF-16 BE hint for BOM-less input. Automatic Open remains BOM-first and strict UTF-8 without a BOM. Invalid UTF-8, truncated UTF-16, and invalid surrogate sequences continue to surface typed failures rather than replacement characters.

Choosing an encoding or EOL conversion saves the active document using the chosen durable format. A scratch tab first uses the native Save panel. Encoding conversion preserves the current EOL choice; EOL conversion preserves the current encoding and BOM. Selecting the already-active format is a no-op. Existing identity-checked atomic save, external-conflict compare/reload/overwrite, cancellation, and retry paths carry the exact conversion through to completion.

Conflict overwrite revalidates the complete captured file context before the write. Receipt publication additionally compares the tab's buffer identity and prior `FileBinding` inside the serialized workspace transaction. A rebind before overwrite leaves both old and new files untouched; a rebind during an already-suspended durable write cannot be rolled back at the filesystem boundary, but it preserves the newer tab binding, does not mark it clean, clears the obsolete conflict, and returns typed invalidation.

The editor remains the live UTF-8 text authority. EOL conversion normalizes bytes at the persistence boundary and records the chosen format in `FileBinding`; every later ordinary save applies that same format, so an edit cannot silently revert a prior conversion.

## Native UI and accessibility

The bottom status bar displays values such as `UTF-8 BOM · CRLF`, `UTF-16 LE · CR`, or `UTF-8 · Mixed EOL`; an unbound scratch tab says `UTF-8 · Unsaved` instead of guessing its eventual disk format. Its tooltip describes that conversion saves the file, and its accessibility label/value exposes encoding and line endings. Format controls are disabled during startup/termination review or when file services are unavailable, matching the rest of Duckpad's command admission.

Native Open, Save, Save As, and format-conversion actions synchronously register their asynchronous work before returning to AppKit. Accepted save/conversion work may cross the later termination lock, and application/window termination joins that exact task before dirty review and final recovery flush. This prevents an immediate `Command-Q` from dropping a clean document's requested conversion or allowing suspended file I/O to finish after termination approval.

## Validation

- Presentation tests cover every selector, empty key equivalent, disabled-state admission, checked format state, explicit BOM-less UTF-16 open, exact Korean/emoji conversion bytes, CR-to-CRLF normalization, binding publication, and status-bar text.
- Application and presentation race tests prove that a Save panel or serialized file operation cannot carry a captured conversion across an active-tab identity/revision/binding change or create the rejected destination.
- The production smoke uses the real local file store to open BOM-less UTF-16 LE and atomically convert it to UTF-8 BOM plus CRLF.
- The initial independent review found two Majors: stale conflict/post-write binding authority and missing accepted format-task termination joining. Exact pre-write and post-write authority checks plus synchronous file-task lifecycle registration remediate both, with regressions for rebind-before-overwrite, rebind-during-write, and immediate termination during a cancellation-ignoring blocked conversion.
- Exact-current Debug and Release each pass 320/320 tests. The production smoke verifies the exact `EF BB BF` prefix and UTF-8 Korean/emoji CRLF payload; parity passes 31/31, commit governance passes 8/8, the default checker exits successfully, and `git diff --check` passes. Independent remediation re-review approved the exact candidate with 0 Blocker/Major/Minor; commit `703b89c` passed the signed receipt audit and was pushed to `origin/main`.

## Deliberate boundary

Legacy locale-dependent 8-bit code pages and heuristic BOM-less detection are excluded because silent guesses are unsafe for scratch data. Macro recording/playback remains excluded. README, the ignored Notepad++ checkout, and user-owned doc04/vendor-script changes are untouched.
