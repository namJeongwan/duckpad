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
| Fold recovery implementation | Plan approved; implementation next | `docs/superpowers/plans/2026-09-04-fold-state-recovery.md`; plan review 0 Critical / 0 Important / 0 Minor |
| Keyboard and VoiceOver controls | Designed | Native View submenu, conflict-free shortcuts, menu accessibility, Command Palette discovery |
| Phase 31 validation and review | Pending | Debug/Release, recovery/menu/AppKit, smoke, performance, independent review |
| Phase 31 commit and push | Pending | Exact reviewed candidate only; target `feature/fold-state-recovery` |

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
  user. The executable TDD plan passed independent review; production code and
  tests have not started.
- Debug and Release builds pass.
- Debug and Release `LanguageEditorAdapterTests` pass.
- Debug and Release split-pane smart-pair regression passes.
- The Release production language smoke exits 0 after exercising real Lexilla
  switching and Scintilla editing.
- The frozen Release performance gate passes all five budgets: warm launch
  387.936 ms, typing p95 0.015958 ms, 100 MiB open 1005.766292 ms, 200-tab
  reflow p95 0.0015 ms, and folder search 288.5145 ms.
- Initial independent review findings for split stale state, CR/CRLF, bounded
  paste inspection, IME source tracking, invalid lexer rollback, and validation
  wording are remediated. Final independent re-review approved the exact
  candidate with 0 Critical, 0 Important, and 0 Minor findings.
- Repository-wide `swift test` reproducibly exits with `signal 11` while
  multiple existing AppKit suites run concurrently. When isolated,
  `ScintillaBridgeTests` reaches the existing
  `activationCommittedBeforeReplaceReservationRejectsStaleTargetWithoutMutation`
  failure. Focused Phase 30 runs do not reproduce either failure, but the new
  process-global AppKit event test's contribution to the monolithic crash has
  not been excluded. Both remain visible review inputs and are not reported as
  passing.

## Prioritized roadmap

1. Lightweight language-aware smart editing. **Delivered.**
2. Fold-state recovery and keyboard/VoiceOver folding controls. **Design review.**
3. Block comments and further language-aware indentation commands.
4. Importable, validated user language definitions without native code loading.
5. Lightweight API completion/call-tip provider contract.
6. Remaining high-value document UX and file-integrity gaps.

## Protected existing work

The following user-owned changes predate this slice and must not enter its commit:

- `docs/wiki/04-implementation-foundation.md`
- `scripts/vendor_scintilla_5_6_6.sh`
