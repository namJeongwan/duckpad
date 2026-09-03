# Phase 22 Document Intelligence — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 22)
- **Date:** 2026-09-03
- **Candidate reviewed:** `9e3f0ecdcf5fa2fa27eddb93a61796172abaa7d3db0a83a93300b3940ce41559`
- **Remediation candidate:** `dc5569bcdf0d96a7ba814a48237a6b73c9ec05e25a0238b485aec92f29d14359`
- **Final content candidate:** `9c4a37f47825797949f0d3ade850a37e9451ca02e9eea3d7f7dcfa32135f09f2`
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Current findings:** 0 Blocker, 0 Major, 0 Minor

## Scope

Reviewed all 14 staged paths for current-document completion, searchable symbol
outline, the narrow Scintilla bridge, production composition, AppKit lifecycle,
tests, the Phase 22 work document, and its wiki index entry against parent
`58d6772499cae06db9d647ee92f056af66e31ae5`.

Explicitly excluded and preserved the unstaged user-owned
`docs/wiki/04-implementation-foundation.md` and untracked
`scripts/vendor_scintilla_5_6_6.sh`. README and ignored Notepad++ material were
not inspected or changed. Product, tests, work documentation, stage, commit,
push, and receipt were not modified.

## Findings

- **P22-01 Major** — `Sources/DuckpadApplication/DocumentIntelligence.swift:120`: completion retains every document/supplemental token in an unbounded `Set`, filters and sorts the full match set before applying the 200-item cap, while symbols eagerly materializes every line with `Data.split` before its 500-item cap; a 3.49 MiB unique-token probe took 5.51 s/48 MB RSS and a 4 MiB two-byte-line probe took 4.76 s/77 MB RSS, violating the bounded/fast analyzer contract despite off-main execution. Stream tokens/lines without whole-input collections, stop symbol parsing at 500, maintain a bounded deterministic top-200 completion set, bound supplemental input, and add adversarial 4 MiB work/memory instrumentation.
- **P22-02 Major** — `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:396`: a completion capture binds only buffer/revision/caret, so after focus moves between two shared-document panes with the same caret, `presentCompletionItems` resolves the newly focused pane and accepts the stale request; an external AppKit probe captured primary, focused secondary, then observed `presented=true`, primary popup false, secondary popup true. Carry an opaque pane/request identity through the Application port and require the same live pane at publication; add same-caret and same-buffer focus-switch tests.
- **P22-03 Minor** — `Sources/DuckpadApplication/DocumentIntelligence.swift:174`: symbol scanning splits only on LF, so a valid CR-only document `func one() {}\rfunc two() {}` returns only `one` on line 1 and misses `two`. Stream CR, LF, and CRLF boundaries while preserving exact UTF-8 offsets and add Unicode range/line tests for every supported EOL.

## Evidence

- Candidate preparation recomputed exactly to
  `9e3f0ecdcf5fa2fa27eddb93a61796172abaa7d3db0a83a93300b3940ce41559`.
  Metadata matched tree `c430a96fe426192677608b7381429a6a87b6cf06`,
  diff SHA-256
  `635d3338d15a742c5dc2fa7cab52ca8234cedaf98e1e0f9bf134b93025a741dd`,
  and message SHA-256
  `c3bae4afcc513c40e6c5d00b538b1f72881c24795df9983de6d0ad0795cc6915`.
- The staged set was exactly the requested 14 paths and
  `git diff --cached --check` passed. No README, Notepad++, gitlink, build, or
  cache path was staged; doc04 and the vendor script remained excluded.
- Independent focused repository tests passed 9/9: Application document
  intelligence 5/5 plus native completion, pre-copy budget/caret binding,
  controller routing/termination cancellation, and symbol search 4/4.
- Independent external probes used the compiled current modules without
  changing repository bytes. They reproduced the bounded-work costs, the
  cross-pane publication, and the CR-only missed symbol described above.
- Builder-provided supporting evidence was inspected but not independently
  rerun in full: exact-current Debug/Release 310/310, release production
  intelligence smoke, parity 31/31, governance 8/8, checker, and diff-check
  were reported PASS.
- The abandoned `cdf0d00d…` candidate was not approved. In this replacement,
  completion comparison is fixed to `en_US_POSIX` and Markdown/INI/JSON forms
  are language-scoped; those two self-reported defects are closed.

## Architecture and Lifecycle

Application owns the analyzer and its editor intent port, Presentation owns the
native popover and task routing, and Scintilla messages remain confined to the
adapter/bridge. Weak editor ownership and weak controller activation captures
avoid a new steady-state retain cycle. Buffer/revision and termination checks
prevent late document mutation, and the native list itself is non-mutating.
In the initial candidate those sound boundaries did not close P22-01: detached
work could still monopolize CPU and transient memory. Buffer-level checks also
did not close P22-02 because split panes deliberately share the same buffer and
revision while retaining distinct selection/focus UI state. The focused result
below supersedes this initial-state analysis.

## Focused Remediation Re-review

- **P22-01 PARTIALLY CLOSED / Major remains** — completion now streams
  256-byte words, retains at most a sorted top 200, and consumes at most
  256 KiB of supplemental text. The exact 3.49 MiB unique-token probe improved
  from 5.51 s/48 MB to 0.58 s/18 MB Debug and 0.23 s/18 MB Release. Symbol
  scanning no longer eagerly allocates all `Data.split` slices, reducing the
  exact 4 MiB two-byte-line probe from 77 MB to 15 MB. However, the no-symbol
  short-line case still constructs and parses about two million transient
  strings and has no cancellation/work checkpoint: it took 4.41 s Debug and
  1.92 s Release on the same host. The initial finding's bounded-memory half is
  closed, but the bounded/fast CPU and lifecycle-cancellation half remains.
  Optimize raw-line classification or impose an explicit inspected-line/work
  budget, check cancellation, and add the exact no-symbol short-line latency
  regression rather than only a fixture that reaches 500 symbols early.
- **P22-02 CLOSED** — capture now carries an Application-owned opaque context
  identity allocated per concrete editor view. Publication validates the
  current view's identity before calling the bridge. The original exact
  same-buffer/revision/caret focus-switch probe now returns `presented=false`
  with neither pane showing a popup.
- **P22-03 CLOSED** — the byte scanner recognizes CR, LF, and CRLF without
  double-counting CRLF. The original CR-only probe now returns `one` at line 1,
  byte 5 and `two` at line 2, byte 19; the mixed-EOL Unicode range regression
  also passes.
- Static and external boundary probes confirm oversized document/supplemental
  words are skipped without partial candidates, scanning resumes after an
  oversized term, input after the aggregate 256 KiB supplemental budget is
  ignored, over-256-byte prefixes produce no candidates, and no analyzed term
  retained by completion exceeds 256 bytes.

Remediation candidate identity recomputed exactly. Its tree is
`6145f6310e9be1cc38cb545436b09610da02eab6`, diff SHA-256 is
`16a8966bc1b7065cc556c46f7a9b9b24d9344f35d11fddefdd77ff4580d846e9`,
and the message SHA-256 remains
`c3bae4afcc513c40e6c5d00b538b1f72881c24795df9983de6d0ad0795cc6915`.
`git diff --cached --check` passed. Independent exact-current focused tests
passed 12/12; builder Debug/Release 313/313, Release intelligence smoke,
parity 31/31, governance 8/8, checker, and diff-check remain supporting
evidence.

## Final Remediation Re-review

- **P22-01 CLOSED** — candidate `36cedcb5…` was abandoned without approval.
  The final raw-byte prefilter skips String allocation for ordinary ASCII
  non-symbol lines, recognizes every byte cue required by `parseSymbol`, and
  checks task cancellation every 1,024 completed lines. The original exact
  4 MiB `a\n` no-symbol probe improved to 0.26 s/15 MB Debug and
  0.04 s/15 MB Release, compared with 4.41 s Debug and 1.92 s Release in the
  partial remediation. Five independent cancelled-task repetitions returned
  after 0.07–0.15 ms. The new repository regression's under-three-second guard
  passed as part of the 1.36-second adversarial test.
- Targeted syntax probes preserved every accepted cue: modifier/type,
  function/property, compact parenthesized function, Markdown heading, INI
  section, JSON property, Unicode identifiers, ASCII space/tab/vertical-tab/
  form-feed token separators, and NBSP/ideographic leading whitespace. VT/FF
  before Markdown/INI/JSON remain rejected by `parseSymbol` itself and are
  therefore not prefilter false negatives.
- P22-02 and P22-03 remained closed. Completion and supplemental term bounds
  remained unchanged and the exact split-pane, CR-only, mixed-EOL, and
  oversized-term probes continued to pass.
- Final candidate preparation recomputed exactly to
  `9c4a37f47825797949f0d3ade850a37e9451ca02e9eea3d7f7dcfa32135f09f2`.
  Metadata matched tree `51c30d5a9cd627885e19d3adc3942dabbacfda9f`,
  diff SHA-256
  `ccb75960869b52916fbdf580acf0f5102e2ff18e7e4932a5ac86f64785b0cf76`,
  and unchanged message SHA-256
  `c3bae4afcc513c40e6c5d00b538b1f72881c24795df9983de6d0ad0795cc6915`.
  Independent final focused tests passed 12/12. Builder-provided final
  supporting evidence was Debug/Release 313/313, Release intelligence smoke,
  parity 31/31, governance 8/8, checker, and diff-check PASS.

## Final Manifest Evidence

Exact 13-path product/test/work-document manifest (wiki index and this review
evidence excluded):

- `Sources/DuckpadApp/DuckpadMain.swift`
- `Sources/DuckpadApplication/DocumentIntelligence.swift`
- `Sources/DuckpadApplication/LanguageService.swift`
- `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- `Sources/DuckpadPresentation/SymbolOutlinePanel.swift`
- `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`
- `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`
- `docs/wiki/25-document-intelligence.md`
- `tests/DuckpadApplicationTests/DocumentIntelligenceTests.swift`
- `tests/DuckpadEditorAdapterTests/LanguageEditorAdapterTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

- Sorted NUL-delimited path digest:
  `86c1cee8c4e4aaa6557b6391bb7a92bcd1fadf957074d2b46e0bc1ab3b75b63f`
- Sorted `path NUL bytes NUL` digest:
  `b554e2e741bd1328c4b159524805341e718d73b47a785f2ddaf3ed0130ddc03e`

Any product/test/work-document byte change invalidates this approval digest
and requires focused re-review.

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P22-01, P22-02,
and P22-03 are closed on the exact 13-path product/test/work-document digest
above. Review/index evidence edits require a newly frozen exact candidate before
receipt creation; this content verdict alone is not a signing receipt.

## Agent Work Log

- Read the complete staged source/test/work-document diff and relevant
  surrounding adapter split ownership, controller termination/teardown, and
  popover lifecycle code.
- Recomputed candidate identity and cached-diff hygiene, ran focused tests, and
  compiled external read-only probes against current build artifacts.
- The `caveman-review` skill shaped findings into concise
  location/problem/fix statements. Only this evidence record and the Phase 22
  index review row/work log were edited.
- Recomputed the remediation candidate, reran all 12 focused tests and the
  original Debug/Release analyzer, split-pane, CR-only, and supplemental-bound
  external probes, then recorded P22-02/P22-03 closure and P22-01's residual.
- Rejected the intermediate `36cedcb5…`, then independently reran the original
  latency/RSS and cancellation probes plus the complete accepted-syntax matrix
  on `9c4a37f…`; updated only this record and the index to final approval.
