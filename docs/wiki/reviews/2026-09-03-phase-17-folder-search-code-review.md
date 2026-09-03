# Phase 17 Folder Search — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 17)
- **Date:** 2026-09-03
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Final findings:** 0 Blocker, 0 Major, 0 Minor
- **Initial findings:** 0 Blocker, 5 Major, 2 Minor; all closed below

## Scope

Reviewed the intended 18-path Phase 17 slice: App composition; Domain search
models; Application folder-search, file-activation, and editor-selection ports;
the descriptor-backed local folder adapter; native menu/window/panel/results and
fallback-editor wiring; six acceptance-test files; the Phase 17 work document;
and the wiki index.

Explicitly excluded and preserved `docs/wiki/04-implementation-foundation.md`,
`scripts/vendor_scintilla_5_6_6.sh`, README, and ignored Notepad++ material. The
reviewer changed only this evidence file and the Phase 17 row/work log in the
wiki index; no product/test edit, stage, commit, or push was performed.

## Initial Findings

- **P17-01 Major** — `Sources/DuckpadInfrastructure/LocalFolderSearchFileStore.swift:72`: path metadata was checked before path-based mapped reads, allowing file/directory symlink swaps and file growth to cross containment or byte caps; traverse/read with directory-relative descriptors, `O_NOFOLLOW`, bounded chunks, and before/after `fstat` identity from the same descriptor.
- **P17-02 Major** — `Sources/DuckpadApplication/FolderSearchUseCase.swift:71`: regex compilation occurred only inside each decoded file scan, so invalid regex returned empty success for empty/all-skipped folders; validate once through the bounded regex port before enumeration.
- **P17-03 Major** — `Sources/DuckpadApplication/FolderSearchUseCase.swift:119`, `Sources/DuckpadDomain/SearchModels.swift:139`, `Sources/DuckpadPresentation/SearchPanelView.swift:168`: the result cap omitted per-match duplicated paths/identity and the UI eagerly copied every row on MainActor; share document metadata, charge every retained field with overflow-safe arithmetic, and virtualize folder rows.
- **P17-04 Major** — `Sources/DuckpadInfrastructure/LocalFolderSearchFileStore.swift:166`: each directory was fully accumulated and sorted without an entry/name-byte bound or cancellation inside `readdir`; enforce aggregate metadata caps and poll cancellation during listing.
- **P17-05 Major** — `Sources/DuckpadPresentation/DuckpadWindowController.swift:1377`: result activation was an untracked search task, so cancellation or termination could finish recovery flush before a delayed file read installed a tab; register the accepted activation, cancel and join it before dirty review/final flush, and make file open observe cancellation before mutation. The first cleanup revision also removed the token from a second Task, permitting a completed-task MainActor livelock; remove it in the activation Task's own `defer`.
- **p17-01 Minor** — `Sources/DuckpadInfrastructure/LocalFolderSearchFileStore.swift:135`: concatenating `root.path + "/"` produced `//name` for `/`, making later canonical identity checks stale; use a root-aware join.
- **p17-02 Minor** — `Sources/DuckpadInfrastructure/LocalFolderSearchFileStore.swift:92`: dot-name/short-extension-only filtering missed Finder-hidden entries and recognized packages; inspect descriptor flags and retain fail-closed package classification.

## Remediation Re-review

- **P17-01 CLOSED** — traversal is anchored at an opened root descriptor and uses
  `openat` with `O_NOFOLLOW | O_CLOEXEC`; only same-descriptor regular files are
  read in 64 KiB bounded chunks. Pre/post device, inode, size, mtime, and ctime
  equality plus a final root identity check reject swaps and concurrent writes.
- **P17-02 CLOSED** — ICU prevalidation now occurs before enumeration and returns
  typed `invalidRegularExpression` even when no candidate can be scanned.
- **P17-03 CLOSED** — matches contain only range/line/column/snippet, while path
  and identity are shared once per document. Root/document/match metadata is
  charged with saturated addition, and the AppKit table stores only document row
  offsets and resolves visible rows by binary search instead of flattening all
  strings on MainActor.
- **P17-04 CLOSED** — directory enumeration has process-wide 1,000,000-entry and
  32 MiB name-byte ceilings, reports truncation, and checks cancellation on each
  `readdir`; test-only low limits and a blocking callback exercise both paths.
- **P17-05 CLOSED** — accepted activation Tasks are registered synchronously,
  remove themselves in their own `defer`, and are canceled then joined by the
  shared termination admission before dirty review and final recovery flush.
  File open checks cancellation after serialized admission, canonicalization,
  read/decode, and immediately before workspace mutation.
- **p17-01/p17-02 CLOSED** — root-aware joining produces `/name`; `UF_HIDDEN`,
  known bundle extensions, and Foundation package metadata restore the promised
  exclusion behavior.

## Validation

- External pre-remediation package probe: invalid regex `(` against an empty
  enumeration incorrectly returned `SUCCESS matches=0`; current-byte tests now
  reject empty and all-undecodable enumerations before scanning.
- Independent current-byte focused run: 22/22 PASS. Coverage includes recursive
  deterministic traversal, file/directory symlink swaps, growing-file cap,
  directory metadata/cancellation caps, strict UTF-8/UTF-16 decode, regex
  prevalidation, retained metadata truncation, global caps, user cancellation,
  dirty/changed identity activation, routed UTF-8 selection, Cmd-Q blocking-read
  join, red-close after Cancel, and five immediate queued-activation termination
  iterations.
- Independent current-byte full Debug suite: 254/254 PASS.
- Builder-provided exact-current supporting evidence: Debug 254/254 and Release
  254/254 PASS; parity 31/31, review-gate 8/8, parity checker exit 0, and diff
  checks PASS. These remain clearly separated from the independent runs above.
- `git diff --check`: PASS.

## Architecture and Invariants

- Domain owns value-only search result/failure models. Application owns the
  filesystem and selection ports, strict text decoding, and orchestration.
  Infrastructure owns Darwin, security-scope, descriptors, hashing, raw bytes,
  and blocking work. Presentation owns AppKit panels, menu routing, lazy table
  rendering, focus, status, and accessibility; dependency direction remains inward.
- Search and enumeration execute off MainActor with explicit file/input/match,
  regex, result, entry, and name-byte limits. Cancellation reaches listing,
  bounded reads, scanning, UI operation identity, and termination joining.
- Activation opens only the exact document-level path/identity, requires a clean
  buffer and exact workspace/editor revision, validates the UTF-8 range, and
  never replaces dirty bytes. Failure/stale results do not move selection.
- `Command-Shift-F` is unique in the complete menu fixture. Native folder choice,
  panel status, row labels, Return/double-click routing, and fallback UTF-8 to
  Cocoa selection conversion are explicit and accessibility-labelled.

## Manifest Evidence

The stable 17-path product/test/work-doc manifest excludes the reviewer-owned
mutable index and this evidence file.

- Sorted NUL-delimited path digest:
  `3fe95b4649f6195289cacc64569fdbd14c2907c066c89f87ee66667c8701ab40`
- Sorted `path NUL bytes NUL` digest:
  `71ad4a98cdb962406387fe3ce321271f2ede20e290d3dd4c7866a10cea46a3e4`
- Exact 18-path product/test/work-doc path digest including the final wiki index:
  `062c3db7986f6c7bd27a11391c10983bdd5849d3e2cee48eea924fd56d5e3437`
- Exact 18-path `path NUL bytes NUL` digest including the final wiki index:
  `a56ac0e6c45ae45698e4c24aeaca91f1f7ca285a7c57db2b29739b282d6a78ed`

The earlier transient 18-path values `f9e2e041...191d3` and
`1fc490b2...17cf4` were respectively computed before the reviewer's final index
validation-line edit and before the builder's two doc20 status corrections.
Neither identifies the current bytes; the digest above is the sole final value.

## Final Documentation Consistency Check

- Builder changed only doc20's status and Validation evidence lines: both now
  truthfully say content approved with 0 Blocker/Major/Minor and exact receipt
  pending. Scoped source/test bytes did not change.
- The independent 22/22 focused and 254/254 Debug results, builder 254/254
  Debug/Release results, findings closure, and final verdict remain applicable.
- `git diff --check`: PASS after the doc-only correction.

Git index remained empty during content review. Exact staged-candidate review and
canonical signed receipt remain pending.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 17 product
content may be frozen for exact staged-candidate review. This verdict is not a
receipt and does not approve any later byte change.

## Agent Work Log

- Inspected all intended Phase 17 diffs and surrounding file-open, recovery,
  termination, editor-selection, regex, and AppKit result-routing contracts.
- Reproduced the empty-folder invalid-regex defect externally; reviewed P17-01
  through P17-05 remediation and independently ran the final 22-test focused set.
- The `caveman-review` skill shaped findings as concise
  location/problem/fix lines. Only this review evidence and the wiki index Phase
  17 review row/work log were modified by the reviewer.
