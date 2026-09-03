# Phase 20 Saved Workspace File Browser — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 20)
- **Date:** 2026-09-03
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Final findings:** 0 Blocker, 0 Major, 0 Minor
- **Findings raised during review:** 0 Blocker, 8 Major, 1 Minor; all closed below

## Scope

Reviewed the exact current Phase 20 changes: Domain root identity, Application
browser and prepared file-open boundary, descriptor-backed Infrastructure store,
AppKit sidebar/panel/menu/controller/composition, six acceptance-test files, and
the Phase 20 work document. The mutable wiki index and this reviewer evidence
are excluded from the byte manifest below.

Explicitly excluded and preserved `docs/wiki/04-implementation-foundation.md`,
`scripts/vendor_scintilla_5_6_6.sh`, README, and ignored Notepad++ material. The
reviewer changed only this evidence file and the Phase 20 index row/work log; no
product/test edit, stage, commit, push, or receipt was performed.

## Findings

- **P20-01 Major** — `Sources/DuckpadInfrastructure/LocalWorkspaceRootStore.swift`: validated paths were returned for a later independent read, so a file-to-symlink swap escaped the root; open every component descriptor-relatively with `O_NOFOLLOW`, read/fingerprint the final same descriptor, and pass immutable bytes/identity to file open.
- **P20-02 Major** — `Sources/DuckpadApplication/WorkspaceBrowserUseCase.swift`: concurrent reentrant Add operations captured the same root snapshot and the later publisher lost one durable root; serialize each complete read/store/apply mutation in FIFO order.
- **P20-03 Major** — `Sources/DuckpadInfrastructure/LocalWorkspaceRootStore.swift`: directory enumeration materialized the full directory before enforcing the accepted-entry cap and did not propagate cancellation; count raw dirents before filtering, cap at limit+1, and scan off-main with cancellation.
- **P20-04 Major** — `Sources/DuckpadPresentation/DuckpadWindowController.swift`: pending panels/browser tasks could retain a closed window or indefinitely delay termination; use weak window/UI ownership, cancel native panels, and detach only cancellation-safe pre-mutation operations.
- **P20-05 Major** — `Sources/DuckpadInfrastructure/LocalWorkspaceRootStore.swift`: restored security-scoped URLs were inspected before access acquisition and failed access could still publish an available root; acquire before canonicalize/stat, fail closed when sandbox access is required, and stop the exact acquired URL on every rollback/remove/deinit path.
- **P20-06 Minor** — `Sources/DuckpadPresentation/DuckpadWindowController.swift`: Add/drop commands remained callable while bookmark restore was loading and then silently no-op'd; bind menu, drag, sidebar, and direct-action admission to browser readiness.
- **P20-07 Major** — `Sources/DuckpadApplication/WorkspaceBrowserUseCase.swift`: a cancellation-ignoring durable mutation published after close/termination cancellation; bind every store continuation to a command epoch and reconcile durable state only after a denied termination resumes authority.
- **P20-08 Major** — `Sources/DuckpadPresentation/DuckpadWindowController.swift`: cancellation detached a workspace file open while its session commit could still succeed after final recovery flush; promote a descriptor read to a synchronously registered accepted-open task and join it before dirty review/final flush.
- **P20-09 Major** — `Sources/DuckpadApplication/WorkspaceBrowserUseCase.swift`: resume without an invalidated mutation fabricated `.ready([])` from a corrupt startup failure; every suspended resume must reload/reconcile and preserve typed failure.

## Remediation Re-review

- **P20-01 CLOSED** — root device/inode is pinned; directory components and the
  final regular file use `openat`/`O_NOFOLLOW`; bytes, stat snapshot, and SHA-256
  identity come from one bounded descriptor. `FileDocumentUseCase` consumes
  `WorkspaceFileRead` without a second path/store read.
- **P20-02 CLOSED** — start/add/remove/navigation share one FIFO mutation gate.
  A controlled reentrant Add and the independent reordered store probe both
  retain durable and published roots A+B.
- **P20-03 CLOSED** — `readdir` counts every non-dot raw name before filtering,
  rejects entry limit+1, checks cancellation during the detached scan, and the
  archive reader is likewise no-follow, bounded, and before/after-stat stable.
- **P20-04 CLOSED** — workspace panels receive a weak window reference; native
  sheets are explicitly cancellable; canceled pre-mutation tasks retain no UI.
  Direct close suspends browser authority, and the cancellation-ignoring panel
  termination/deallocation regression releases controller and window.
- **P20-05 CLOSED** — injected order evidence is exactly start → inspect → stop;
  required access failure never inspects or marks the root available. Scope
  ownership rolls back on failure/duplicate/persist and ends on remove/deinit.
- **P20-06 CLOSED** — `acceptsCommands` gates menu validation, direct actions,
  drag/drop, and sidebar interaction until root restore reaches ready.
- **P20-07 CLOSED** — suspension advances the epoch before task cancellation;
  post-await publication validates epoch/cancellation, and denied termination
  reloads durable roots through the serialized reconciliation path.
- **P20-08 CLOSED** — descriptor reads remain cancellable/detachable, but an
  accepted file-open task is registered synchronously, is not canceled by the
  browser teardown, and is joined before final recovery flush. The blocked
  commit regression proves the recovered session includes the opened tab/text.
- **P20-09 CLOSED** — suspension always requires reconciliation; resume is valid
  only from suspended state and always reloads. Corrupt startup remains typed
  failed with command admission disabled after termination denial.

## Reproduction and Evidence

- Initial external probes reproduced stale concurrent publication
  (`stored=2, published=["A"]`), post-validation symlink escape
  (`resolved-after-swap=secret`), canceled late root publication
  (`cancelled add published=["late"]`), canceled file commit still opening a
  second tab, and corrupt failure becoming `ready([])` after resume.
- Current external probe returns published A+B, rejects the final symlink,
  suppresses the canceled root publication, refuses post-close panel routing,
  and keeps corrupt start failed/disabled after resume. Direct FileDocument
  cancellation remains commit-atomic by design; the production controller now
  joins that accepted commit rather than detaching it.
- Independent exact-current focused tests: WorkspaceBrowser 6/6,
  LocalWorkspaceRootStore 7/7, accepted workspace-file termination 1/1,
  cancellation-ignoring panel lifecycle 1/1, delayed browser admission 1/1,
  and prepared descriptor open 1/1 — **17/17 PASS**.
- Builder-provided current-byte supporting evidence: Debug 288/288, Release
  288/288, production workspace smoke, parity 31/31, governance 8/8, and checker
  exit 0 all PASS.
- `git diff --check`: PASS; Git index remained untouched during content review.

## Architecture and Invariants

- Domain contains only `WorkspaceRootID`; Application owns models/state/ports;
  Infrastructure owns bookmark/POSIX/CryptoKit details; Presentation owns AppKit
  views, panels, menus, and lifecycle routing. No inward dependency violation
  was found.
- Blocking filesystem work runs outside MainActor. Root identity, no-follow
  traversal, raw-entry/archive/file caps, cancellation, and stable same-fd
  snapshots bound the untrusted filesystem surface.
- Browser mutation authority, accepted document mutation, termination review,
  and final recovery flush now have explicit ordering. Lazy per-root outline
  loading and revisioned navigation do not introduce a second document authority.

## Manifest Evidence

The exact current 16-path product/test/work-document manifest is:

- `Sources/DuckpadApp/DuckpadMain.swift`
- `Sources/DuckpadApplication/FileDocumentUseCase.swift`
- `Sources/DuckpadApplication/WorkspaceBrowserUseCase.swift`
- `Sources/DuckpadDomain/Identifiers.swift`
- `Sources/DuckpadInfrastructure/LocalWorkspaceRootStore.swift`
- `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- `Sources/DuckpadPresentation/FilePanels.swift`
- `Sources/DuckpadPresentation/WorkspaceSidebarView.swift`
- `docs/wiki/23-workspace-file-browser.md`
- `tests/DuckpadApplicationTests/FileDocumentUseCaseTests.swift`
- `tests/DuckpadApplicationTests/WorkspaceBrowserUseCaseTests.swift`
- `tests/DuckpadInfrastructureTests/LocalWorkspaceRootStoreTests.swift`
- `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
- `tests/DuckpadPresentationTests/WorkspaceSidebarPresentationTests.swift`

- Sorted NUL-delimited path digest:
  `29692564f4202a2ffdb8cc605d654ce4d18435ac987bea8eff57837eab829901`
- Sorted `path NUL bytes NUL` digest:
  `3c236328361bdeab3e830e5df2fca6060ed4e9c1564adf3f1aabd256f645db4b`

Any later product/test/work-document byte change invalidates this review digest
and requires focused re-review.

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 20 content may
be frozen for exact staged-candidate review. This verdict is not a receipt.

## Agent Work Log

- Read the complete scoped diff and surrounding file-open, session commit,
  termination, panel, outline, bookmark, POSIX traversal, and persistence paths.
- Ran focused repository gates and an external adversarial package across each
  remediation freeze, then recomputed the exact final manifest.
- The `caveman-review` skill shaped findings as concise
  location/problem/fix lines. Only this review record and the wiki index Phase
  20 review row/work log were changed.
