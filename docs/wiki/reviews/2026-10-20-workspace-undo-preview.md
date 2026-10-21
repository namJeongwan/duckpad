# Workspace search, Undo and Markdown preview follow-up

Base: `9e7a73644c9032b0ff0d594ed99dd608bd8a44fc` (after the 0.14.0 update-feed merge).
Implementation: `fix/workspace-file-search`. Release preparation: 0.14.1 (63).

## Filename discovery and workspace tree

The filename popup previously filtered only the first 20,000 indexed entries.
Unopened files in deeper directories could be absent even for an exact query
such as `utils.ts`. Filename queries now reach disk discovery before applying
the retained-result cap. Bundled ripgrep streams names without reading document
contents; workspace access retains its original root device/inode checks.
ASCII matching avoids per-name Foundation URL construction and ICU folding;
non-ASCII names retain case/diacritic folding, and query punctuation stays literal.
Ignore rules, hidden-file preferences, no-follow checks and cancellation remain.
Nonempty native queries have a bounded 256 MiB name stream and 30-second deadline;
the compatibility provider separately bounds discovered names, bytes and time.

The Workspace sidebar now has an input using the shared search-field component.
It searches filenames and paths recursively, shows matching files with their
ancestors, and restores the original tree navigation when cleared. Search-tree
expansion/selection is not persisted as normal navigation. Normal navigation is
retained by root ID and path across hidden-file refreshes and root additions or
removals. Sidebar results are limited to 1,000 and disclose truncation. Empty
directories are not filename results. Existing localized strings are reused.

Actual signed sandbox-app probe: `utils.ts` returned **666 files, not truncated**.
Before the matching optimization: **11,617 ms**; after: **2,924 ms**. A separate
raw-name discovery observed 378,716 names / 62,692,341 bytes in 1,796 ms. These are
individual local measurements, not a general latency guarantee; UI input remains
separate from the cancellable background search.

## Undo and saved state

The adapter forwarded native savepoint notifications only for buffers containing
file-format Undo actions. Ordinary text Undo therefore restored the bytes while
leaving the workspace's dirty bit set. Trusted savepoint tracking now includes
successful loads, successful saves and explicitly clean initial session buffers.
Stale writes and invalidated points remain untrusted. Dirty recovery snapshots
do not become clean merely because Undo returns to their restored baseline.

The loaded-file and saved-file regressions failed before the correction (four
dirty-state assertions) and pass afterward. Redo restores dirty state. Clean and
dirty recovery baselines, existing format Undo/write races, save failures and
per-document state are covered. Two existing save tests now expect both the
initial clean anchor and the successful save anchor.

## Markdown preview

First opening a document no longer waits for the former 350 ms debounce; edits
within the same document debounce for 150 ms. Mermaid is a separate bundled
runtime loaded only when diagrams exist. Initial JavaScript decreased from
6,762,689 to approximately 1,498,000 bytes. Mermaid requires no installed runtime,
network service or CDN. Generated assets come from the existing pinned npm tree.

Native text updates do not await all Mermaid diagrams. The diagram scheduler
retains only one active and one latest pending request, preventing stale work
from growing Mermaid's internal queue. A gated 50-edit regression failed before
this safeguard and passes afterward. Generation and attachment
checks prevent an older diagram from replacing newer text. Sanitized SVG reuse
is bounded to 16 entries / 4 MiB and avoids reusing the same SVG IDs twice in one
page. CSP, DOMPurify, local-image authorization and runtime teardown remain.
Markdown parsing, highlighting and KaTeX still process the complete source.

A panel-direct WebKit measurement changed from **342 ms to 268 ms** for a plain
document. This excludes coordinator debounce and is a single local comparison.
The final packaged application opened/closed preview three times and rendered
Rust highlighting, KaTeX fonts and lazily loaded Mermaid without changing source
bytes or revision.

## Usage lifecycle delivery

The earlier usage-statistics change is included: enabled/configured startup
immediately attempts asynchronous lifecycle delivery instead of waiting five
minutes. Subsequent batches retain their existing cadence. Opt-out, cancellation,
bounded retries and success-only acknowledgement remain. It does not replay a
version event already acknowledged by a same-version preview installation.
Actual dashboard ingestion remains unverified; no artificial production events
were sent. Structured error reporting remains a separate deferred task.

## Validation and review

- Final 0.14.1 release gate: **159 Swift functions passed**, including localization
  catalogs, the related UI/backend suites and the 81-function application set.
- Related search/preview/Undo run: 49 test functions passed; additional focused
  runs cover topology restoration, Unicode/literal query matching, clean/dirty
  recovery and the 11 usage-statistics functions. These runs overlap.
- Application file/session/recovery regression set: **81 functions passed**.
- Markdown parser: **4 Node tests passed**.
- Final native application builds; package/resource/signature verification passes.
- Isolated Finder/Open With, resizing, sandboxed extension isolation and ripgrep
  smokes passed. The final optimized app separately passed signed sandbox name
  discovery and packaged Markdown smokes.
- Dark sidebar search screenshot visually checked at 220-point width; existing
  strings/localization are reused. Full manual inspection in eight languages,
  physical Korean IME, Intel/macOS 13 hardware and native Save-panel automation
  were not run. The Save-panel smoke explicitly reports SKIP.
- Independent reviewers approved search and Undo/Markdown separately; all reported
  Major findings were resolved. Final matching optimization was also reviewed.
- Developer test app only: native Apple Silicon, ad-hoc signed, not notarized.
  The implementation was validated before release preparation. Universal package
  verification and publication evidence are recorded with the 0.14.1 release.
