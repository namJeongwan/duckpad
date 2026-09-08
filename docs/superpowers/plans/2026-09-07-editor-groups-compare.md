# Editor Groups and Open-Document Compare Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task with a fresh implementer and independent task review.

**Goal:** Add a lightweight two-group tab-drag split workflow and a read-only synchronized Compare command for any two open documents.

**Architecture:** A window-local Presentation model owns group membership and selection. The existing `ScintillaEditorAdapter` routes two group views while retaining one native document/Undo history, edit publisher, and recovery journal. Compare captures immutable open-buffer snapshots in Application and renders a bounded aligned diff in a native AppKit sheet. Durable session and editor-recovery formats remain unchanged.

**Tech Stack:** Swift 6, AppKit, Swift Testing, existing Scintilla 5.6.6 bridge; no new dependency.

**Spec:** `docs/superpowers/specs/2026-09-07-editor-groups-compare-design.md`

## Global constraints

- Support exactly one or two groups; no nesting or third group.
- Normal drag moves; Option-drag clones; edge creation supports right and down.
- Keep one logical tab/document/buffer and one workspace edit acceptance path.
- Preserve current Scintilla same-document Split commands and recovery schema.
- Reject group/internal-split combinations that would create ambiguous four-pane UI.
- Compare is immutable, read-only, bounded, and does not activate its right side.
- Use one primary component/value per source file.
- Do not add a package dependency.
- Do not touch root-worktree user changes in `docs/wiki/04-implementation-foundation.md` or `scripts/vendor_scintilla_5_6_6.sh`.
- Review the exact staged candidate before every commit; do not push until final review reports zero Critical, Important, and Minor findings.

## Task 1: Pure group layout and drag contracts

**Files:**
- Create `Sources/DuckpadApplication/EditorGroupID.swift`
- Create `Sources/DuckpadApplication/EditorGroupSplitOrientation.swift`
- Create `Sources/DuckpadPresentation/EditorGroupLayoutModel.swift`
- Create `Sources/DuckpadPresentation/EditorGroupDragPayload.swift`
- Create `Tests/DuckpadPresentationTests/EditorGroupLayoutModelTests.swift`
- Create `Tests/DuckpadPresentationTests/EditorGroupDragPayloadTests.swift`

**Interfaces:**
- Produce application-owned `EditorGroupID` and `EditorGroupSplitOrientation`.
- Produce Presentation-owned `EditorGroupDropOperation` and `EditorGroupLayoutSnapshot`.
- Produce `EditorGroupLayoutModel.reconcile(workspace:)`, `select(_:in:)`, `split(tabID:source:orientation:operation:)`, `move(_:from:to:)`, and `closeSecondaryGroup()`.
- Produce a versioned local pasteboard payload with strict UUID/group decoding.

- [ ] Write failing layout tests for initial primary membership, right/down move,
  Option clone, last-source rejection, independent selection/focus, insertion,
  close/removal reconciliation, duplicate-copy rejection, moving a cloned
  source reference, empty-group collapse, and secondary close normalization.
- [ ] Run `swift test --filter EditorGroupLayoutModelTests` and verify RED.
- [ ] Implement the minimal pure model and make the tests GREEN.
- [ ] Write failing pasteboard tests for round-trip, bad version/UUID/group, and
  move/copy operation selection; implement and rerun GREEN.
- [ ] Run `swift test --filter EditorGroup` and `git diff --check`.
- [ ] Prepare a task review package; fix all findings through the implementer.
- [ ] Stage exact Task 1 files, obtain a signed zero-finding review receipt, and
  commit `feat: add editor group layout model` without pushing.

## Task 2: Routed Scintilla editor groups

**Files:**
- Create `Sources/DuckpadApplication/EditorGroupRoutingPort.swift`
- Modify `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- Create `Tests/DuckpadEditorAdapterTests/ScintillaEditorGroupTests.swift`

**Interfaces:**
- `EditorGroupRoutingPort` consumes Task 1 application-owned identifiers and
  exposes active group, assignment/reconciliation, `hasVisibleGroups`, group
  focus callback, and split suspension state without importing AppKit.
- `ScintillaEditorAdapter` remains the single editor capability implementation,
  edit publisher, buffer store, and recovery journal owner; its concrete API
  separately exposes stable AppKit primary/secondary hosts to app composition.
- Clone views share one native Scintilla document/Undo history; distinct group
  buffers use distinct native documents and independent view state.

- [ ] Write failing adapter tests for per-group display, install/snapshot/retire,
  group focus, command routing, input state, exact single edit acceptance and
  recovery delta, shared native clone document, alternating clone edits plus
  Undo/Redo/save/recovery, distinct-buffer isolation, reversible internal-split
  suspension for active/inactive/startup/reopened buffers, autosave and
  termination capture during group-only clone and suspended internal split,
  current owner-view state updates with and without a suspended split, absence
  of transient peer state in `secondaryViewState`, and invalidation.
- [ ] Run `swift test --filter ScintillaEditorGroupTests` and verify RED.
- [ ] Add the narrow routing port and extend the existing adapter; make GREEN.
- [ ] Run existing `ScintillaEditorAdapterTests`, `LanguageEditorAdapterTests`,
  `FoldingEditorAdapterTests`, and the new router suite sequentially.
- [ ] Run `swift build` and `git diff --check`.
- [ ] Complete task review/fix loop, signed staged review, and commit
  `feat: route Scintilla across editor groups` without pushing.

## Task 3: Group workspace UI and tab-drop behavior

**Files:**
- Create `Sources/DuckpadPresentation/EditorGroupDropOverlay.swift`
- Create `Sources/DuckpadPresentation/EditorGroupPaneView.swift`
- Create `Sources/DuckpadPresentation/EditorGroupWorkspaceView.swift`
- Modify `Sources/DuckpadPresentation/MultilineTabStripView.swift`
- Create `Tests/DuckpadPresentationTests/EditorGroupWorkspaceViewTests.swift`
- Modify `Tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

**Interfaces:**
- Each pane owns one tab strip above one editor host.
- The workspace view owns the right/down edge overlay and emits typed
  select/reorder/split/move/clone/focus/close actions without touching the workspace.
- `MultilineTabStripView` publishes source group in its drag payload, accepts
  `.copy` under Option, and preserves existing local reorder semantics.

- [ ] Write failing view tests for unsplit/split hierarchy, orientation,
  filtered group tabs, edge hit testing, copy/move validation, overlay cleanup,
  cross-group drop, within-group reorder, and accessibility.
- [ ] Verify RED, implement the smallest AppKit views, then rerun GREEN.
- [ ] Run `swift test --filter EditorGroupWorkspaceViewTests` and
  `swift test --filter TabFlowLayoutTests` sequentially.
- [ ] Run `swift build` and `git diff --check`.
- [ ] Complete task review/fix loop, signed staged review, and commit
  `feat: add tab drag split workspace` without pushing.

## Task 4: Controller, menu, and production composition

**Files:**
- Modify `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- Modify `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- Modify `Sources/DuckpadApp/DuckpadMain.swift`
- Create `Tests/DuckpadPresentationTests/EditorGroupCommandTests.swift`
- Modify `Tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

**Interfaces:**
- Controller reconciles layout on workspace changes, activates the group before
  its selected tab, and assigns buffers through `EditorGroupRoutingPort`.
- Add native/context commands for Move/Clone Right/Down, Focus Other Group,
  Close Editor Group; share validation with drag rules.
- `DuckpadApp` injects the concrete adapter's primary root and stable secondary
  `NSView` host into Presentation separately from the view-free routing port;
  no second editor or document store is constructed.

- [ ] Write failing controller/menu tests for activation order, drop move/clone,
  secondary focus, group close, last-tab rejection, internal split suspension,
  document-switcher/search/file-open/Save-All/close/recovery activation, cloned
  tab ambiguity, command validation, shortcuts/accessibility, and teardown.
- [ ] Verify RED; integrate model/view/router and production composition; GREEN.
- [ ] Run focused presentation, workspace, file routing, recovery, and editor
  adapter suites sequentially; run `swift build` and `git diff --check`.
- [ ] Complete task review/fix loop, signed staged review, and commit
  `feat: integrate editor group commands` without pushing.

## Task 5: Bounded open-document comparison core

**Files:**
- Create `Sources/DuckpadApplication/OpenDocumentComparison.swift`
- Create `Sources/DuckpadApplication/OpenDocumentComparisonUseCase.swift`
- Create `Sources/DuckpadPresentation/AlignedLineDiff.swift`
- Create `Tests/DuckpadApplicationTests/OpenDocumentComparisonUseCaseTests.swift`
- Create `Tests/DuckpadPresentationTests/AlignedLineDiffTests.swift`

**Interfaces:**
- Capture two exact immutable open-buffer snapshots without workspace activation.
- Reuse a 32 MiB-per-side limit; add 50,000-line-per-side, two-million-step,
  and 100,000-row limits with typed same-tab/missing/stale/size/complexity errors.
- Produce compact equal-length aligned rows with left/right line references,
  semantic kind, common-prefix/suffix trimming, bounded Myers work, and a
  replaced-middle fallback that still obeys the row ceiling.

- [ ] Write failing capture/validation tests; verify RED; implement; GREEN.
- [ ] Write failing alignment tests for insert/delete/replace, duplicates, empty
  documents, trailing newline, Unicode, newline-dense input, every ceiling,
  cancellation, and bounded fallback; implement; GREEN.
- [ ] Run both focused suites, `swift build`, and `git diff --check`.
- [ ] Complete task review/fix loop, signed staged review, and commit
  `feat: add bounded document comparison` without pushing.

## Task 6: Native compare picker and synchronized panel

**Files:**
- Create `Sources/DuckpadPresentation/OpenDocumentComparePresenting.swift`
- Create `Sources/DuckpadPresentation/OpenDocumentComparePanel.swift`
- Modify `Sources/DuckpadPresentation/FilePanels.swift`
- Modify `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- Modify `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- Create `Tests/DuckpadPresentationTests/OpenDocumentComparePanelTests.swift`
- Create `Tests/DuckpadPresentationTests/OpenDocumentCompareCommandTests.swift`
- Modify `Tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

**Interfaces:**
- Picker excludes the source and disambiguates duplicate titles with paths.
- Panel renders one flat attributed string per side with batched changed ranges,
  disables wrapping, and mirrors normalized vertical scroll under a reentrancy
  guard; horizontal scroll remains independent.
- External conflict Compare adapts onto the same panel renderer.
- Controller restores focus to the initiating group after dismissal.

- [ ] Write failing picker/panel/menu/controller tests including candidate
  filtering, no-second-tab validation, markers, read-only state, synchronized
  vertical scroll, fixed rows, long unequal lines, resize/end clamping,
  independent horizontal scroll, off-main diff, stale-result suppression,
  external compare reuse, focus, cancellation, failure, accessibility, teardown.
- [ ] Verify RED; implement the minimal native presenter and routing; GREEN.
- [ ] Run focused compare, file, command routing, and presentation suites;
  run `swift build` and `git diff --check`.
- [ ] Complete task review/fix loop, signed staged review, and commit
  `feat: add synchronized open document compare` without pushing.

## Task 7: Documentation, complete validation, and delivery

**Files:**
- Modify `docs/DASHBOARD.md`
- Modify `docs/wiki/01-product-philosophy-and-parity.md`
- Modify `docs/wiki/19-external-file-compare.md`
- Modify or create only task-relevant smoke coverage under `Sources/DuckpadApp/DuckpadMain.swift` and `scripts/` if an existing smoke entry point requires it.

- [ ] Document two-group limits, normal/Option drag, menu alternatives, Compare
  behavior, bounds, recovery non-persistence, and verification evidence.
- [ ] Run sequentially: `swift test`, `swift build -c release`, relevant
  production smoke commands discovered in-repo, and `git diff --check`.
- [ ] Inspect `git status`, staged scope, and root worktree status; prove user
  files remain untouched.
- [ ] Complete task review/fix loop and signed staged review; commit
  `chore: document editor groups and compare` without pushing.
- [ ] Generate one whole-branch review package from the merge base; obtain an
  independent zero-finding final review and address every finding through the
  owning implementer before repeating validation.
- [ ] Verify review receipts/audit, push `feature/editor-groups-compare`, and
  confirm the remote branch SHA equals local HEAD.
