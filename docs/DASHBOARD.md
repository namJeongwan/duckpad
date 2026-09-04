# Duckpad Delivery Dashboard

Last updated: 2026-09-04 (Asia/Seoul)

## Product direction

- Keep Duckpad a lightweight, native macOS scratchpad.
- Prioritize broad language highlighting and everyday editing UX.
- Reuse Scintilla/Lexilla where practical; do not add IDE-scale parsing or background services.
- Macro recording/playback remains intentionally out of scope.

## Current slice

| Item | Status | Evidence / next gate |
| --- | --- | --- |
| Phase 31 fold-state design | Chat design approved | Pane-specific Scintilla state; no parser, background service, or dependency |
| Written Phase 31 specification | User approved | `docs/superpowers/specs/2026-09-04-fold-state-recovery-design.md`; independent review 0 Critical / 0 Important / 0 Minor |
| Fold recovery implementation | Delivered | Independent pane recovery, native focus ownership, accepted-edit invalidation, and terminal teardown reviewed clean |
| Keyboard and VoiceOver controls | Delivered | Native View submenu, conflict-free shortcuts, menu accessibility, Command Palette secondary-pane routing reviewed clean |
| Phase 31 validation and review | Complete | Final independent review 0 Critical / 0 Important / 0 Minor; six Release budgets, focused Debug/Release suites, builds, and production folding smoke pass |
| Phase 31 commit and push | Complete | Audited delivery commit `7eada54` pushed and remote-verified on `feature/fold-state-recovery`; this dashboard is the reviewed closeout follow-up |

## Recently delivered

| Item | Status | Evidence |
| --- | --- | --- |
| Lightweight smart editing design | Complete | Native Scintilla insertion notifications; no parser, LSP, or new dependency |
| Direct-input delimiter pairing | Complete | `{`, `[`, and `(` close atomically; one undo and one recovery revision |
| JSON and Python smart newline | Complete | Current-line indentation, configured tabs/spaces, and aligned JSON closer |
| Real AppKit input path | Complete | Queued key event reaches the Scintilla first responder and produces `{}` |
| Focused validation | Complete | Debug/Release language suite, split-pane regression, builds, and production language smoke pass |
| Repository-wide validation | Known baseline blockers | Monolithic run exits with AppKit `signal 11`; isolated Scintilla suite also has one unrelated replace-reservation failure |
| Independent code review | Approved | Final re-review: 0 Critical / 0 Important / 0 Minor |
| Commit and remote branch push | Complete | `3c718ef` audited and pushed to `origin/feature/smart-editing` |

Deferred from this slice: quote pairing, selection surround, closer skip-over,
and standalone closing-delimiter reindent. Those behaviors require broader key
interception and will be reconsidered only with explicit IME and undo proof.

## Quality gates

1. Add a failing behavior test before each production behavior.
2. Preserve IME composition, UTF-8 boundaries, selection, undo, recovery, and revision accounting.
3. Keep work bounded to the current line and adjacent characters; no full-document parse on keystrokes.
4. Run focused tests, the full Debug suite, the full Release suite, and a production AppKit smoke.
5. Complete an independent code review and re-review every remediation.
6. Commit and push only the exact reviewed candidate.

## Current validation notes

- Phase 31's independently reviewed written specification was approved by the
  user. The executable TDD plan passed independent review. Tasks 1 and 2 are
  complete in `/Users/namjeongwan/app/duckpad/.worktrees/fold-state-recovery`;
  the typed folding façade passed Debug/Release tests and independent review
  after hardening recovery input bounds and numeric validation. Task 3 passed
  its post-commit review after adding pane-specific pending recovery, native
  focus routing, accepted-edit invalidation, terminal teardown, and reentrant
  lifecycle protection. Task 4 delivered the native menu, palette, and
  VoiceOver path; selector validation tests were strengthened with mutation
  proof. Task 5 completed its functional gates and passed final independent
  review with 0 Critical, 0 Important, and 0 Minor findings. The audited
  delivery commit `7eada54` was pushed and verified against the remote branch;
  this dashboard update closes the delivery record.
- Debug and Release builds pass. Debug and Release focused suites pass for
  `FoldRecoveryStateTests` (7 tests), `FoldingEditorAdapterTests` (30 tests),
  `FoldingPresentationTests` (4 tests), and all 21 individually enumerated
  `LanguageEditorAdapterTests`. The aggregate language command exits 0 but
  stops its console stream at the IME test, so it is not the sole proof.
- The Release production language smoke exits 0 after exercising real Lexilla
  Swift highlighting, Collapse/Expand Current with `[1] -> []` capture while
  preserving UTF-8 bytes and revision, Python switching, and the dark palette.
- The frozen Release performance gate passes all six budgets on a Mac16,7:
  warm launch 407.517 ms, typing p95 0.016958 ms, 100 MiB open 1046.987333 ms,
  200-tab reflow p95 0.001583 ms, folder search 277.940125 ms, and exact
  10,000-header contract/capture/shared-pane restore 129.29475 ms against its
  250 ms maximum.
- Phase 30 smart-editing review findings for split stale state, CR/CRLF, bounded
  paste inspection, IME source tracking, invalid lexer rollback, and validation
  wording are remediated. Final independent re-review approved the exact
  candidate with 0 Critical, 0 Important, and 0 Minor findings.
- Repository-wide `swift test` and `swift test -c release` each exit 1 because
  the SwiftPM testing helper receives `signal 11` while process-global AppKit
  suites run concurrently. The same commands at Phase 30 parent `0e511bf`
  reproduce the same signal in Debug and Release. The concurrent
  `bundledSamplePreservesFinalAndMixedEOLAndUTF8ThroughRealHost` timeout seen in
  the Phase 31 Release run also reproduces at that parent in Debug. These are
  baseline blockers, not Phase 31 passes; the focused fold/language suites are
  the attributable green evidence.

## Prioritized roadmap

1. Lightweight language-aware smart editing. **Delivered.**
2. Fold-state recovery and keyboard/VoiceOver folding controls. **Delivered.**
3. Block comments and further language-aware indentation commands.
4. Importable, validated user language definitions without native code loading.
5. Lightweight API completion/call-tip provider contract.
6. Remaining high-value document UX and file-integrity gaps.

## Protected existing work

The following user-owned changes predate this slice and must not enter its commit:

- `docs/wiki/04-implementation-foundation.md`
- `scripts/vendor_scintilla_5_6_6.sh`
