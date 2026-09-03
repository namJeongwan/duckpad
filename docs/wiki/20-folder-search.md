# Phase 17 — Folder Search and Structured Results

Status: **Content approved; exact candidate receipt pending**

## Outcome

Duckpad now searches recursively across a user-selected folder from **Search → Find in Folder…** (`Command-Shift-F`) or the Find panel's **Folder…** button. Results stay in the existing non-modal search panel, grouped by relative file path with line, UTF-8 byte column, and snippet. Double-click or Return opens the file and selects the exact match.

Normal, Extended, Regex, Match Case, Whole Word, and dot-matches-newline reuse the same search engine as current/open-document search. Folder results are read-only; folder Replace All is intentionally not introduced.

## Bounded filesystem boundary

- AppKit grants a one-shot user-selected directory URL; the Infrastructure adapter owns security-scoped access and blocking filesystem calls.
- Descriptor-relative traversal and reads use `openat`, `O_NOFOLLOW`, and same-descriptor `fstat` snapshots, so path swaps cannot redirect a search outside the selected root. Reads stop at the configured byte cap even if a file grows after inspection.
- Enumeration skips dot/Finder-hidden entries, Foundation/common-extension packages, symbolic links, non-regular files, unreadable entries, and oversized files. Directory-entry count and name bytes are independently capped.
- Defaults cap enumeration at 10,000 files, 64 MiB per file, 256 MiB total input, 100,000 matches, 32 MiB result metadata, 64 KiB patterns, and 8 MiB regex documents.
- Enumeration and scanning run away from the main actor and propagate cancellation through directory listing, file reads, and both detached tasks.
- Regex syntax is compiled once before enumeration, including for empty or entirely undecodable folders. Result paths and identity are retained once per document, match metadata is charged to one saturating 32 MiB budget, and the AppKit table materializes display text only for requested rows.
- UTF-8, UTF-8 BOM, and BOM-marked UTF-16 use the existing strict text codec; undecodable candidates are counted as skipped.

## Stale-result safety

Each document result carries the adapter-produced content identity from the exact searched file descriptor; its matches carry only ranges and display metadata. Result activation passes through `FileDocumentUseCase`, then requires the same canonical path and identity, a clean live buffer, exact workspace/editor revision agreement, and an in-bounds UTF-8 range. Dirty open documents, files changed after search, invalid ranges, and unsupported selection adapters fail as stale without moving the selection or replacing bytes. Accepted activation tasks are cancelled and joined before termination's final recovery flush, preventing late tab mutation after Cmd-Q or red-window close.

## Validation

Focused tests cover recursive deterministic enumeration, hidden/package/symlink exclusion, adversarial file/directory swaps, file growth, directory metadata and byte caps, UTF-8 and UTF-16 Unicode search, invalid text and invalid regex handling, global result truncation, cancellation propagation, shortcut collision, routed panel search/open/selection, dirty-buffer rejection, changed-disk rejection, and Cmd-Q/red-close activation joining.

The full Debug and Release suites each pass 254/254 tests; `git diff --check` passes. Independent review approved the content with 0 Blocker/Major/Minor; exact receipt and commit evidence are pending.

## Next slice

Persistent per-document bookmarks, next/previous bookmark navigation, and clear-all behavior follow. Macro recording/playback remains excluded.
