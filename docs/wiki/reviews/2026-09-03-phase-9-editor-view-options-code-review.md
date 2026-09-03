# Phase 9 editor view-options independent code review

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Exact staged-candidate receipt remains pending.

## Scope

Reviewed exactly the current Phase 9 changes in:

- `Sources/DuckpadApplication/Ports.swift`
- `Sources/DuckpadApplication/RecoveryPorts.swift`
- `Sources/DuckpadApplication/SessionRecoveryUseCase.swift`
- `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- `Sources/DuckpadPresentation/TextViewEditorAdapter.swift`
- `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`
- `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`
- `tests/DuckpadApplicationTests/SessionRecoveryUseCaseTests.swift`
- `tests/DuckpadEditorAdapterTests/ScintillaEditorAdapterTests.swift`
- `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
- `docs/wiki/00-wiki-index.md`
- `docs/wiki/12-editor-view-options.md`

The pre-existing `docs/wiki/04-implementation-foundation.md` and untracked `scripts/vendor_scintilla_5_6_6.sh` were excluded and preserved. README and the ignored Notepad++ reference were not accessed. Reviewed product/source/test files were not edited, staged, signed, or committed.

## Evidence

- Clean Architecture direction is preserved: Application owns `EditorViewOptionsPort` and recovery values; Presentation routes native menu intent/capability; the Scintilla/AppKit adapters own engine-specific flags and layout.
- `wrapMarkerVisible` is an additive recovery field with an explicit legacy default of `false`; current encoding writes all fields. Local recovery validation still checks bounded UTF-8 view coordinates before exposing an archive.
- The Scintilla bridge maps word wrap to `SCI_SETWRAPMODE(SC_WRAP_WORD/SC_WRAP_NONE)` and markers to `SCI_SETWRAPVISUALFLAGS(SC_WRAPVISUALFLAG_START | SC_WRAPVISUALFLAG_END/SC_WRAPVISUALFLAG_NONE)`, matching the vendored 5.6.6 headers. State is captured/restored per buffer.
- The fallback editor stores word wrap per buffer, switches text-container width tracking and horizontal scrolling coherently, and advertises marker rendering as unsupported so native validation disables that action.
- View actions do not enter the document-edit callback. Scintilla revision and recovery bytes remain unchanged across toggles; bridge messages do not create text/undo operations. Recovery receives a separate debounced state-change signal, including a serial retry when a durable write overlaps another state change.
- The close-test hardening awaits the exact close task, drains the preceding persistence transaction before the new edit, asserts immediate revision/text acceptance, then verifies Retry saves the latest revision. Independent repetition passed **10/10**.
- Independent focused Phase 9 tests passed **7/7**. Independent full debug and release suites passed **188/188** each. Production Scintilla tab smoke passed with 50 tabs across 8 rows and exit 0. Builder-reported fresh-scratch 188/188 and macOS 13 x86_64 release build were treated as supporting evidence.

## Findings

- `Sources/DuckpadPresentation/DuckpadWindowController.swift:L460-L488` — **Minor P9-01:** View items remain enabled while workspace startup is restoring/failed and during termination review; a delayed restore can overwrite a provisional-buffer toggle that `editorViewStateDidChange()` intentionally ignores. Require `.ready`, an active buffer, and no termination review in both validation and actions so enabled commands are always durable/actionable.

## Notes

- P9-01 cannot mutate document text and does not affect normal ready-state operation, so it does not block this content approval.
- The generic graceful-termination smoke is unsuitable in this headless runner; the established forced-exit production-composition smoke passed. This is not attributed to the Phase 9 diff.

## Agent Work Log

### 2026-09-03 — `/root/phase1_code_review`

Performed the independent Phase 9 code review, inspected all 15 scoped paths and relevant existing recovery/store/lifecycle contracts, ran focused/full/repeated/smoke validation, and recorded one non-blocking menu lifecycle finding. Modified only this review record and the wiki index; did not modify reviewed source/tests, stage, sign, or commit.

## P9-01 focused remediation re-review — 2026-09-03

### Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P9-01 is closed; exact staged-candidate receipt remains pending.

### Closure

- **P9-01 closed:** `actionableEditorViewOptions` is the single admission predicate used by both View actions and menu validation. It requires workspace `.ready`, a non-nil active buffer, and no termination review before exposing `EditorViewOptionsPort`.
- Delayed recovery keeps the menu disabled and direct selector invocation inert against the provisional buffer; ready state re-enables the command with the restored/default check state.
- A blocked termination review disables validation and makes direct selector invocation inert. Cancellation reopens the same admission predicate without changing text or the existing view state.

### Evidence

- Inspected the current controller and both regression-test bodies. The shared predicate removes validation/action drift and introduces no new Application or adapter dependency.
- Independent debug focused pair passed **2/2 five times** (**10/10** total); independent release focused pair passed **2/2**.
- Independent full debug suite passed **189/189**. Builder-reported full release **189/189** remains supporting evidence.

### Agent Work Log

`/root/phase1_code_review` independently re-reviewed only P9-01 remediation and its delayed-restore/blocked-termination tests. Updated only this review record and the wiki index; source/tests/work documentation, staging, signing, and commit state were not changed.
