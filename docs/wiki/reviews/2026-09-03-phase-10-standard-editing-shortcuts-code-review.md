# Phase 10 standard editing shortcuts independent code review

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Candidate freeze and exact staged-candidate signing are authorized; the receipt remains pending.

## Scope

Reviewed exactly the current Phase 10 changes in:

- `Sources/DuckpadApplication/Ports.swift`
- `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- `Sources/DuckpadPresentation/TextViewEditorAdapter.swift`
- `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`
- `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`
- `tests/DuckpadEditorAdapterTests/ScintillaEditorAdapterTests.swift`
- `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
- `docs/wiki/00-wiki-index.md`
- `docs/wiki/12-editor-view-options.md`
- `docs/wiki/13-standard-editing-shortcuts.md`

The pre-existing `docs/wiki/04-implementation-foundation.md` and untracked
`scripts/vendor_scintilla_5_6_6.sh` were excluded and preserved. Reviewed
source/tests/work documentation were not edited or staged; no receipt or commit
was created.

## Evidence

- Clean Architecture direction is correct: Application owns platform-neutral
  command intent/capability, Presentation owns native selectors/validation, and
  the adapters/Objective-C++ bridge own AppKit and Scintilla behavior.
- The static native menu publishes the requested macOS shortcuts; the recursive
  complete-menu chord check includes every submenu and passed. Delete's empty
  key equivalent correctly leaves physical Backspace/Delete and IME dispatch in
  the focused editor.
- Normal single-selection Scintilla Cut/Delete/Undo/Redo advanced the owned
  revision and recovery delta stream, and the fallback editor retained its
  per-buffer undo manager.
- Independent focused Phase 10 tests passed **5/5**. Independent complete debug
  and release suites passed **192/192** each. The scoped diff check and inward
  dependency scan passed. Builder-reported fresh-scratch 192/192, macOS 13
  x86_64 release link, and production launch/exit smoke were supporting evidence.
- Three tests added only to an external scratch copy reproduced the findings:
  active-IME Undo/Paste failed **2/2** semantic assertions; revision-exhausted
  fallback capability failed **3/3** assertions; blocked Cmd-N versus final
  recovery failed **1/1** with one durable tab at approval and two live tabs
  after the blocked command completed.

## Initial findings — resolved

- `Sources/DuckpadPresentation/DuckpadWindowController.swift:L396-L403,L606-L642` — **Major P10-01:** Cmd-N launches an untracked Task, so termination can approve/final-flush while its durable `addScratch()` is blocked and the tab appears only afterward. Register every accepted New task synchronously, recheck/cancel queued work after the termination lock, and await all entered work before dirty review/final recovery.
- `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm:L382-L388,L440-L446` — **Major P10-02:** menu Undo/Paste use raw `SCI_*` messages, bypassing Scintilla Cocoa's marked-text validation and its discard/`CompositionCommit` path; Undo remains enabled and Paste leaves stale active composition. Route capability/actions through the Cocoa content responder or reproduce its exact marked-text gates, then test both commands during Korean composition.
- `Sources/DuckpadPresentation/TextViewEditorAdapter.swift:L51-L78,L119-L122,L147-L177` — **Major P10-03:** a buffer at `UInt64.max` remains editable and reports Paste/Delete available, unlike the fail-closed Scintilla adapter; rejected edits can still enter AppKit's undo machinery. Track lifecycle input separately, make mutation availability require `revision < .max` on display/install/accepted edits, and prove every mutating command preserves text/revision/undo at exhaustion.

## Agent Work Log

### 2026-09-03 — `/root/phase1_code_review`

Performed the independent Phase 10 content review over the frozen 13-path
scope, inspected menu/editor/lifecycle and test bodies, ran focused and full
debug/release validation, and reproduced three current-scope races/semantic
violations in an external scratch package. Modified only this review record and
the wiki index; did not modify product source/tests/work documentation, stage,
sign, or commit.

## P10-01/P10-02/P10-03 focused remediation re-review — 2026-09-03

### Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** All three initial
Major findings are closed. The current Phase 10 content may be frozen and
prepared for an exact signed candidate receipt.

### Closure

- **P10-01 closed:** every accepted New Scratch request is synchronously
  registered in `pendingNewScratchTasks`; its MainActor task rechecks admission,
  removes itself on every exit, and termination closes admission before joining
  the complete registered set. Dirty review and final recovery now start only
  after those durable transactions finish. A workspace publication during the
  join can make `EditorBindingUseCase` apply ready-state input, so `handle(_:)`
  immediately reasserts disabled input while termination review remains active.
- **P10-02 closed:** Scintilla capabilities and standard actions now use its
  Cocoa `SCIContentView` responder validation/action paths. Active Korean marked
  text disables Undo; attempted Undo is inert; Paste performs the native
  discard/`CompositionCommit` step and leaves no stale marked range before the
  clipboard insertion.
- **P10-03 closed:** `TextViewEditorAdapter` separates requested lifecycle input
  from revision capacity and reapplies it on display, install, accepted edit,
  rejection recovery, retirement, and explicit input changes. At `UInt64.max`
  the buffer remains selectable for Copy/Select All but every mutation command
  is disabled without changing text, revision, or undo/redo state.

### Evidence

- Read the current remediation implementations and all three regression-test
  bodies; the Application/Presentation/adapter dependency direction remains
  inward and no platform symbol entered Application.
- Independent current-byte focused remediation run passed **3/3**. An external
  scratch probe additionally blocked final recovery after joined tab insertion
  and passed **1/1**, proving physical input remained disabled at that boundary.
- Independent complete debug and release suites passed **195/195** each. The
  scoped/full diff check passed. Builder-reported fresh-scratch debug 195/195,
  macOS 13 x86_64 release link, and production 50-tab Scintilla smoke remain
  supporting evidence.
- The builder's first parallel release viewport-state failure passed in
  isolation and in both complete reruns; it is unrelated to the Phase 10 command
  paths and did not recur in this independent release run.

### Findings

None.

### Agent Work Log

`/root/phase1_code_review` independently re-reviewed P10-01/P10-02/P10-03 and
the complete Phase 10 diff, ran focused/adversarial/full debug-release
validation, and authorized candidate freeze/signing. Only this review record
and the wiki index were changed; source/tests/work documentation, stage,
receipt, and commit state were not changed.
