# Phase 25B Native Document Lifecycle — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 25B)
- **Date:** 2026-09-03
- **Candidate:** `6c1d7886c8d96ccae7840539f2d125479877dd0f57ef13497bfd033f2084af0f`
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Initial findings:** 0 Blocker, 2 Major, 1 Minor
- **Current findings:** 0 Blocker, 0 Major, 0 Minor

## Scope

Reviewed the exact ten staged paths for Finder/Open With and drag/drop batch
open, native recent documents, Save Copy, Save All, menu shortcuts, tests, and
Phase 25B acceptance evidence. The review covered startup/termination
admission, ordered batch execution and replies, canonical-path and destination
TOCTOU behavior, stable tab/revision authority, dirty/binding preservation,
original-tab restoration, recent-menu targets, shortcut collisions, and the
surrounding file-operation serialization.

User-owned `docs/wiki/04-implementation-foundation.md` and untracked
`scripts/vendor_scintilla_5_6_6.sh` remained excluded. README, ignored
Notepad++, source/product/test/work-document bytes, index staging, receipt,
commit, and push were not modified by this review.

## Findings

- **P25B-01 Major** — `Sources/DuckpadApplication/FileDocumentUseCase.swift:281-308`, `Sources/DuckpadPresentation/DuckpadWindowController.swift:1659-1673`: Save Copy converts panel consent into unconditional `expectedIdentity: nil, overwrite: true`; a destination replaced after the panel returns is silently overwritten, and its failure retry closure is empty. Capture the consented destination identity/nonexistence, commit with that exact expectation, surface a typed conflict, and retain an identity-bound actionable retry that cannot overwrite a later replacement.
- **P25B-02 Major** — `Sources/DuckpadPresentation/DuckpadWindowController.swift:1363-1400`, `Sources/DuckpadApplication/FileDocumentUseCase.swift:523-534`: each external request gets its own task while the use case serializes only individual files, so concurrent accepted batches interleave (`A1, B1, A2`) and can complete/reply out of request order. Add a controller/application-level FIFO batch gate covering the whole request through completion/reply, and test concurrent startup/Finder/drop batches plus termination joining.
- **P25B-03 Minor** — `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift:322-339`: duplicate recent filenames are qualified by only one parent component, so `/a/foo/shared.txt` and `/b/foo/shared.txt` still render identical labels. Compute the shortest unique path suffix (falling back to full path) and add same-parent-name coverage.

## Evidence

- Candidate preparation independently recomputed exactly to
  `6c1d7886c8d96ccae7840539f2d125479877dd0f57ef13497bfd033f2084af0f`.
  Parent is `aa2e52396a29049a9deba8647b41abaea6d788a1`, tree is
  `5af93922894375b24de23659e43e42d975c481f1`, diff SHA-256 is
  `07f1a0e2595870d7e62ef129554f44c2b489402200c23d96aecec0dfa980cab9`,
  and message SHA-256 is
  `fff378d31e6752d40446676477c14c1f189d375b494ec2cf9574f8ef54017035`.
- `git diff --cached --check` passed. The exact stage contained ten intended
  paths; excluded user files remained unstaged/untracked.
- Independent current-byte focused tests passed 4/4: Save Copy snapshot and
  format preservation, ordered single external batch/recent publication, Save
  All dirty-set/original-tab restoration, and Open Recent application target.
- An isolated copy of the exact staged tree added a cancellation-ignoring
  destination race. After the destination changed from `consented old` to
  `external replacement` while Save Copy was blocked, the operation returned
  `.saved` and replaced the external bytes; both preservation assertions failed.
- A second isolated probe blocked `A1`, admitted batch `B1`, then released it.
  The observed recent/open order was exactly `A1, B1, A2`, not the accepted
  request order `A1, A2, B1`; the ordering assertion failed deterministically.
- Apple's `application(_:openFiles:)` contract describes it as the multi-file
  equivalent of `application(_:openFile:)` and requires one
  `reply(toOpenOrPrint:)` on completion. The candidate implements that callback
  and its explicit Open Recent target routes into the same batch opener, so the
  absence of the single-file delegate method is not itself a finding. See
  [Apple NSApplicationDelegate application(_:openFiles:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfiles%3A%29).
- Builder Debug/Release 344/344, parity 31/31, governance 8/8, and expected
  structural-checker release=false are supporting evidence only; they do not
  exercise either adversarial race.

## Verdict

**CHANGES REQUIRED — 0 Blocker, 2 Major, 1 Minor.** P25B-01 and P25B-02 block
content approval and receipt authorization. This review/index evidence also
invalidates candidate `6c1d7886…`; remediation needs a newly frozen candidate.

## Agent Work Log

- Recomputed candidate/tree/diff/message, inspected all staged hunks and
  surrounding file-operation, termination, panel, recent-menu, and task
  ownership paths, and checked cached whitespace/exclusions.
- Ran independent focused 4/4 plus two isolated exact-tree adversarial probes;
  both race probes failed with the concrete outcomes recorded above.
- Used `caveman-review` form so every finding is one concise
  location/problem/fix statement.
- Modified only this review record and the wiki-index review evidence; no
  product/source/test/work-document or staged bytes were changed.

## Focused Remediation Re-review

- **P25B-01 PARTIALLY CLOSED / Major remains** —
  `Sources/DuckpadApplication/FileDocumentUseCase.swift:285-331` now observes
  the canonical destination identity and commits through exact expected-identity
  swap or exclusive create. The replacement-race regression proves later bytes
  are preserved and the operation returns a typed store conflict. However,
  `Sources/DuckpadPresentation/DuckpadWindowController.swift:1666-1679` still
  passes `{}` as `resolve`'s retry closure. The native failure alert therefore
  displays an actionable-looking Retry button that performs no operation. Start
  a newly admitted Save Copy panel/identity-observation cycle from that retry;
  never reuse the stale consented identity blindly, and add a click-retry test.
- **P25B-02 CLOSED** — `FileDocumentUseCase.open([URL])` holds the existing FIFO
  operation admission across the complete array and calls a non-reacquiring
  primitive for each URL. The concurrent blocked-read test now proves request A
  remains contiguous before request B and both tasks complete in FIFO order.
- **P25B-03 CLOSED** — recent URLs are eagerly standardized/deduplicated and
  labels expand to the minimum parent suffix unique among filename peers, with
  a full-parent fallback. The regression covers equal immediate parent names.
- Remediation candidate preparation recomputed exactly to
  `58c995381fb3dd4543713c2b38b3decebc583ff5c7f2cff75bfa407b7516b3a6`;
  `git diff --cached --check` passed and excluded user paths remain outside the
  exact 12-path stage.
- Independent focused remediation tests passed 6/6: copy format/state,
  replacement preservation/conflict, single and concurrent batch ordering,
  Save All restoration, and unique Recent labels. Static dispatch inspection,
  not a flaky timing observation, establishes the remaining no-op retry.
- Builder Debug/Release 346/346, parity 31/31, governance 8/8, and expected
  structural-checker release=false remain supporting evidence only.

## Current Verdict

**CHANGES REQUIRED — 0 Blocker, 1 Major, 0 Minor.** P25B-02 and P25B-03 are
closed, and P25B-01's overwrite/data-preservation portion is closed. The
visible but inert Save Copy retry leaves P25B-01 open, so candidate `58c995…`
is not authorized for receipt. These review/index edits require another exact
refreeze after remediation.

### Re-review Work Log

- Recomputed the remediation candidate and cached-diff boundary; inspected the
  new store identity contract, batch-wide admission, minimum-unique-suffix
  algorithm, tests, and Presentation failure dispatch.
- Ran independent focused 6/6 and updated only this review record and the wiki
  review evidence; product/source/tests/work docs/stage remain unchanged.

## Final Residual Re-review

- **P25B-01 CLOSED** — `DuckpadWindowController.routeSaveCopyAs` now supplies
  `resolve` with a real retry that synchronously registers a new accepted file
  task and calls `routeSaveCopyAs(expectedContext:)` from its beginning. The
  fresh route presents a second native panel and `FileDocumentUseCase.saveCopy`
  observes that newly selected destination's current identity; it neither
  reuses the raced URL nor stale consent/identity. Weak captures, current
  context guards, window teardown guards, and termination task joining remain
  intact.
- The new regression blocks the first write, replaces its destination, verifies
  conflict presentation and external-byte preservation, changes the panel URL,
  invokes the presented Retry, and proves a second panel request plus successful
  copy to the new destination while the source stays unbound and dirty.
- **P25B-02/P25B-03 remain CLOSED** — batch-wide FIFO admission and minimum
  unique Recent suffix code/tests are unchanged from the preceding re-review.
- Final-remediation candidate preparation recomputed exactly to
  `3d3d6b1aa9ec33532e1a2c83f39edbb466f6db45fba8fcb31b7ab5a8ca3381ae`.
  Parent is `aa2e52396a29049a9deba8647b41abaea6d788a1`, tree is
  `05aa394abe997953a81bae3f5821aedc24e013dc`, diff SHA-256 is
  `b100a8bcb2cfed3c89a4890f8388b7832d0731b3a5815549c9f9e9a81846d02a`,
  and message SHA-256 remains
  `fff378d31e6752d40446676477c14c1f189d375b494ec2cf9574f8ef54017035`.
  Cached diff check and the 12-path exclusion boundary passed.
- Independent exact-current focused validation passed 7/7: the new routed
  retry, destination replacement preservation, copy state/format, single and
  concurrent external batches, Save All restoration, and unique Recent labels.
  Builder Debug/Release 347/347 are supporting evidence.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P25B-01 through
P25B-03 are closed and the content is approvable for exact-candidate refreeze.
These final review/index edits invalidate candidate `3d3d6b1a…`; receipt review
must use the newly frozen identity after the evidence is staged.

### Final Re-review Work Log

- Recomputed the exact candidate and inspected the new retry registration,
  panel/context lifecycle, fresh destination identity cycle, test body, and all
  retained remediation paths.
- Ran independent focused 7/7 and changed only this review record and wiki-index
  evidence; product/source/tests/work docs/stage/receipt/commit/push remain
  untouched.
