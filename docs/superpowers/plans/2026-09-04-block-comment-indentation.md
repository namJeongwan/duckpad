# Block Comments and Closing-Delimiter Indentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Every production behavior starts with a failing test, and every checkpoint receives an independent review before commit.

**Goal:** Add literal manifest-driven block-comment toggling, direct-input closing-delimiter dedent, and proof that explicit indent/outdent obey each active language configuration without making Duckpad IDE-heavy.

**Architecture:** `EditorLanguageConfiguration.comments` is the only applied comment authority. `LanguageWorkspaceUseCase` invokes a no-argument port command; `ScintillaEditorAdapter` retains the successfully applied pair; the Duckpad-owned Objective-C++ bridge owns UTF-8 selection validation and native mutations. Block comments and indentation canonicalization suppress Scintilla component notifications and publish one aggregate edit. The direct closer and dedent remain one native Undo group with bounded current-line inspection.

**Tech stack:** Swift 6, AppKit, Swift Testing, Objective-C++17, vendored Scintilla 5.6.6, vendored Lexilla 5.5.3. No new dependency.

**Spec:** `docs/superpowers/specs/2026-09-04-block-comment-indentation-design.md`

## Global constraints

- Add no parser, LSP, background worker, macro system, or dependency.
- Keep block syntax literal; never infer nesting or grammar.
- Support only one stream selection with no virtual space. Other selection topologies are no-ops.
- Validate delimiters as nonempty UTF-8 values of at most 64 bytes.
- Keep direct-input indentation inspection at or below 4,096 bytes.
- Reserve five revisions before closer auto-dedent: two forward edits and three worst-case native Undo components.
- Preserve IME, paste, programmatic edit, split-pane, UTF-8, revision, recovery, dirty, Undo, and Redo behavior.
- One source file contains one primary component/module. Do not add a generic editing framework.
- Never stage or modify the user-owned `docs/wiki/04-implementation-foundation.md` or `scripts/vendor_scintilla_5_6_6.sh`.
- Do not push until the exact final candidate has passed independent review with 0 Critical / 0 Important / 0 Minor.

### Reviewed checkpoint protocol

Every task checkpoint uses the repository's installed signed-review workflow;
raw `git commit` is forbidden:

1. the builder stages only that task's exact paths and runs `git diff --cached --check`;
2. the builder writes the Conventional Commit message to a temporary file and
   runs `python3 scripts/review/verify_candidate.py prepare --message-file <file>`;
3. the builder gives the returned immutable candidate ID and scope to an
   independent reviewer;
4. the reviewer inspects that exact candidate, remediations create a new
   candidate, and only a 0/0/0 reviewer signs it with
   `python3 scripts/review/create_receipt.py --candidate-id <id> --reviewer-id /root/phase1_code_review --scope <exact-scope> --validation <review-and-test-evidence>`;
5. after the reviewer returns the receipt evidence, the builder runs
   `python3 scripts/review/verify_candidate.py verify --candidate-id <id>`;
6. the builder commits only with
   `python3 scripts/review/local_commit.py --candidate-id <id>`; and
7. the builder runs `python3 scripts/review/verify_candidate.py audit --commit HEAD`.

Any change after review invalidates the candidate and requires a fresh review,
candidate, and receipt. No checkpoint is pushed independently.

## File map

- Modify `Sources/DuckpadApplication/Ports.swift`: applied comment configuration and block-comment port surface.
- Modify `Sources/DuckpadApplication/LanguageService.swift`: no-argument ready-state routing.
- Modify `Sources/DuckpadInfrastructure/LanguageManifestLoader.swift`: block-pair byte validation.
- Modify `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`: narrow native block-comment API and selection-topology test seam.
- Modify `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`: aggregate edits, literal toggle, closer dedent, and lifecycle cleanup.
- Modify `Vendor/Scintilla/5.6.6/PROVENANCE.md`: record Duckpad-owned bridge changes only.
- Modify `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`: last-successful configuration capability, focused-pane routing, and rejection cancellation.
- Modify `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`: accessible Option-Command-/ menu command.
- Modify `Sources/DuckpadPresentation/DuckpadWindowController.swift`: validation, invocation, and focus restoration.
- Modify `Sources/DuckpadApp/DuckpadMain.swift`: production block-comment and closer-dedent smoke.
- Modify `tests/DuckpadInfrastructureTests/LanguageManifestTests.swift`: manifest boundary tests.
- Modify `tests/DuckpadApplicationTests/LanguageWorkspaceUseCaseTests.swift`: SSOT and ready-state routing tests.
- Modify `tests/DuckpadEditorAdapterTests/LanguageEditorAdapterTests.swift`: native, adapter, recovery, indentation, performance, and regression tests.
- Modify `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`: native menu and controller policy tests.
- Modify `tests/DuckpadPresentationTests/ExtensionPresentationTests.swift`: extension shortcut collision proof.
- Modify `docs/DASHBOARD.md`, `docs/wiki/05-scintilla-integration.md`, and `docs/wiki/10-language-support.md`: delivered behavior and validation evidence.

---

### Task 1: Applied comment capability and manifest validation

**Files:**

- Modify: `Sources/DuckpadApplication/Ports.swift`
- Modify: `Sources/DuckpadApplication/LanguageService.swift`
- Modify: `Sources/DuckpadInfrastructure/LanguageManifestLoader.swift`
- Modify: `tests/DuckpadInfrastructureTests/LanguageManifestTests.swift`
- Modify: `tests/DuckpadApplicationTests/LanguageWorkspaceUseCaseTests.swift`

**Interfaces:**

- `EditorLanguageConfiguration.comments: LanguageCommentSyntax`
- `LanguageEditorPort.canToggleBlockComment: Bool`
- `LanguageEditorPort.toggleBlockComment() -> EditorEditOutcome`
- `LanguageWorkspaceUseCase.toggleBlockComment() -> EditorEditOutcome?`

- [ ] **Step 1: Add failing manifest boundary tests**

Add table-driven fixtures named `blockCommentManifestRejectsInvalidDelimiterPairs` for `[]`, one entry, three entries, empty start, empty end, 65-byte start, and 65-byte end. Each fixture must still contain the required 60 definitions so failure is attributable to the pair. Add `bundledBlockCommentPairsAreNonemptyAndBounded` to assert every existing complete bundled pair is 1...64 UTF-8 bytes.

Run: `swift test --filter LanguageManifestTests`

Expected RED: empty and oversized pairs currently load.

- [ ] **Step 2: Implement minimal loader validation**

Keep manifest schema version 1. Add one local predicate in `load(_:)`:

```swift
let validBlockComment = entry.blockComment.map {
    $0.count == 2 && $0.allSatisfy { (1...64).contains($0.utf8.count) }
} ?? true
```

Require `validBlockComment` in the existing entry guard. Do not normalize delimiters or alter `Languages.json`.

- [ ] **Step 3: Add failing configuration and use-case tests**

Extend `LanguageEditorFake` with literal capability and invocation counters. Add:

- `appliedConfigurationCarriesTheDetectedCommentSyntax`: C/HTML/plain fixtures equal registry values.
- `blockCommentRoutesOnlyWhenLanguageStateIsReadyAndEditorIsCapable`: degraded, unsupported, and ready cases.
- `blockCommentUseCaseDoesNotResolveOrPassDelimiters`: the fake owns the outcome and records only a no-argument invocation.
- `failedLanguageApplicationDoesNotPublishReadyCommentCapability`: an application failure leaves the previous capability in the fake and service state degraded.

Run: `swift test --filter LanguageWorkspaceUseCaseTests`

Expected RED: configuration has no comments and the command surface does not compile.

- [ ] **Step 4: Implement the application contract**

Add `comments` to `EditorLanguageConfiguration` with a default `.init()` so unrelated configuration call sites remain source-compatible. Pass `definition.capabilities.comments` when building the configuration. Keep the new protocol requirements explicit: update the two repository conforming fakes in `LanguageWorkspaceUseCaseTests.swift` and `TabFlowLayoutTests.swift` with fail-closed capability/outcome values rather than hiding missing behavior behind a protocol default.

The use case must only do:

```swift
public func toggleBlockComment() -> EditorEditOutcome? {
    guard case .ready = state, let editor, editor.canToggleBlockComment else { return nil }
    return editor.toggleBlockComment()
}
```

It must not read the registry pair at invocation time.

- [ ] **Step 5: Verify and checkpoint**

Run:

```bash
swift test --filter LanguageManifestTests
swift test --filter LanguageWorkspaceUseCaseTests
swift test -c release --filter LanguageManifestTests
swift test -c release --filter LanguageWorkspaceUseCaseTests
```

Stage only the five Task 1 files, run `git diff --cached --check`, request independent review, remediate all severities, then follow the reviewed checkpoint protocol with `feat: validate block comment capability`. Do not push.

---

### Task 2: Atomic native block-comment toggle and adapter authority

**Files:**

- Modify: `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`
- Modify: `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`
- Modify: `Vendor/Scintilla/5.6.6/PROVENANCE.md`
- Modify: `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- Modify: `tests/DuckpadEditorAdapterTests/LanguageEditorAdapterTests.swift`

**Native surface:**

```objective-c
typedef NS_ENUM(NSInteger, DPScintillaSelectionShape) {
    DPScintillaSelectionShapeStream = 0,
    DPScintillaSelectionShapeRectangle = 1,
    DPScintillaSelectionShapeLines = 2,
    DPScintillaSelectionShapeThin = 3,
};

+ (BOOL)blockCommentSupportsSelectionShape:(DPScintillaSelectionShape)shape
                                     count:(NSUInteger)count
                         caretVirtualSpace:(NSUInteger)caretVirtualSpace
                        anchorVirtualSpace:(NSUInteger)anchorVirtualSpace;
- (BOOL)canToggleBlockCommentsWithStartUTF8:(NSData *)start
                                    endUTF8:(NSData *)end
                             selectionOwner:(DPScintillaEditorView *)selectionOwner;
- (BOOL)toggleBlockCommentsWithStartUTF8:(NSData *)start
                                 endUTF8:(NSData *)end
                          selectionOwner:(DPScintillaEditorView *)selectionOwner;
@property(nonatomic, copy, nullable) void (^onSmartIndentationStateChange)(BOOL pending);
- (void)cancelPendingSmartIndentation;
```

The pure class method is the typed selection-topology predicate used by the live bridge and the table-driven tests. The live path maps `SCI_GETSELECTIONMODE` to the Duckpad enum before calling it. This proves all excluded modes without adding a state-mutating test hook; no Scintilla pointer, raw message, or raw selection constant escapes the module. A live multi-selection integration uses the existing `addSelectionUTF8Range:` method.

- [ ] **Step 1: Write failing native toggle tests**

Add these named tests before bridge implementation:

- `blockCommentWrapAndUnwrapPreserveUTF8CRLFAndSelectionDirection`
- `emptyCaretInsertsAndRemovesAdjacentPairAtExactBytePosition`
- `identicalDelimitersRequireTwoDisjointEdgesBeforeUnwrap`
- `nestedDelimiterTextIsHandledLiterally`
- `blockCommentRejectsInvalidDelimiterDataWithoutMutation`
- `blockCommentRejectsMultiRectangularLineThinAndVirtualSelections`
- `blockCommentUndoRedoRestoresExactBytesSelectionAndRevision`
- `largeBlockCommentPublishesOneAggregateEditWithinExplicitCommandBudget`

The large test uses a 1 MiB UTF-8 selection, requires one published edit/revision, linear aggregate payload bytes, zero full `contentUTF8` snapshot reads during the command, and completion within 250 ms when `_isDebugAssertConfiguration()` is false. The topology predicate table covers every shape/count/virtual-space tuple; the live multi-selection case additionally requires no callback, mutation, focus change, or new Undo record.

Run: `swift test --filter 'blockComment|BlockComment'`

Expected RED: bridge and adapter methods are absent.

- [ ] **Step 2: Add one aggregate user-edit helper**

In the Objective-C++ implementation, add a private helper owned by `DPScintillaEditorView` that:

1. validates revision budget and UTF-8 boundaries;
2. reads the exact affected bytes with `SCI_GETTEXTRANGEFULL`;
3. sets `_suppressEdit = YES`, performs one native `SCI_REPLACETARGET`, then restores suppression with scope-safe cleanup;
4. installs the resulting selection on the initiating selection owner after replacement and before publication;
5. increments `_revision` once and disables editing only if it reaches `UINT64_MAX`;
6. updates incremental instrumentation once; and
7. publishes one `DPScintillaEdit` carrying original range, replacement bytes, deleted bytes, and `.user` origin.

Do not call `contentUTF8`, do not publish Scintilla's component delete/insert notifications, and do not reuse the application-driven `replaceUTF8Range` method because this is a user edit that must pass through `onEdit`.

- [ ] **Step 3: Implement literal selection semantics**

Validate exactly one `SC_SEL_STREAM` selection and zero `SCI_GETSELECTIONNCARETVIRTUALSPACE` / `SCI_GETSELECTIONNANCHORVIRTUALSPACE`. Reject marked text, disabled input, invalid delimiters, overflow, and revision exhaustion.

For nonempty selection, unwrap only when length is at least `start.length + end.length` and both outer byte ranges match. Otherwise build `start + selected + end`. Preserve anchor/caret direction after replacing and select the complete wrapped or payload range. For empty selection, inspect only adjacent delimiter-sized ranges; removal sets caret to `oldCaret - start.length`, insertion leaves it between delimiters.

- [ ] **Step 4: Route through the last successfully applied configuration**

In `ScintillaEditorAdapter`, compute `canToggleBlockComment` from the active buffer's stored `languageConfigurations[bufferID].comments`, the focused live view, and the native capability query. `toggleBlockComment()` reads that same stored pair, invokes the primary view as transaction publisher with the focused view as `selectionOwner`, and returns accepted only when the adapter's authoritative revision advanced exactly once. Failed lexer application must not replace `languageConfigurations` or capability.

Add adapter tests:

- `adapterUsesOnlyLastSuccessfullyAppliedBlockPair`
- `blockCommentAcceptanceAdvancesDirtyRecoveryExactlyOnce`
- `rejectedBlockCommentReloadsUnchangedAuthorityWithoutPartialDelimiter`
- `splitBlockCommentTargetsFocusedPaneAndSharesAcceptedText`
- `secondaryBlockCommentUsesPrimaryAggregatePublisherWhenAcceptedOrRejected`
- `largeStyleFallbackRetainsLiteralBlockCommentCapability`

`shareDocumentWithView:` records a weak primary publisher on the secondary. The
publisher suppresses its own shared-document component notifications, mutates
the shared document, installs the resulting selection on the selection owner,
and publishes through its sole `onEdit` callback. The secondary stays a
nonpublisher.

The secondary test runs accepted and rejected commands. It requires zero raw
callbacks, exactly one aggregate callback, one authoritative revision only on
acceptance, shared bytes, initiating selection semantics, and no duplicate
recovery append. The general rejection test awaits scheduled recovery and
asserts original bytes, original revision, original selection, zero recovery
delta append, and no partial delimiter.

- [ ] **Step 5: Verify and checkpoint**

Run:

```bash
swift test --filter 'blockComment|BlockComment'
swift test --filter LanguageEditorAdapterTests
swift test -c release --filter 'blockComment|BlockComment'
swift test -c release --filter LanguageEditorAdapterTests
```

Update `PROVENANCE.md` to state only Duckpad-owned `bridge/` files changed. Stage only the five Task 2 files, run `git diff --cached --check`, request independent review and re-review to zero, then follow the reviewed checkpoint protocol with `feat: add atomic block comment toggle`. Do not push.

---

### Task 3: Direct closer dedent and configured indent/outdent proof

**Files:**

- Modify: `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`
- Modify: `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- Modify: `tests/DuckpadEditorAdapterTests/LanguageEditorAdapterTests.swift`

**Pending native state:** closer byte, insertion position, original indentation range/data, canonical replacement data, expected post-insert caret, and whether a native Undo group is open. No document-sized or persistent state.

- [ ] **Step 1: Write failing direct-input behavior tests**

Add table-driven tests:

- `directClosingDelimiterDedentsOneConfiguredLevel`: `}`, `]`, `)` with 2-space, 4-space, and tab configurations.
- `mixedIndentationDedentsToExactTabStopColumn`: prefixes `"\t  "` and `" \t"` under both `useTabs` settings; assert target `max(0, columns - tabWidth)` and configured canonical bytes.
- `shortIndentationDedentsToZero`
- `closerDedentPublishesTwoForwardEditsAndOneUndoRestoresBoth`
- `repeatedCloserDedentsRetainInitiatingViewTracking`
- `closerDedentRedoRestoresBothAndUsesExistingComponentAuthority`
- `rejectedCloserCancelsPendingIndentationAndRecoversPreInputAuthority`
- `rejectedIndentationReplacementKeepsAcceptedCloserAuthority`
- `secondaryCloserDedentUsesPrimaryPublisherAndCancelsTheInitiatorOnRejection`
- `undoRedoRejectionRecoversEachAcceptedComponentPrefix`
- `closerDedentRequiresFiveRevisionBudget`

The revision boundary table starts at `UInt64.max - 5`, which dedents and remains Undo-capable. `max - 4` through `max - 1` insert only the closer. `max` is input-disabled. At `max - 5`, worst-case mixed Undo may end at max; delete-only restoration may end earlier.

Run: `swift test --filter 'Dedent|dedent|ClosingDelimiter'`

Expected RED: direct closers do not adjust indentation.

- [ ] **Step 2: Implement bounded insert-check preflight**

Extend `handleSmartInsertionCheck:` only for one-byte ASCII closers. Require known direct input, no marked text, smart editing enabled, exactly one empty stream selection, zero virtual space, and at least five remaining revisions. Scan from line start to insertion position, stopping at byte 4,096; any non-space/tab or byte 4,097 declines without opening Undo.

Compute current columns with tab stops. Set target columns to `max(0, current - configuredTabWidth)`. Canonicalize to all spaces when `useTabs == NO`, otherwise tabs plus remainder spaces. If replacement equals original or target is not lower, decline. Save bounded pending values, notify `onSmartIndentationStateChange(YES)` so the adapter records the exact initiating view, ask that view's recorded primary publisher to suppress shared component notifications, and call `SCI_BEGINUNDOACTION` before the closer insertion proceeds.

- [ ] **Step 3: Apply one aggregate indentation replacement after the closer**

The initiating primary or secondary asks the primary publisher to synthesize the
already-inserted closer as one aggregate edit while the publisher remains
suppressed. If that callback is accepted, `handleSmartCharacterAdded:` verifies
source, closer, caret, revision, and pending position, then asks the same
publisher to replace the original indentation prefix through the Task 2
aggregate helper. The forward path publishes exactly two aggregate edits and
zero raw components even when secondary initiated it.

The adapter's `onSmartIndentationStateChange` closures capture each live view
weakly and maintain the initiating view identity per buffer. When `receive`
rejects the closer aggregate, it synchronously calls
`cancelPendingSmartIndentation()` on that exact view before scheduling recovery;
the resumed character-added handler sees cleared pending state and skips the
indentation replacement. One idempotent cleanup closes the initiating Undo
group, ends publisher suppression, clears the adapter's pending identity value,
publishes `onSmartIndentationStateChange(NO)`, and clears pending bytes. It does
not remove the callback, so repeated closer inputs remain tracked. Only
invalidation, pane close, retire, and deinit nil the callback after first
calling the same pending-state cleanup; load and language reset clean pending
state but retain the live callback.

The secondary test requires zero raw callbacks, two aggregate callbacks on full
acceptance, exact primary/secondary revision synchronization, exact initiating-
view cancellation after closer rejection, closer-only authority after
indentation rejection, and a closed Undo group in every branch.
`repeatedCloserDedentsRetainInitiatingViewTracking` performs two attempts in the
same primary and then two in the same secondary, rejects each second closer,
and proves the second attempt cancels that exact initiator without touching the
other pane's pending state.

- [ ] **Step 4: Prove all excluded input paths**

Add `closerDedentExcludesPasteIMEProgrammaticMultiCharacterAndNonWhitespaceLines`, covering:

- pasteboard `}`;
- marked text followed by IME commit;
- application `replaceUTF8Range`;
- `insertCommittedText("}}")`;
- a closer after a non-whitespace byte;
- zero indentation;
- multiple or nonstream selections; and
- 4,097 whitespace bytes.

Each case asserts literal input only, no stranded Undo group, expected revision count, and bounded instrumentation.

- [ ] **Step 5: Add explicit indent/outdent regression proof**

Use `ScintillaEditorAdapter.perform(.indent/.unindent)` and add:

- `explicitIndentUsesTwoAndFourSpaceLanguageWidths`
- `explicitIndentUsesTabsForMakefileConfiguration`
- `explicitMultilineIndentAndOutdentPreserveSelectionAndGroupUndo`
- `explicitOutdentHandlesMixedLeadingWhitespace`
- `explicitIndentAdvancesDirtyAndRecoveryForEveryNativeEdit`

Do not change production indent/outdent unless a RED test proves current `SCI_TAB` / `SCI_BACKTAB` behavior violates the configured result.

- [ ] **Step 6: Run regressions and checkpoint**

Run:

```bash
swift test --filter LanguageEditorAdapterTests
swift test --filter ScintillaEditorAdapterTests
swift test -c release --filter LanguageEditorAdapterTests
swift test -c release --filter ScintillaEditorAdapterTests
```

Stage only the three Task 3 files, run `git diff --cached --check`, request independent review of revision/Undo/rejection/lifecycle behavior, remediate all findings, then follow the reviewed checkpoint protocol with `feat: dedent direct closing delimiters`. Do not push.

---

### Task 4: Native menu, Command Palette, accessibility, and shortcut safety

**Files:**

- Modify: `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- Modify: `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- Modify: `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
- Modify: `tests/DuckpadPresentationTests/ExtensionPresentationTests.swift`

- [ ] **Step 1: Write failing menu and routing tests**

Add:

- `blockCommentMenuIsAccessibleUniqueAndPaletteDiscoverable`
- `blockCommentValidationRequiresReadyWorkspaceAndEditorCapability`
- `blockCommentCommandFocusesEditorOnlyAfterAcceptedMutation`
- `everyCoreShortcutIdentityIsUnique`
- extend `extensionShortcutsFailClosedOnCoreCollisionOrMalformedDeclaration` with `cmd+option+/`.

Require title `Toggle Block Comment`, selector `performToggleBlockComment:`, key `/`, modifiers `[.command, .option]`, accessibility label `Toggle block comment`, and Command Palette discovery. The all-core uniqueness assertion recursively flattens the completed menu before extensions are added.

Run:

```bash
swift test --filter 'blockCommentMenu|blockCommentValidation|blockCommentCommand|everyCoreShortcut'
swift test --filter extensionShortcutsFailClosedOnCoreCollisionOrMalformedDeclaration
```

Expected RED: command and selector are missing; the new extension collision receives the shortcut.

- [ ] **Step 2: Add the native command**

Place `Toggle Block Comment` in the Edit menu adjacent to the existing Indent
Line(s) and Unindent Line(s) commands. Keep Toggle Line Comment in its current
Language-menu location so this phase does not relocate an established command.
The presentation test asserts that the Block command's immediate parent title
is `Edit`:

```swift
add(
    "Toggle Block Comment",
    #selector(DuckpadWindowController.performToggleBlockComment(_:)),
    "/",
    target,
    modifiers: [.command, .option],
    accessibilityLabel: "Toggle block comment",
    to: editMenu
)
```

Keep recursive palette indexing and existing extension collision logic unchanged. The new core shortcut enters the occupied set automatically.

- [ ] **Step 3: Route capability, outcome, and focus**

Add one controller selector. It must guard actionable workspace plus `languageUseCase` capability, invoke the no-argument use-case command, and call the editor's existing `focus()` only for `.accepted`. Menu validation uses the same ready/capability conditions and does not mutate the document. No new view/controller file is needed.

- [ ] **Step 4: Verify presentation and checkpoint**

Run:

```bash
swift test --filter TabFlowLayoutTests
swift test --filter ExtensionPresentationTests
swift test --filter CommandPalettePresentationTests
swift test -c release --filter TabFlowLayoutTests
swift test -c release --filter ExtensionPresentationTests
swift test -c release --filter CommandPalettePresentationTests
```

Stage only the four Task 4 files, run `git diff --cached --check`, request independent accessibility/routing review, remediate to zero, then follow the reviewed checkpoint protocol with `feat: expose block comment command`. Do not push.

---

### Task 5: Production smoke, durable evidence, final review, and push

**Files:**

- Modify: `Sources/DuckpadApp/DuckpadMain.swift`
- Modify: `docs/DASHBOARD.md`
- Modify: `docs/wiki/05-scintilla-integration.md`
- Modify: `docs/wiki/10-language-support.md`

- [ ] **Step 1: Extend the real AppKit language smoke**

Inside the existing `DUCKPAD_LANGUAGE_SMOKE` branch, after Swift highlighting:

1. select a UTF-8/CRLF payload and invoke the adapter's no-argument block toggle;
2. require one accepted revision, exact `/*payload*/`, Undo to exact source, and Redo;
3. switch to JSON, insert an indentation-only line, directly type `}`, and require one-level dedent;
4. require one Undo to remove both closer and dedent;
5. retain existing folding, Python switch, palette, and text/revision checks.

Update the smoke receipt text to name block comments and closer dedent.

- [ ] **Step 2: Run complete focused validation**

Run each separately and retain logs/exit codes:

```bash
swift build
swift build -c release
swift test --filter LanguageManifestTests
swift test --filter LanguageWorkspaceUseCaseTests
swift test --filter LanguageEditorAdapterTests
swift test --filter ScintillaEditorAdapterTests
swift test --filter TabFlowLayoutTests
swift test --filter ExtensionPresentationTests
swift test --filter CommandPalettePresentationTests
swift test -c release --filter LanguageManifestTests
swift test -c release --filter LanguageWorkspaceUseCaseTests
swift test -c release --filter LanguageEditorAdapterTests
swift test -c release --filter ScintillaEditorAdapterTests
swift test -c release --filter TabFlowLayoutTests
swift test -c release --filter ExtensionPresentationTests
swift test -c release --filter CommandPalettePresentationTests
scripts/run_performance_benchmarks.sh
smoke_root="$(mktemp -d /tmp/duckpad-block-comment-smoke.XXXXXX)"
DUCKPAD_RECOVERY_ROOT="$smoke_root" DUCKPAD_LANGUAGE_SMOKE=1 .build/release/DuckpadApp
git diff --check
```

The six frozen performance budgets must remain green; no seventh metric is added. Focused block-comment Release stress must finish within 250 ms.

- [ ] **Step 3: Run and classify monolithic diagnostics honestly**

Run `swift test` and `swift test -c release` separately. If the known process-global AppKit `signal 11` or extension-host timeout recurs, reproduce the exact command at parent `4510f3a`, retain both results, and report it as a baseline blocker rather than a Phase 32 pass. Any new attributable failure blocks completion.

- [ ] **Step 4: Update documentation**

Document literal block capability, single-stream scope, aggregate authority, IME/paste exclusions, 4,096-byte line bound, five-revision auto-dedent threshold, configured explicit indent/outdent evidence, performance results, and exact baseline diagnostics. Update the dashboard Phase 32 row to implemented but leave push pending.

- [ ] **Step 5: Perform mandatory final independent code review**

Review the complete Phase 32 commit range from design parent `4510f3a` through
current `HEAD`, plus the exact staged Task 5 smoke/documentation delta. Confirm
both protected user paths remain unstaged. Ask the reviewer to inspect
correctness, UTF-8/overflow arithmetic, single-publisher notification
suppression, revision exhaustion, rejection recovery, Undo/Redo accepted-prefix
behavior, initiating-view teardown, split focus, accessibility, performance,
and test honesty. Remediate every Critical, Important, and Minor finding and
repeat until all counts are zero. Earlier committed task paths are reviewed as
the range; they are not re-staged.

- [ ] **Step 6: Commit, audit, and push the exact reviewed candidate**

Run `git diff --cached --check` and follow the reviewed checkpoint protocol with
`chore: validate block comment editing`. Push
`feature/block-comment-indentation`, then verify
`git ls-remote origin refs/heads/feature/block-comment-indentation` equals local
`HEAD` exactly.

- [ ] **Step 7: Close the dashboard after remote verification**

Change the Phase 32 dashboard status to Delivered with the verified SHA. Review this doc-only delta independently, create an audited `chore: close block comment dashboard` commit, push again, and re-verify the remote SHA. Keep the broader roadmap goal active unless every remaining roadmap item is also complete.

## Requirement-to-test checklist

| Approved requirement | Named proof | Task |
| --- | --- | --- |
| Manifest pair cardinality/nonempty/64-byte bound | `blockCommentManifestRejectsInvalidDelimiterPairs`, `bundledBlockCommentPairsAreNonemptyAndBounded` | 1 |
| Applied comments are SSOT and failed apply preserves them | `appliedConfigurationCarriesTheDetectedCommentSyntax`, `adapterUsesOnlyLastSuccessfullyAppliedBlockPair` | 1–2 |
| Ready/capable no-argument routing | `blockCommentRoutesOnlyWhenLanguageStateIsReadyAndEditorIsCapable` | 1 |
| UTF-8/CRLF wrap/unwrap and direction | `blockCommentWrapAndUnwrapPreserveUTF8CRLFAndSelectionDirection` | 2 |
| Empty caret and identical delimiters | `emptyCaretInsertsAndRemovesAdjacentPairAtExactBytePosition`, `identicalDelimitersRequireTwoDisjointEdgesBeforeUnwrap` | 2 |
| Literal nested semantics | `nestedDelimiterTextIsHandledLiterally` | 2 |
| Exactly one stream/no virtual selection | `blockCommentRejectsMultiRectangularLineThinAndVirtualSelections` | 2 |
| One aggregate revision and rejection atomicity | `blockCommentAcceptanceAdvancesDirtyRecoveryExactlyOnce`, `rejectedBlockCommentReloadsUnchangedAuthorityWithoutPartialDelimiter` | 2 |
| Large selection has explicit-only linear cost | `largeBlockCommentPublishesOneAggregateEditWithinExplicitCommandBudget` | 2 |
| Focused split-pane command shares text | `splitBlockCommentTargetsFocusedPaneAndSharesAcceptedText` | 2 |
| Direct closers dedent exact configured columns | `directClosingDelimiterDedentsOneConfiguredLevel`, `mixedIndentationDedentsToExactTabStopColumn` | 3 |
| Paste/IME/programmatic/multi/nonspace/long prefixes excluded | `closerDedentExcludesPasteIMEProgrammaticMultiCharacterAndNonWhitespaceLines` | 3 |
| Five-revision boundary and teardown | `closerDedentRequiresFiveRevisionBudget`, rejection tests | 3 |
| Undo/Redo and accepted-prefix recovery | `closerDedentPublishesTwoForwardEditsAndOneUndoRestoresBoth`, `undoRedoRejectionRecoversEachAcceptedComponentPrefix` | 3 |
| Explicit indent/outdent follows 2/4-space/tab configs | five `explicitIndent...` / `explicitOutdent...` tests | 3 |
| Native menu/palette/accessibility/core uniqueness | `blockCommentMenuIsAccessibleUniqueAndPaletteDiscoverable`, `everyCoreShortcutIdentityIsUnique` | 4 |
| Extension loses Option-Command-/ collision | extended `extensionShortcutsFailClosedOnCoreCollisionOrMalformedDeclaration` | 4 |
| Real AppKit highlighting/editing smoke | extended `DUCKPAD_LANGUAGE_SMOKE=1` | 5 |
| No performance regression | six-budget runner plus 1 MiB focused Release stress | 2, 5 |
