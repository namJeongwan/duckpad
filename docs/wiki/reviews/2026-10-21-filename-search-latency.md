# Progressive filename search

Base: `7c69f75875013dbf322cef0511c640e770391cc7` (0.14.1 update-feed merge).
Worktree: `fix/filename-search-latency`. Release preparation: **0.14.2 (64)**.

## Cause and behavior

Shift Shift / All used bundled `rg --files --null` for discovery, but retained
results until the complete per-query traversal finished. A broad `util` query
matched 4,383 files on a local workspace; verifying their path components and
mapping/ranking them added latency. The input also waited for a 120 ms debounce.

One discovery traversal now emits the first validated match immediately, followed
by snapshots no more often than every 50 ms while new matches arrive. Delivery
retains only the latest pending snapshot and awaits each consumer; it does not
spawn one UI task per update. The normal final result still includes late/deep
matches up to the existing disclosed result/input/time limits. Completion of the
whole directory traversal is not required to select and open a shown result.

Input debounce is 20 ms. Background ranking retains usable rows from the current
scope and exact target set; it immediately removes rows outside a new scope/query.
Result updates preserve the user's current selection, including selections made
after asynchronous ranking started. Old query/scope/dismissal generations and
changed workspace root authorities reject late updates.

Repeated directory package classification is cached only within one pinned root
search (2,048 paths / 256 KiB path keys), with directory stat snapshots checked
before reuse. Directory openat/no-follow/fstat checks still run for every file;
file contents are never read for filename search. New directory identities or
metadata changes force reclassification. Final opening revalidates the file.
Mapping names to UI entries avoids repeated Foundation URL construction.

## Evidence

- Local name discovery observed 378,732 names. Raw rg delivered its first `util`
  match in 28.85 ms and completed discovery in 1,979 ms (separate run).
- Previous debug backend query: 4,383 matches, 7,341 ms before any result returned.
- Progressive debug backend query: first snapshot 14.13 ms, 120 snapshots,
  4,383 complete matches in 6,248 ms. No truncation. These are individual warm
  local measurements, not a guaranteed end-to-end UI or cold-filesystem latency.
- Deterministic gated regression failed before the change: usable results were
  unavailable while the backend completion was held. It passes with streaming.
- Independent review identified stale rows during a >500-entry scope transition
  and selection resetting after asynchronous ranking. Both regressions failed
  before their fixes and pass afterward; the selection test additionally covers
  a query-triggered ranking while the user changes the selection.
- Related search scope, Korean composition notification, filename ranking/design,
  split routing, workspace provider, root access, no-follow, ignore/hidden file
  and bounded-discovery tests are run with this change. No strings or locale
  resources changed. Physical Korean IME, full eight-locale visual inspection,
  Intel hardware and macOS 13 runtime checks are outside this follow-up.

Final validation: **66 related Swift test functions passed** (43 presentation,
20 infrastructure, 3 application). The optional real-directory profiling case
was also executed separately as recorded above. Independent final review has no
remaining Blocker, Major or Minor findings. Native Apple Silicon release-mode
app packaging, bundle/resources/signature verification, Finder/Open With, resize,
sandboxed extension isolation and packaged ripgrep smokes passed. Native save
panel automation was explicitly skipped. This local app uses ad-hoc signing and
is not notarized. These results preceded the authorized 0.14.2 release preparation;
final universal packaging and publication follow the repository release procedure.
