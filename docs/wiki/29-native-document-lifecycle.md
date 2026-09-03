# Phase 25B — Native document lifecycle and save set

Status: **Approved, committed and pushed** (`34c3ef83b66eb8af16f968007d3752841bac76be`)

## User contract

Duckpad accepts one or more files from Finder, **Open With**, and file drops.
The files open in input order in the active Duckpad window, an already-open
canonical file activates its existing tab, and every successful open is added
to the native recent-document list. **File → Open Recent** shows at most ten
items, disambiguates duplicate filenames with their parent folder, retains the
full path as help text, and provides **Clear Menu**.

The File menu now completes the expected save family:

- **Save** — `Command-S`
- **Save As…** — `Shift-Command-S`
- **Save a Copy As…** — `Option-Shift-Command-S`
- **Save All** — `Option-Command-S`

The global shortcut collision test owns these exact combinations. The command
palette discovers the same menu items; no parallel shortcut or dispatch table
is introduced.

## Authority and lifecycle

Finder requests received before asynchronous settings/runtime startup are
queued and drained after the first window is registered. A whole multi-file
request is admitted as one window-owned file task, so application termination
waits for already accepted opens. Duckpad replies to Finder only after the
batch completes and reports failure if any item fails. Drag/drop uses this same
route instead of maintaining a second open loop.

Successful open and ordinary Save/Save As operations publish their canonical
bound URL to the application-lifetime recent-document owner. Recent-menu items
also target the application delegate, so they remain valid when document
windows are replaced; the current main menu is rebuilt after the recent set
changes.

`FileDocumentUseCase.saveCopy` captures the current revision through the same
serialized file-operation authority and applies the current or explicitly
selected encoding/BOM/EOL format. It writes a snapshot without rebinding,
renaming, or marking the document clean. A copy may not target any currently
open canonical binding. After the native save panel obtains user consent, the
destination identity is captured and passed into the atomic swap. A replacement
between observation and commit is restored and reported as a conflict; a newly
created file races an exclusive rename and is never overwritten. The presented
failure's Retry action starts a new native panel and a new identity-observation
cycle; it never reuses stale consent or a stale destination identity.

Save All snapshots the current ordered dirty-tab identities, visits only tabs
that remain dirty, prompts for untitled destinations, uses the existing
conflict-resolution path for bound files, stops on cancel/failure, and restores
the originally active tab if it still exists. The whole operation remains an
accepted file task across termination admission, so final recovery cannot race
ahead of it.

## Validation

- Application tests prove a UTF-16 LE BOM/CRLF copy has exact converted text
  while the source remains dirty, unbound, and revision-identical.
- Presentation tests prove ordered multi-file external open, canonical recent
  URL publication, and last-opened activation.
- Save All tests prove two dirty scratch tabs receive distinct panel
  destinations, become clean, publish both recent URLs, and restore the
  original active tab.
- Native menu tests prove recent-item application ownership, duplicate-name
  disambiguation, represented URL preservation, Clear Menu routing, exact save
  shortcuts, and global collision freedom.
- Adversarial tests replace a consented Save Copy destination during the blocked
  atomic write and prove the external bytes survive with a typed conflict.
- Concurrent-batch tests block `A1`, admit batch B, and prove read/tab order
  remains contiguous `A1,A2,B1,B2` rather than interleaving.
- A routed conflict test proves Retry opens a fresh panel, preserves the raced
  destination, writes only the newly selected path, and leaves the source dirty.
- Full Debug and Release suites each pass 347 tests after final remediation.

## Delivery

The exact candidate `df49292e00f84298c089400ce3b51816b4fbcf9b57c3b961952844c51fa0bdc8`
was approved with 0 Blocker/Major/Minor findings, committed as `34c3ef8`,
audited across 26 commits, and pushed to `origin/main`. The immutable receipt
SHA-256 is `30bc1be63d4dc8d6377160e6225f70364bcdaa41a59d68d5f3110f0ceacbe1e5`.

## Deliberate boundary

The `.app` document-type declaration, sandbox entitlements, bundle assembly,
signing, and Finder launch smoke belong to Phase 26; this phase builds the
in-process lifecycle they exercise. Open tabs remain unlimited. The separate
recently-closed-tab recovery stack remains bounded to 100 entries and is not an
open-tab cap. Macro features remain excluded. README, the ignored Notepad++
checkout, and user-owned doc04/vendor-script changes remain untouched.
