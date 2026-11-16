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

## Project search result stability (2026-11-16)

Find/Replace in Files retains its last visible rows and preview while the next
query is debouncing or scanning. The old result is immediately invalidated for
activation, replacement and opening in the classic Find window. An empty initial
open-buffer progress update cannot blank retained filesystem results. Clearing
the query, a completed zero-match search or a search error clears the view;
pending preview work is invalidated too. Identical progress avoids table/preview
rewrites, and appended rows preserve the selected match and preview selection.

Across multiple roots, the remaining file and input-byte discovery budgets are
shared among roots that have not yet started. This prevents a large earlier root
from consuming the complete 10,000-file/256-MiB allowance before later roots are
visited. Unused capacity carries forward. Earlier roots may be truncated at their
share even if later roots leave spare capacity; capacity is not redistributed
backward. Partial results remain explicitly truncated and cannot enable Replace
All. Global file, byte, match and result-memory bounds still apply. Single-root
search retains its existing budget.

Regression tests cover a literal `hongyoung` inside a URL through the actual
Replace-in-Files controller and native unsaved buffer, stale-action rejection,
preview stability and late failure callbacks, and later-root matches under both
file-count and byte limits. User documents are not edited by these tests.

## Syntax colors in search previews (2026-11-16)

Find/Replace in Files uses the editor's existing Lexilla language definitions and
light/dark palettes to color the read-only code preview. The yellow search match
remains above syntax colors. Open buffers respect manual language selection;
closed files use filename and content detection. Plain text and unsupported
lexers retain the normal preview foreground.

A dedicated native lexer receives at most 32 KiB of visible text and 64 KiB of
preceding context. A separate 64 KiB document-start probe preserves shebang and
signature detection for matches far into a file. Lexer work stays synchronous
and bounded; multiline constructs starting before the preceding-context window
can have approximate colors. The preview never shares an editable document or
undo stack. Theme updates preserve the preview selection and scroll position.

Focused tests exercise Rust, Python, Ruby, JSON and YAML colors, preceding
multiline comments, distant extensionless shebang scripts, UTF-8 scalar
boundaries, light/dark search overlays, and the actual closed-file and unsaved
manual-language search paths. Native source bytes, language and Undo history
remain unchanged. Canonically equivalent Unicode previews with different byte
and UTF-16 lengths replace their exact source before applying attributes.
Light/dark preview snapshots are inspected separately.
