# Milestone 01 Independent Review

> Status: **REJECTED — changes required**
> Date: 2026-09-02 (Asia/Seoul)
> Reviewer: `/root/milestone_one_review`
> Review type: independent documentation/architecture/governance review
> Commit authorization: **not granted**

## Review scope

The review covers the complete current contents of:

- `docs/wiki/01-product-philosophy-and-parity.md`
- `docs/wiki/02-clean-architecture-and-plugins.md`
- `docs/wiki/03-development-workflow-and-roadmap.md`

The three source documents were reviewed without modification. The review checks all eight user requirements: fixed scratch-first philosophy, a prominent product emphasis, measurable Notepad++ feature/UX parity of at least 90%, Local Git, independent review before every commit, English commit header/body, Clean Architecture, and sub-agent work/design records in Markdown wiki form. It also checks cross-document consistency, macOS-native adaptation, plugin extensibility and isolation, Notepad++/Scintilla/Lexilla license boundaries, local source references, and whether the Git/review protocol can actually be executed.

This is a full-file review rather than an approval of a staged diff. The Duckpad root was not a Git repository at the start of the review; another task initialized it during this review. At disposition time it is an empty local `main` repository with no commits or remotes and all reviewed files are untracked. Therefore this review cannot supply the exact staged-diff approval required by the proposed workflow.

Out of scope:

- modifying the three reviewed documents
- reviewing application code, because none is in this milestone
- committing or staging any file
- providing legal advice

## Commands and evidence inspected

```sh
git status --short --branch
git remote -v
git log --oneline --decorate -5
git -C notepad-plus-plus rev-parse --short=9 HEAD
git -C notepad-plus-plus status --short
wc -l docs/wiki/0*.md
nl -ba docs/wiki/01-product-philosophy-and-parity.md
nl -ba docs/wiki/02-clean-architecture-and-plugins.md
nl -ba docs/wiki/03-development-workflow-and-roadmap.md
rg -n '<parity, plugin, review, license, architecture, macOS terms>' docs/wiki/0*.md
rg -n '^\| [^|]+ \| P[012] ' docs/wiki/01-product-philosophy-and-parity.md
sed -n '<cited ranges>' notepad-plus-plus/README.md
sed -n '<cited ranges>' notepad-plus-plus/PowerEditor/src/{menuCmdID.h,Parameters.h,NppIO.cpp,Notepad_plus.cpp}
sed -n '<cited ranges>' notepad-plus-plus/PowerEditor/src/ScintillaComponent/{Buffer.h,Buffer.cpp,DocTabView.h,FindReplaceDlg.h,ScintillaEditView.cpp}
sed -n '<cited ranges>' notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/{PluginInterface.h,PluginsManager.h,PluginsManager.cpp}
sed -n '<cited ranges>' notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp
sed -n '<cited ranges>' notepad-plus-plus/scintilla/cocoa/{ScintillaView.h,ScintillaCocoa.h,ScintillaCocoa.mm}
sed -n '1,24p' notepad-plus-plus/{LICENSE,scintilla/License.txt,lexilla/License.txt}
command -v shasum
printf '' | shasum -a 256
```

The reference repository is clean at `dda973d2b`, matching document 01. The reviewed Notepad++, Scintilla, Lexilla, multiline-tab, session/recovery, search, split-view, language, plugin ABI, Cocoa bridge, and license ranges exist and support the material claims. Apple documentation also confirms that `NSCollectionView` supports custom `NSCollectionViewLayout`, while directly launched sandboxed helpers inherit the app sandbox and distinct privilege separation requires a concrete XPC/helper design: [NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview), [Embedding a helper tool](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app), [Diagnosing App Sandbox violations](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations).

## Requirement disposition

| Requirement | Result | Evidence |
| --- | --- | --- |
| 1. Fix the Notepad philosophy and extensible language/plugin direction | Pass | Document 01:8-39 establishes scratch-first, loss-averse, simple-surface/deep-capability, broad-language, plugin, and Mac-first principles. |
| 2. Show the main emphasis prominently | Pass | Document 01:8-12 gives the product promise its own prominent heading and quotation. |
| 3. Port at least 90% of Notepad++ features and UX with macOS optimization | Reject | B-02 and M-01 leave the denominator and scoring algorithm non-authoritative. |
| 4. Use Local Git | Partial | Document 03:22-36 is directionally correct; the root now has a local, remote-free, no-commit repository, but there is no reviewed staged diff or commit evidence yet. |
| 5. Review before every commit | Reject | B-01 makes the prescribed exact-checksum evidence flow self-referential and impossible as written. |
| 6. English commit header and content | Pass as policy | Document 03:38-77 is explicit and gives valid English examples; there are no commits to audit yet. |
| 7. Apply Clean Architecture | Pass with minor correction | Document 02 defines strong inward dependencies and typed ports; m-01 identifies one contradictory diagram in document 03. |
| 8. Use sub-agents and preserve work/design in Markdown wiki | Pass as policy/evidence | All three documents contain agent work logs; document 03:102-163 makes investigator/builder/independent-reviewer wiki evidence mandatory. |

## Findings

### Blocker

`docs/wiki/03-development-workflow-and-roadmap.md:128-143,169-197`: **B-01 — exact staged checksum is self-referential.** The template requires the SHA-256 and approval to be written into a wiki file that is itself included in the exact staged diff, so recording the hash changes the diff and invalidates that same hash. Line 197 recognizes commit-ID self-reference but misses staged-hash self-reference. Define a two-artifact protocol: freeze and hash the candidate staged diff, store the reviewer receipt in a separate unstaged `docs/wiki/reviews/pending/<hash>.md`, commit the unchanged candidate, then bring the prior receipt into a separately reviewed follow-up/attestation commit; alternatively define and tool a canonical hash that explicitly excludes the reviewer-owned receipt and stop calling it the checksum of the entire staged diff. Add a pre-commit verifier and an end-to-end fixture proving approval remains valid through commit.

`docs/wiki/01-product-philosophy-and-parity.md:71-114` and `docs/wiki/03-development-workflow-and-roadmap.md:410-416`: **B-02 — two incompatible 90% formulas are binding.** Document 01 uses ten category weights, equal weight per row inside a category, and quarter-step earned ratios; document 03 instead assigns item weights 5/3/1, permits only Full/Partial/Missing 1/0.5/0, and adds a separately calculated 90% UX pass rate. The same implementation can pass one formula and fail the other. Make document 01 the single normative algorithm, delete the duplicate algorithm from document 03 in favor of a direct link, and provide one versioned machine-readable matrix/calculator with a frozen baseline checksum.

### Major

`docs/wiki/01-product-philosophy-and-parity.md:84-114,135-299,321-330` and `docs/wiki/03-development-workflow-and-roadmap.md:397-420`: **M-01 — the claimed fixed denominator precedes the promised exhaustive inventory.** The 91 rows are coarse bundles and only listed behavior can affect the score, while document 03 postpones the full Notepad++ user-facing command/workflow inventory until Phase 6. Unlisted behaviors therefore disappear from the denominator and 90% can be reached without proving 90% source coverage. Before freezing weights, map every user-visible source command/workflow to a stable item ID and one of Full/Partial/Missing/Reviewed-N/A; require independent N/A rationale, detect unmapped source commands, and derive the 91 workflow rows from that traceable inventory.

`docs/wiki/02-clean-architecture-and-plugins.md:19,196-204,238-263` and `docs/wiki/03-development-workflow-and-roadmap.md:373-387`: **M-02 — plugin capability enforcement has no selected macOS sandbox topology and is weakened to optional isolation in the roadmap.** A broker can deny host APIs, but an arbitrary executable can call filesystem/network/process APIs itself; directly launched sandboxed helpers inherit the parent sandbox rather than the manifest's per-plugin grants. Document 02 correctly acknowledges this gap, but document 03 says out-of-process isolation only “if possible” and its Phase 5 gates do not prove denial of direct OS access. Fix the architecture before freezing SDK v1: select and spike the signing/distribution plus XPC/helper topology, default workers to no direct filesystem/network/process access, route granted effects through brokers, and add direct-syscall denial tests for every capability. Isolation and over-permission enforcement must be MUST-level gates consistent with G9/P0.

`docs/wiki/01-product-philosophy-and-parity.md:24,61,260-276,375` and `docs/wiki/02-clean-architecture-and-plugins.md:247`: **M-03 — required plugin panel capability has no committed v1 contract.** The parity baseline says command/event/editor/language/decorations/**panels** is the retained ability surface and scores panel contribution, while architecture v1 exposes no panel contribution and leaves a web panel as an uncommitted later possibility. Define a host-rendered declarative panel schema and lifecycle/accessibility contract for the 90% release, or explicitly mark the row Missing/Partial and show that the fixed parity calculation still passes without contradicting the “maintain this ability surface” decision.

### Minor

`docs/wiki/03-development-workflow-and-roadmap.md:203-225`: **m-01 — the dependency diagram points Infrastructure/Adapters at Domain while the rules say they implement Application ports.** Replace it with the same inward diagram used in document 02 so builders do not bypass application ports.

`docs/wiki/02-clean-architecture-and-plugins.md:22-43,331-340`: **m-02 — source/license evidence is not pinned or navigable as precisely as document 01.** Add reference commit `dda973d2b`, convert raw path/range text to clickable relative links, and describe Notepad++ as governed by its GPLv3 license text “with the clarifications and exceptions described below” rather than shortening the exact local license terms. Keep the existing no-copy/legal-review boundary.

### Note

`docs/wiki/01-product-philosophy-and-parity.md:8-65` and `docs/wiki/02-clean-architecture-and-plugins.md:7-192`: **N-01 — product philosophy, macOS shell, Scintilla bridge, document/buffer/view separation, recovery invariants, and multiline tab design are mutually aligned and well grounded.** No corrective action beyond preserving these decisions through the fixes above.

`docs/wiki/03-development-workflow-and-roadmap.md:38-124,145-163`: **N-02 — English commit messages, independent reviewer identity, re-review after changes, and per-agent wiki logging satisfy the intended governance once B-01 is repaired.** No commit exists yet, so implementation compliance remains unverified.

## Disposition

**REJECTED.** Two Blockers and three Majors remain open. The three documents must not be treated as an approved milestone or as commit-approved content. Resolve B-01, B-02, M-01, M-02, and M-03, update the affected wiki work logs, and request a new independent full-document review. After content approval, stage the exact intended files and perform a separate checksum-bound pre-commit review under the repaired protocol.

No source document was modified, no file was staged, and no commit was created by this reviewer.

## Agent Work Log

- **Task:** `milestone_one_review`
- **Agent:** `/root/milestone_one_review`
- **Role:** Independent reviewer
- **Goal:** Verify the first three decision/governance wiki documents against the eight user requirements and authoritative local source.
- **Scope:** Full content of documents 01-03; cross-document parity, architecture, plugin, license, macOS, and Git protocol checks.
- **Explicit non-scope:** Source-document edits, staging, commits, and application implementation.
- **Evidence:** Local Duckpad Git state; clean Notepad++ reference commit `dda973d2b`; all cited source families and license files; official Apple AppKit and sandbox/helper documentation.
- **Key decisions:** Reject because the checksum protocol cannot represent its own final staged diff and two normative parity formulas conflict; require a traceable exhaustive inventory and a concrete enforceable plugin sandbox topology.
- **Files changed by reviewer:** `docs/wiki/reviews/2026-09-02-milestone-01-review.md` only.
- **Validation:** Re-read all 1,238 reviewed lines; confirmed 91 inventory rows; verified reference commit and cited source ranges; verified `shasum -a 256` availability; inspected Local Git/no-remote state.
- **Findings:** 2 Blocker, 3 Major, 2 Minor, 2 Note.
- **Decision:** REJECTED; no staged-diff or commit approval.
- **Commit:** None.
