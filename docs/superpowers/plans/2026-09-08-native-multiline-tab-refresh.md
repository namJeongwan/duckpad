# Native Multiline Tabs and Incremental Insertion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use test-driven development for every behavior change and report the observed RED failure before production edits.

**Goal:** Match the documented Windows multiline-tab behavior without truncation or scrolling, and remove whole-view refreshes from normal new-document insertion.

**Architecture:** Keep the pure `TabFlowLayoutEngine` as the single layout authority, add a narrow insertion operation to the AppKit collection-layout cache, route valid insertion changes to only the affected strip, and make same-host Scintilla display idempotent. Invalid deltas retain the safe full-snapshot fallback.

**Tech Stack:** Swift 6, AppKit, Swift Testing, existing Scintilla bridge; no new dependency.

**Spec:** `docs/superpowers/specs/2026-09-08-native-multiline-tab-refresh-design.md`

## Global constraints

- Preserve complete measured tab-title widths; never truncate or shrink them.
- Preserve source order, compact zero-gap chrome, no visible tab-strip control,
  and no horizontal or vertical tab scrolling.
- Keep single-row tabs at natural width; justify only after wrapping occurs.
- Match Windows multiline row balancing for equal-width tabs and preserve full
  titles for variable-width tabs.
- A valid `.tabInserted(index:)` must not call a full collection reload.
- In split mode, insertion updates only the group that gained the tab.
- Keep workspace, group layout, and editor buffer state as existing sources of
  truth; do not introduce a second model.
- One primary component per source file and no new package dependency.
- Do not touch root-worktree user changes.
- Obtain independent zero-finding review before commit and again before push.

## Task 1: Reproduce native multiline row behavior

**Files:**
- Modify `Tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
- Modify `Sources/DuckpadPresentation/TabFlowLayout.swift`

**Behavior:**
- `layout(itemWidths:containerWidth:)` retains natural widths when all items fit.
- For `[100, 100, 100, 100]` at width `399`, produce two balanced rows
  `[0, 0, 1, 1]`; each row ends at `399` and each item stays at least `100`.
- For an already multiline equal-width fixture, row item counts differ by at
  most one and every row ends at the usable trailing edge.
- For variable or oversized widths, never shrink an item; add rows when a
  balanced candidate cannot hold complete titles.

- [x] Add literal behavior tests and run
  `swift test --filter 'rowsUseNativeMultilineBalancing|multilineRowsJustifyWithoutShrinkingTitles'`;
  confirm that the old greedy implementation fails.
- [x] Implement the smallest pure row-range and positive-slack distribution
  change in `TabFlowLayoutEngine`.
- [x] Run `swift test --filter TabFlowLayoutTests` and `git diff --check`.
- [x] Independently review the task diff and resolve every finding.

## Task 2: Insert new tabs without rebuilding the strip

**Files:**
- Modify `Sources/DuckpadPresentation/TabFlowLayout.swift`
- Modify `Sources/DuckpadPresentation/MultilineTabStripView.swift`
- Create `Tests/DuckpadPresentationTests/TabInsertionRefreshTests.swift`

**Interfaces:**
- Add `MultilineTabCollectionLayout.insertItemWidth(_:at:)` with guarded index
  validation and the same cache invalidation semantics as width updates.
- Add an insertion count to `MultilineTabStripView.UpdateMetrics`.
- Accept a delta only when the old IDs equal the new IDs after removing the
  proposed inserted index; otherwise call `apply(tabs:)`.

- [x] Add a hosted test that applies a valid insertion and asserts one item was
  inserted, no full reload occurred, the new ID/order/active selection are
  correct, and both tab scrollers remain disabled; verify RED.
- [x] Add a malformed-delta test that proves the full-snapshot fallback remains.
- [x] Implement the narrow layout-cache and collection insertion path.
- [x] Run `swift test --filter TabInsertionRefreshTests`,
  `swift test --filter TabFlowLayoutTests`, and `git diff --check`.
- [x] Independently review the task diff and resolve every finding.

## Task 3: Keep split groups and native editor views stable

**Files:**
- Modify `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- Modify `Tests/DuckpadPresentationTests/EditorGroupCommandTests.swift`
- Modify `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- Modify `Tests/DuckpadEditorAdapterTests/ScintillaEditorGroupTests.swift`

**Behavior:**
- After group reconciliation, `.tabInserted(index:)` derives the inserted tab's
  group-local index and calls `apply(change:)` only on that strip.
- The other strip receives no reload, insertion, or item update.
- Redisplaying an already displayed buffer in its existing group host leaves
  the same native view attached and preserves editor focus.

- [x] Add a 500-tab split-controller test asserting the focused strip gains one
  incremental insertion while the other strip's metrics remain unchanged;
  verify RED.
- [x] Add a hosted Scintilla group test proving a focused same-buffer redisplay
  does not detach/re-attach the native editor; verify RED through first-responder
  stability or another user-observable attachment effect.
- [x] Implement the smallest controller routing case and adapter idempotence
  guard; keep safe fallbacks for inconsistent snapshots.
- [x] Run `swift test --filter EditorGroupCommandTests`,
  `swift test --filter ScintillaEditorGroupTests`, and `git diff --check`.
- [x] Independently review the task diff and resolve every finding.

## Task 4: Document, verify, review, commit, and push

**Files:**
- Modify `docs/DASHBOARD.md`
- Modify only directly relevant tab behavior documentation discovered with
  `rg -n 'multiline|tab strip|new document|reload' docs`.

- [x] Document the Windows-control behavioral reference, AppKit implementation,
  no-dependency decision, natural single-row sizing, multiline justification,
  and incremental insertion.
- [x] Run focused suites, then `swift test --no-parallel`, `swift build`,
  `swift build -c release`, the existing noninteractive smoke flows with hidden
  launch, and `git diff --check`.
- [x] Inspect both worktree statuses and confirm root-only user changes remain
  untouched.
- [x] Generate exact staged candidate packages and obtain independent
  zero-finding review before committing.
- [x] Commit with Conventional Commit messages, audit each commit, and obtain a
  cumulative zero-finding review before pushing.
- [x] Push code/test `feature/editor-groups-compare` and verify the remote SHA
  equals local `HEAD`.
