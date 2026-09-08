# Duckpad Delivery Dashboard

Last updated: 2026-09-08 (Asia/Seoul)

## Product direction

- Keep Duckpad a lightweight, native macOS scratchpad.
- Prioritize broad language highlighting and everyday editing UX.
- Reuse Scintilla/Lexilla where practical; do not add IDE-scale parsing or background services.
- Macro recording/playback remains intentionally out of scope.

## Current slice

| Item | Status | Evidence / next gate |
| --- | --- | --- |
| Editor groups | Implemented and locally audited | Two window-local groups, separate routed Scintilla hosts, right/down drag Split, move/Option-copy, focus/close commands, and state normalization are committed through `92c5773` |
| Open-document Compare | Implemented and locally audited | Immutable non-activating capture, bounded Myers alignment, shared external-conflict renderer, read-only fixed rows, semantic markers, synchronized vertical and independent horizontal scroll are committed through `04d6d4d` |
| Native command and tab chrome | Implemented, audited, and remote-verified | Compact command buttons open the exact native `NSMenu` immediately below the window-local bar. A single tab row keeps complete natural widths and trailing space. After wrapping begins, contiguous rows are balanced where full-title minima permit and each row distributes only positive slack; tabs never truncate, shrink, or scroll. A valid `tabInserted` event performs one native collection insertion, split mode changes only the receiving strip, and same-buffer/same-host Scintilla redisplay preserves the attached view and focus. Malformed deltas retain the full-snapshot fallback |
| Compact Language menus | Implemented, audited, and remote-verified | The window command bar and status control use the same bounded native `NSMenu`: Auto/Plain Text stay direct, repeated initials become alphabet submenus, singleton initials such as XML/YAML/Zig stay direct, and all 78 definitions retain their original action/ID/state |
| Recursive editor-group focus | Fixed and locally audited | `9ecdd588` rejects an already-focused synchronous Scintilla callback at the transition boundary; Task 9 group-command tests pass 21/21 and independent review reports 0/0/0 |
| Bounded editor-group routing | Fixed and locally audited | `c0a0083` restores the source editor after native tab reparenting and makes normal 500-tab edit/activation/click/clone-focus paths cache-validated O(1), with group-local updates and synchronized pane focus/accessibility |
| Focused and serial validation | Passed | TabFlow 93/93, insertion 5/5, editor-group commands 29/29, Scintilla groups 24/24, and Language editor 56/56 pass. The monolithic serial run completes all 653 tests in 12 suites; Debug and Release builds pass |
| Current-source packaged smoke | Passed | A fresh Universal `x86_64 + arm64` app from `ca97721` passed bundle/resource/XPC/signature verification and hidden Finder/Open With, security-scoped relaunch/save, extension, XPC-isolation, and 50-tab multiline smokes (`6` rows). No smoke process remained |
| Default parallel whole suite | Non-release baseline limitation | Process-global AppKit tests are not treated as parallel-safe. The attributable whole-suite gate is the successful 653-test monolithic serial run; two stale test-window animation lifetimes found during that gate were fixed and verified under `NSZombieEnabled` |
| Reviewed source delivery | Code/test source complete | Commits `0dc85b7` through `ca97721` each have an exact signed review receipt and audit. Cumulative pre-push review reports 0 Critical / 0 Important / 0 Minor, and local/remote `feature/editor-groups-compare` both resolve to `ca97721d8795a647c8677ab339cdfd5b49ff4182` |

The [Phase 33 delivery record](wiki/38-editor-groups-compare-and-native-tabs.md)
is authoritative for the delivered baseline and the completed follow-up state.
Earlier rows below retain historical evidence for already delivered work.

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

- Phase 32 implementation Tasks 1–5, the user-reported stale tab-hover fix, and
  the rejected-closer selection-recovery remediation completed independent
  reviews with 0 Critical, 0 Important, and 0 Minor findings. Audited delivery
  commit `c438a760` was pushed to `feature/block-comment-indentation` and its
  full SHA `c438a760d99768f997ed960cff8d6e4427166041` matched the remote branch.
- The first final-range candidate was rejected with one Important finding:
  rejected direct-closer recovery restored bytes/revision but could restore a
  stale selection. Remediation `2aa8754` snapshots primary and split-pane view
  state when pending direct input opens. RED captured primary `11/11`, reverse
  `2/5`, and focused-secondary `11/11`, each incorrectly restored as `0/0`;
  the fix passes the new/strengthened recovery set 3/3, related lifecycle set
  9/9, and Language split gate 56/56 in both Debug and Release. The repeated
  final-range review then passed 0 Critical / 0 Important / 0 Minor before the
  audited delivery commit was pushed.
- Debug and Release builds exit 0. The requested focused Debug and Release
  filters all exit 0: `LanguageManifestTests`, `LanguageWorkspaceUseCaseTests`,
  `LanguageEditorAdapterTests`, `ScintillaEditorAdapterTests`,
  `TabFlowLayoutTests`, `ExtensionPresentationTests`, and
  `CommandPalettePresentationTests`. Counted summaries are 8/8 manifest, 8/8
  workspace, 66/66 tab flow, 5/5 extension, and 7/7 palette in both
  configurations. The two large adapter filters retain their known truncated
  console stream, so the independently reviewed explicit Phase 32 batches
  (15/15 block comments and the original 18/18 closer/indent tests in Debug and
  Release) remain their complete named proof. The final-review remediation adds
  a separate 3/3 selection-recovery proof; it is not folded into the original
  18/18 count.
- The Release production language smoke exits 0 after real Swift highlighting
  and folding, a UTF-8/CRLF block toggle with exactly one accepted revision and
  exact Undo/Redo, JSON direct-closer one-level dedent with one grouped Undo,
  Python switching, and the dark palette.
- The frozen Release performance gate passes exactly six budgets on a Mac16,7:
  warm launch 289.016 ms, typing p95 0.017792 ms, 100 MiB open 902.360833 ms,
  200-tab reflow p95 0.001875 ms, folder search 263.726791 ms, and 10,000-header
  fold recovery 114.223042 ms. The separate Release 1 MiB block-comment stress
  passes its 250 ms assertion and completes in 0.154 seconds.
- Current `swift test` and `swift test -c release` each exit 1 with SwiftPM
  testing-helper `unexpected signal code 11` after 5.03 and 5.10 seconds. The
  exact commands at design parent `4510f3a` reproduce the same signal and exit
  after 58.61 and 217.42 seconds respectively. No extension-host timeout or new
  Phase 32 assertion failure appeared in these runs; the signal remains a
  process-global AppKit baseline blocker, not a monolithic pass.
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
3. Block comments and further language-aware indentation commands. **Delivered.**
4. Importable, validated user language definitions without native code loading.
5. Lightweight API completion/call-tip provider contract.
6. Remaining high-value document UX and file-integrity gaps.

## Protected existing work

The following user-owned changes predate this slice and must not enter its commit:

- `docs/wiki/04-implementation-foundation.md`
- `scripts/vendor_scintilla_5_6_6.sh`
