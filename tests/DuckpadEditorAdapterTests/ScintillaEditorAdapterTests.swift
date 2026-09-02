import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation
import DuckpadScintillaBridge
import Testing

private actor DelayedSearchSessionStore: SessionStore {
    private var session: ScratchSession?
    private var generation = PersistenceGeneration(rawValue: 0)
    private var blockNextCommit = false
    private var blockedCommitEntered = false
    private var releaseBlockedCommit = false

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        session.map { StoredSession(session: $0, generation: generation) }
    }

    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        if blockNextCommit {
            blockNextCommit = false
            blockedCommitEntered = true
            while !releaseBlockedCommit { await Task.yield() }
        }
        guard generation > self.generation else {
            return .superseded(durableGeneration: self.generation)
        }
        self.session = session
        self.generation = generation
        return .committed
    }

    func arm() {
        blockNextCommit = true
        blockedCommitEntered = false
        releaseBlockedCommit = false
    }

    func waitUntilBlocked() async {
        while !blockedCommitEntered { await Task.yield() }
    }

    func release() { releaseBlockedCommit = true }
}

@Suite(.serialized)
struct ScintillaBridgeTests {
    @Test @MainActor
    func realViewUsesUTF8ByteRangesAndRejectsStaleRevision() throws {
        let view = makeHostedView()
        try view.loadUTF8(Data("Duckpad 한글 🦆".utf8), revision: 4)
        #expect(text(view) == "Duckpad 한글 🦆")
        #expect(view.revision == 4)
        #expect(view.cursorResourcesAvailable)
        #expect(view.accessibilityIdentifier() == "duckpad.editor.scintilla")

        try view.replaceUTF8Range(
            NSRange(location: 8, length: 6),
            withReplacement: Data("오리".utf8),
            expectedRevision: 4,
            resultingRevision: 5
        )
        #expect(text(view) == "Duckpad 오리 🦆")
        #expect(view.revision == 5)

        var rejected = false
        do {
            try view.replaceUTF8Range(
                NSRange(location: 0, length: 0),
                withReplacement: Data("x".utf8),
                expectedRevision: 4,
                resultingRevision: 5
            )
        } catch { rejected = true }
        #expect(rejected)
        #expect(text(view) == "Duckpad 오리 🦆")

        try view.loadUTF8(Data("x".utf8), revision: .max)
        do {
            try view.replaceUTF8Range(
                NSRange(location: 1, length: 0),
                withReplacement: Data("y".utf8),
                expectedRevision: .max,
                resultingRevision: .max
            )
            Issue.record("revision overflow must fail closed")
        } catch {
            #expect(view.revision == .max)
            #expect(text(view) == "x")
        }
    }

    @Test @MainActor
    func splitUTF8CodePointBoundariesFailWithoutMutation() throws {
        for sample in ["é", "한", "🦆", "e\u{301}"] {
            let view = makeHostedView()
            let original = Data(sample.utf8)
            try view.loadUTF8(original, revision: 9)
            let continuationOffsets = original.indices.filter {
                (original[$0] & 0xC0) == 0x80
            }
            for offset in continuationOffsets {
                for range in [
                    NSRange(location: offset, length: 0),
                    NSRange(location: 0, length: offset),
                ] {
                    do {
                        try view.replaceUTF8Range(
                            range,
                            withReplacement: Data("x".utf8),
                            expectedRevision: 9,
                            resultingRevision: 10
                        )
                        Issue.record("split UTF-8 boundary \(range) must be rejected")
                    } catch {
                        #expect(view.revision == 9)
                        #expect(view.contentUTF8 == original)
                    }
                }
            }
        }

        let combining = makeHostedView()
        try combining.loadUTF8(Data("e\u{301}".utf8), revision: 1)
        try combining.replaceUTF8Range(
            NSRange(location: 1, length: 2),
            withReplacement: Data("".utf8),
            expectedRevision: 1,
            resultingRevision: 2
        )
        #expect(text(combining) == "e")
    }

    @Test @MainActor
    func revisionExhaustionIsReadOnlyBeforeUserMutation() throws {
        let view = makeHostedView()
        var edits = 0
        var errors: [any Error] = []
        view.onEdit = { _ in edits += 1 }
        view.onError = { errors.append($0) }
        try view.loadUTF8(Data("base".utf8), revision: .max - 1)
        view.setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
        view.insertCommittedText("!")
        #expect(view.revision == .max)
        #expect(edits == 1)
        let accepted = view.contentUTF8

        view.resetInstrumentation()
        edits = 0
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("paste", forType: .string)
        view.insertCommittedText("x")
        view.paste()
        view.undo()
        view.redo()
        view.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(!view.isInputEnabled)
        #expect(view.contentUTF8 == accepted)
        #expect(view.revision == .max)
        #expect(edits == 0)
        #expect(view.incrementalNotificationCount == 0)
        #expect(!errors.isEmpty)
        #expect((view.lastMutationError as? NSError)?.code == 4)
        #expect(!view.hasMarkedText())

        do {
            try view.replaceUTF8Range(
                NSRange(location: 0, length: 0),
                withReplacement: Data("external".utf8),
                expectedRevision: .max,
                resultingRevision: .max
            )
            Issue.record("external apply at max revision must fail")
        } catch {
            #expect(view.contentUTF8 == accepted)
            #expect(view.revision == .max)
        }
    }

    @Test @MainActor
    func acceptedEditWorkIsBoundedAcrossOneTenAndFiftyMegabytes() throws {
        let clock = ContinuousClock()
        var durations: [Duration] = []
        for size in [1_000_000, 10_000_000, 50_000_000] {
            let adapter = ScintillaEditorAdapter()
            let bufferID = BufferID()
            adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
            adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
            let view = try #require(adapter.activeScintillaView)
            var document = Data(repeating: 0x61, count: size)
            for newline in stride(from: 79, to: size, by: 80) { document[newline] = 0x0A }
            try view.loadUTF8(document, revision: 0)
            view.isWordWrapEnabled = false
            view.setPrimarySelectionUTF8Range(NSRange(location: size, length: 0))
            view.resetInstrumentation()
            let start = clock.now
            view.insertCommittedText("x")
            durations.append(start.duration(to: clock.now))

            #expect(view.documentByteLength == size + 1)
            #expect(view.snapshotReadCount == 0)
            #expect(view.incrementalNotificationCount == 1)
            #expect(view.incrementalPayloadByteCount == 1)
        }
        #expect(durations.allSatisfy { $0 < .milliseconds(250) })
        #expect((durations.max() ?? .zero) - (durations.min() ?? .zero) < .milliseconds(100))
    }

    @Test @MainActor
    func recoveryJournalMiddleEditWorkIsIndependentOfDocumentSize() throws {
        var work: [Int] = []
        for size in [1_000_000, 10_000_000, 50_000_000] {
            let adapter = ScintillaEditorAdapter()
            let bufferID = BufferID()
            let text = String(repeating: "a", count: size)
            adapter.install(EditorTextSnapshot(bufferID: bufferID, revision: 0, text: text))
            adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
            adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
            let view = try #require(adapter.activeScintillaView)
            view.setPrimarySelectionUTF8Range(NSRange(location: size / 2, length: 0))
            view.resetInstrumentation()

            view.insertCommittedText("x")

            let capture = try #require(adapter.recoveryCapture(for: bufferID))
            work.append(adapter.lastRecoveryJournalWorkByteCount)
            #expect(adapter.recoveryJournalAppendCount == 1)
            #expect(capture.baseUTF8.count == size)
            #expect(capture.deltas.count == 1)
            #expect(capture.deltas[0].replacementUTF8.count == 1)
            #expect(view.snapshotReadCount == 0)
            #expect(try capture.materializedSnapshot().utf8.count == size + 1)
        }
        #expect(Set(work).count == 1)
        #expect(work.allSatisfy { $0 < 256 })
    }

    @Test @MainActor
    func typingUndoRedoAndMultiselectionEmitOwnedEdits() throws {
        let view = makeHostedView()
        try view.loadUTF8(Data("alpha beta".utf8), revision: 0)
        var edits: [DPScintillaEdit] = []
        view.onEdit = { edits.append($0) }
        view.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 0))
        view.insertCommittedText(" 한글")
        #expect(text(view) == "alpha 한글 beta")
        #expect(edits.first?.range == NSRange(location: 5, length: 0))
        #expect(edits.first?.replacementUTF8 == Data(" ".utf8))
        #expect(edits.first?.baseRevision == 0)
        #expect(edits.last?.resultingRevision == UInt64(edits.count))
        #expect(edits.enumerated().allSatisfy { offset, edit in
            edit.baseRevision == UInt64(offset)
                && edit.resultingRevision == UInt64(offset + 1)
        })
        #expect(edits.allSatisfy { !$0.insertedUTF8.isEmpty && $0.deletedUTF8.isEmpty })
        #expect(view.canUndo)

        let insertedEventCount = edits.count
        view.undo()
        #expect(text(view) == "alpha beta")
        #expect(edits.last?.origin == .undo)
        let undoEvents = edits.dropFirst(insertedEventCount)
        #expect(undoEvents.allSatisfy { $0.insertedUTF8.isEmpty && !$0.deletedUTF8.isEmpty })
        #expect(undoEvents.reduce(0) { $0 + $1.deletedUTF8.count } == Data(" 한글".utf8).count)
        view.redo()
        #expect(text(view) == "alpha 한글 beta")
        #expect(edits.last?.origin == .redo)

        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 5))
        #expect(view.addSelectionUTF8Range(NSRange(location: 13, length: 4)))
        #expect(view.selectionCount == 2)
        view.isWordWrapEnabled = false
        #expect(!view.isWordWrapEnabled)
        view.isWordWrapEnabled = true
        #expect(view.isWordWrapEnabled)
    }

    @Test @MainActor
    func koreanMarkedTextCopyPasteAndLargeUTF8RemainValid() throws {
        let view = makeHostedView()
        try view.loadUTF8(Data(), revision: 0)
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(text(view) == "한")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(" 붙여넣기", forType: .string)
        view.setPrimarySelectionUTF8Range(NSRange(location: 3, length: 0))
        view.paste()
        #expect(text(view) == "한 붙여넣기")
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 3))
        view.copySelection()
        #expect(NSPasteboard.general.string(forType: .string) == "한")

        let large = String(repeating: "Duckpad-한글-🦆\n", count: 40_000)
        try view.loadUTF8(Data(large.utf8), revision: 100)
        #expect(view.contentUTF8.count == large.utf8.count)
        #expect(text(view) == large)
    }

    @Test @MainActor
    func swiftAdapterPublishesRevisionCheckedIncrementalEdit() {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
        var received: EditorIncrementalEdit?
        adapter.onEdit = {
            received = $0
            return .accepted(newRevision: $0.expectedRevision + 1)
        }
        adapter.activeScintillaView?.insertCommittedText("🦆")
        #expect(received?.range == TextEditRange(location: 0, length: 0))
        #expect(received?.replacement == "🦆")
        #expect(adapter.snapshot(for: bufferID)?.text == "🦆")
        #expect(adapter.snapshot(for: bufferID)?.revision == 1)
    }

    @Test @MainActor
    func rejectedEditReplaysAcceptedDeltaJournalWithoutHotPathSnapshot() async {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
        adapter.onEdit = {
            $0.replacement == "A"
                ? .accepted(newRevision: $0.expectedRevision + 1)
                : .rejected(currentRevision: $0.expectedRevision)
        }
        let view = adapter.activeScintillaView!
        view.resetInstrumentation()
        view.insertCommittedText("A")
        #expect(view.snapshotReadCount == 0)
        view.insertCommittedText("B")
        for _ in 0..<200 where view.revision != 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(view.snapshotReadCount == 0)
        #expect(view.revision == 1)
        #expect(adapter.snapshot(for: bufferID)?.text == "A")
    }

    @Test @MainActor
    func recoverySnapshotUsesIncrementalUTF8AndRestoresViewStateWithoutFullRead() throws {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
        let text = (0..<30).map { "line \($0) 한글🙂" }.joined(separator: "\n")
        let view = try #require(adapter.activeScintillaView)
        view.insertCommittedText(text)
        view.restoreCaretUTF8Position(
            18,
            anchorPosition: 5,
            firstVisibleLine: 7,
            horizontalScrollOffset: 11,
            wordWrapEnabled: false
        )
        view.resetInstrumentation()

        let recovery = try #require(adapter.recoverySnapshot(for: bufferID))
        #expect(recovery.utf8 == Data(text.utf8))
        #expect(recovery.viewState.anchorUTF8 == 5)
        #expect(recovery.viewState.caretUTF8 == 18)
        #expect(recovery.viewState.wordWrapEnabled == false)
        #expect(view.snapshotReadCount == 0)

        let restored = ScintillaEditorAdapter()
        restored.installRecovery(recovery)
        restored.display(EditorBufferDescriptor(bufferID: bufferID, revision: 1))
        let restoredView = try #require(restored.activeScintillaView)
        #expect(restoredView.anchorUTF8Position == 5)
        #expect(restoredView.caretUTF8Position == 18)
        #expect(restoredView.isWordWrapEnabled == false)
        #expect(restored.recoverySnapshot(for: bufferID)?.utf8 == Data(text.utf8))
    }

    @Test @MainActor
    func directRecoveryInstallClampsUnsafeViewCoordinatesWithoutTrap() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        let bytes = Data("한🙂".utf8)
        adapter.installRecovery(EditorRecoverySnapshot(
            bufferID: bufferID,
            revision: 3,
            utf8: bytes,
            viewState: EditorViewState(
                anchorUTF8: 1,
                caretUTF8: Int.max,
                firstVisibleLine: -9,
                horizontalScrollOffset: -3,
                wordWrapEnabled: false
            )
        ))
        adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 3))
        let view = try #require(adapter.activeScintillaView)
        #expect(view.anchorUTF8Position == 0)
        #expect(view.caretUTF8Position == bytes.count)
        #expect(view.firstVisibleLine == 0)
        #expect(view.horizontalScrollOffset == 0)
        #expect(!view.isWordWrapEnabled)
    }

    @Test @MainActor
    func eachBufferKeepsItsOwnScintillaUndoState() {
        let adapter = ScintillaEditorAdapter()
        let first = BufferID()
        let second = BufferID()
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.display(EditorBufferDescriptor(bufferID: first, revision: 0))
        adapter.activeScintillaView?.insertCommittedText("A")
        adapter.display(EditorBufferDescriptor(bufferID: second, revision: 0))
        adapter.activeScintillaView?.insertCommittedText("B")
        adapter.retire(bufferID: second)
        adapter.display(EditorBufferDescriptor(bufferID: first, revision: 1))

        #expect(adapter.activeScintillaView?.canUndo == true)
        adapter.activeScintillaView?.undo()
        #expect(adapter.snapshot(for: first)?.text == "")
        #expect(adapter.snapshot(for: second) == nil)
    }

    @Test @MainActor
    func productionWindowBoundaryHostsAndFocusesScintilla() {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: adapter,
            editorView: adapter.view,
            automaticallyStarts: false
        )
        controller.showAndFocus()
        #expect(adapter.view.window === controller.window)
        #expect(adapter.view.isDescendant(of: controller.window!.contentView!))
        adapter.focus()
        #expect(adapter.activeScintillaView?.hasEditorFocus == true)
        controller.close()
    }

    @Test @MainActor
    func nativeLiteralSearchAndReservedReplaceAllUseUTF8AndOneUndoGroup() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let descriptor = try #require(workspace.snapshot().activeBuffer)
        adapter.install(EditorTextSnapshot(bufferID: descriptor.bufferID, revision: descriptor.revision, text: "한글 duck 🦆 duck"))
        adapter.display(descriptor)
        let port = adapter as any SearchEditorPort
        let first = try port.findActive(ActiveSearchRequest(
            patternUTF8: Data("duck".utf8),
            options: SearchOptions(matchCase: true),
            restrictTo: nil
        ))
        #expect(first == SearchUTF8Range(location: 7, length: 4))

        let search = SearchWorkspaceUseCase(workspace: workspace, editor: adapter, regexEngine: ICURegexEngine())
        let count = try await search.replaceAll(SearchQuery(pattern: "duck", replacement: "오리"))
        #expect(count == 2)
        #expect(adapter.snapshot(for: descriptor.bufferID)?.text == "한글 오리 🦆 오리")
        #expect(workspace.snapshot().activeBuffer?.revision == 2)
        #expect(workspace.snapshot().tabs.first?.isDirty == true)
        #expect(adapter.activeScintillaView?.canUndo == true)
        adapter.activeScintillaView?.undo()
        await Task.yield()
        #expect(adapter.snapshot(for: descriptor.bufferID)?.text == "한글 duck 🦆 duck")
        // Scintilla emits delete+insert for each of the two grouped inverse edits.
        #expect(workspace.snapshot().activeBuffer?.revision == 6)
        #expect(adapter.recoverySnapshot(for: descriptor.bufferID).flatMap { String(data: $0.utf8, encoding: .utf8) } == "한글 duck 🦆 duck")
        withExtendedLifetime(binding) {}
    }

    @Test @MainActor
    func cancelledReplaceAllWaitingForWorkspaceReservationNeverMutatesEditorOrRecovery() async throws {
        let store = DelayedSearchSessionStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        _ = await workspace.start()
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let tab = try #require(workspace.snapshot().tabs.first)
        adapter.install(EditorTextSnapshot(
            bufferID: tab.buffer.bufferID,
            revision: tab.buffer.revision,
            text: "duck duck"
        ))
        adapter.display(tab.buffer)
        let originalRecovery = try #require(adapter.recoverySnapshot(for: tab.buffer.bufferID))
        let originalCanUndo = adapter.activeScintillaView?.canUndo
        let search = SearchWorkspaceUseCase(
            workspace: workspace,
            editor: adapter,
            regexEngine: ICURegexEngine()
        )

        await store.arm()
        let blocker = Task { await workspace.setPinned(tab.id, isPinned: true) }
        await store.waitUntilBlocked()
        let replacement = Task {
            try await search.replaceAll(SearchQuery(pattern: "duck", replacement: "goose"))
        }
        await Task.yield()
        replacement.cancel()
        await store.release()
        _ = await blocker.value

        do {
            _ = try await replacement.value
            Issue.record("cancelled reservation waiter must not replace text")
        } catch let failure as SearchFailure {
            #expect(failure == .cancelled)
        }
        #expect(adapter.snapshot(for: tab.buffer.bufferID)?.text == "duck duck")
        #expect(workspace.snapshot().activeBuffer?.revision == tab.buffer.revision)
        #expect(adapter.activeScintillaView?.canUndo == originalCanUndo)
        #expect(adapter.recoverySnapshot(for: tab.buffer.bufferID) == originalRecovery)
        withExtendedLifetime(binding) {}
    }

    @Test @MainActor
    func activationCommittedBeforeReplaceReservationRejectsStaleTargetWithoutMutation() async throws {
        let store = DelayedSearchSessionStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        _ = await workspace.start()
        let first = try #require(workspace.snapshot().tabs.first)
        _ = await workspace.addScratch()
        let second = try #require(workspace.snapshot().tabs.last)
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        workspace.onChange = { binding.render($0) }
        adapter.install(EditorTextSnapshot(
            bufferID: second.buffer.bufferID,
            revision: second.buffer.revision,
            text: "duck duck"
        ))
        adapter.display(second.buffer)
        let originalRecovery = try #require(adapter.recoverySnapshot(for: second.buffer.bufferID))
        let search = SearchWorkspaceUseCase(
            workspace: workspace,
            editor: adapter,
            regexEngine: ICURegexEngine()
        )

        await store.arm()
        let activation = Task { await workspace.activate(tabID: first.id) }
        await store.waitUntilBlocked()
        let replacement = Task {
            try await search.replaceAll(SearchQuery(pattern: "duck", replacement: "goose"))
        }
        await Task.yield()
        await store.release()
        #expect(await activation.value == .applied(.saved))

        do {
            _ = try await replacement.value
            Issue.record("replacement captured before activation must be refused")
        } catch let failure as SearchFailure {
            #expect(failure == .staleRevision(expected: second.buffer.revision, actual: first.buffer.revision))
        }
        #expect(workspace.snapshot().activeBuffer?.bufferID == first.buffer.bufferID)
        #expect(adapter.snapshot(for: second.buffer.bufferID)?.text == "duck duck")
        #expect(adapter.recoverySnapshot(for: second.buffer.bufferID) == originalRecovery)
        #expect(adapter.activeScintillaView?.canUndo == false)
    }

    @Test @MainActor
    func directionalRegexWholeWordSkipsEmbeddedUnicodeWordCandidates() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let descriptor = try #require(workspace.snapshot().activeBuffer)
        let text = "duckling duck"
        adapter.install(EditorTextSnapshot(
            bufferID: descriptor.bufferID, revision: descriptor.revision, text: text
        ))
        adapter.display(descriptor)
        let view = try #require(adapter.activeScintillaView)
        let search = SearchWorkspaceUseCase(
            workspace: workspace, editor: adapter, regexEngine: ICURegexEngine()
        )

        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        var options = SearchOptions(
            mode: .regularExpression, matchCase: true, wholeWord: true,
            wrapAround: false, direction: .forward
        )
        #expect(try await search.find(SearchQuery(pattern: "duck", options: options)) == SearchUTF8Range(location: 9, length: 4))

        view.setPrimarySelectionUTF8Range(NSRange(location: text.utf8.count, length: 0))
        options.direction = .backward
        #expect(try await search.find(SearchQuery(pattern: "duck", options: options)) == SearchUTF8Range(location: 9, length: 4))

        view.setPrimarySelectionUTF8Range(NSRange(location: text.utf8.count, length: 0))
        options.direction = .forward
        options.wrapAround = true
        #expect(try await search.find(SearchQuery(pattern: "duck", options: options)) == SearchUTF8Range(location: 9, length: 4))
        withExtendedLifetime(binding) {}
    }

    @Test @MainActor
    func terminalZeroLengthRegexProgressesAndOnlyWrapsOncePerCommand() async throws {
        func fixture(_ text: String) async throws -> (
            SearchWorkspaceUseCase, ScintillaEditorAdapter, EditorBindingUseCase
        ) {
            let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
            _ = await workspace.start()
            let adapter = ScintillaEditorAdapter()
            let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
            let descriptor = try #require(workspace.snapshot().activeBuffer)
            adapter.install(EditorTextSnapshot(
                bufferID: descriptor.bufferID, revision: descriptor.revision, text: text
            ))
            adapter.display(descriptor)
            return (
                SearchWorkspaceUseCase(
                    workspace: workspace, editor: adapter, regexEngine: ICURegexEngine()
                ),
                adapter,
                binding
            )
        }

        let (endSearch, _, endBinding) = try await fixture("a")
        let noWrap = SearchOptions(
            mode: .regularExpression, matchCase: true,
            wrapAround: false, direction: .forward
        )
        #expect(try await endSearch.find(SearchQuery(pattern: "$", options: noWrap)) == SearchUTF8Range(location: 1, length: 0))
        #expect(try await endSearch.find(SearchQuery(pattern: "$", options: noWrap)) == nil)
        #expect(try await endSearch.find(SearchQuery(pattern: "$", options: noWrap)) == nil)
        var wrap = noWrap
        wrap.wrapAround = true
        #expect(try await endSearch.find(SearchQuery(pattern: "$", options: wrap)) == SearchUTF8Range(location: 1, length: 0))
        #expect(try await endSearch.find(SearchQuery(pattern: "$", options: wrap)) == SearchUTF8Range(location: 1, length: 0))
        withExtendedLifetime(endBinding) {}

        let (startSearch, startAdapter, startBinding) = try await fixture("a")
        startAdapter.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
        var backward = noWrap
        backward.direction = .backward
        #expect(try await startSearch.find(SearchQuery(pattern: "^", options: backward)) == SearchUTF8Range(location: 0, length: 0))
        #expect(try await startSearch.find(SearchQuery(pattern: "^", options: backward)) == nil)
        withExtendedLifetime(startBinding) {}

        let (lookSearch, _, lookBinding) = try await fixture("🦆🦆")
        #expect(try await lookSearch.find(SearchQuery(pattern: "(?=🦆)", options: noWrap)) == SearchUTF8Range(location: 0, length: 0))
        #expect(try await lookSearch.find(SearchQuery(pattern: "(?=🦆)", options: noWrap)) == SearchUTF8Range(location: 4, length: 0))
        #expect(try await lookSearch.find(SearchQuery(pattern: "(?=🦆)", options: noWrap)) == nil)
        withExtendedLifetime(lookBinding) {}

        let (emptySearch, _, emptyBinding) = try await fixture("")
        #expect(try await emptySearch.find(SearchQuery(pattern: "^$", options: noWrap)) == SearchUTF8Range(location: 0, length: 0))
        #expect(try await emptySearch.find(SearchQuery(pattern: "^$", options: noWrap)) == nil)
        withExtendedLifetime(emptyBinding) {}
    }

    @Test @MainActor
    func selectionReplaceAllAndReplaceCurrentKeepOriginalSearchScope() async throws {
        func fixture() async throws -> (
            ScratchWorkspaceUseCase, ScintillaEditorAdapter,
            EditorBindingUseCase, SearchWorkspaceUseCase
        ) {
            let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
            _ = await workspace.start()
            let adapter = ScintillaEditorAdapter()
            let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
            let descriptor = try #require(workspace.snapshot().activeBuffer)
            adapter.install(EditorTextSnapshot(
                bufferID: descriptor.bufferID, revision: descriptor.revision,
                text: "duck x duck y duck"
            ))
            adapter.display(descriptor)
            adapter.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 11))
            return (
                workspace, adapter, binding,
                SearchWorkspaceUseCase(
                    workspace: workspace, editor: adapter, regexEngine: ICURegexEngine()
                )
            )
        }
        let options = SearchOptions(
            mode: .regularExpression, matchCase: true, wrapAround: false,
            direction: .forward, scope: .selection
        )

        let (allWorkspace, allAdapter, allBinding, allSearch) = try await fixture()
        #expect(try await allSearch.find(SearchQuery(pattern: "duck", options: options)) == SearchUTF8Range(location: 0, length: 4))
        let replaced = try await allSearch.replaceAll(
            SearchQuery(pattern: "duck", replacement: "goose", options: options)
        )
        #expect(replaced == 2)
        #expect(allAdapter.snapshot(for: allWorkspace.snapshot().activeBuffer!.bufferID)?.text == "goose x goose y duck")
        withExtendedLifetime(allBinding) {}

        let (oneWorkspace, oneAdapter, oneBinding, oneSearch) = try await fixture()
        #expect(try await oneSearch.find(SearchQuery(pattern: "duck", options: options)) == SearchUTF8Range(location: 0, length: 4))
        let next = try await oneSearch.replaceCurrentThenFind(
            SearchQuery(pattern: "duck", replacement: "goose", options: options)
        )
        #expect(next == SearchUTF8Range(location: 8, length: 4))
        #expect(oneAdapter.snapshot(for: oneWorkspace.snapshot().activeBuffer!.bufferID)?.text == "goose x duck y duck")
        withExtendedLifetime(oneBinding) {}
    }

    @Test @MainActor
    func selectionOperationsFailClosedWhenNoNonemptyScopeExists() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let descriptor = try #require(workspace.snapshot().activeBuffer)
        adapter.install(EditorTextSnapshot(
            bufferID: descriptor.bufferID, revision: descriptor.revision,
            text: "duck duck"
        ))
        adapter.display(descriptor)
        adapter.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        let search = SearchWorkspaceUseCase(
            workspace: workspace, editor: adapter, regexEngine: ICURegexEngine()
        )
        let query = SearchQuery(
            pattern: "duck", replacement: "goose",
            options: SearchOptions(
                mode: .regularExpression, matchCase: true,
                wrapAround: false, scope: .selection
            )
        )
        let originalText = adapter.snapshot(for: descriptor.bufferID)
        let originalRevision = workspace.snapshot().activeBuffer?.revision
        let originalUndo = adapter.activeScintillaView?.canUndo
        let originalRecovery = adapter.recoverySnapshot(for: descriptor.bufferID)

        do { _ = try await search.find(query); Issue.record("Find must require a non-empty selection") }
        catch let failure as SearchFailure { #expect(failure == .noSelection) }
        do { _ = try await search.findAll(query); Issue.record("Find All must require a non-empty selection") }
        catch let failure as SearchFailure { #expect(failure == .noSelection) }
        do { _ = try await search.replaceCurrentThenFind(query); Issue.record("Replace must require a non-empty selection") }
        catch let failure as SearchFailure { #expect(failure == .noSelection) }
        do { _ = try await search.replaceAll(query); Issue.record("Replace All must require a non-empty selection") }
        catch let failure as SearchFailure { #expect(failure == .noSelection) }

        #expect(adapter.snapshot(for: descriptor.bufferID) == originalText)
        #expect(workspace.snapshot().activeBuffer?.revision == originalRevision)
        #expect(adapter.activeScintillaView?.canUndo == originalUndo)
        #expect(adapter.recoverySnapshot(for: descriptor.bufferID) == originalRecovery)
        withExtendedLifetime(binding) {}
    }

    @Test @MainActor
    func revisionInvalidatedSelectionCannotFallThroughToWholeDocumentReplacement() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let descriptor = try #require(workspace.snapshot().activeBuffer)
        adapter.install(EditorTextSnapshot(
            bufferID: descriptor.bufferID, revision: descriptor.revision,
            text: "duck x duck y duck"
        ))
        adapter.display(descriptor)
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 11))
        let search = SearchWorkspaceUseCase(
            workspace: workspace, editor: adapter, regexEngine: ICURegexEngine()
        )
        let query = SearchQuery(
            pattern: "duck", replacement: "goose",
            options: SearchOptions(
                mode: .regularExpression, matchCase: true,
                wrapAround: false, scope: .selection
            )
        )
        #expect(try await search.find(query) == SearchUTF8Range(location: 0, length: 4))

        view.setPrimarySelectionUTF8Range(NSRange(location: Int(view.documentByteLength), length: 0))
        view.insertCommittedText("!")
        await workspace.waitForPendingPersistence()
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        let acceptedText = adapter.snapshot(for: descriptor.bufferID)
        let acceptedRevision = workspace.snapshot().activeBuffer?.revision
        let acceptedRecovery = adapter.recoverySnapshot(for: descriptor.bufferID)
        #expect(adapter.activeScintillaView?.canUndo == true)

        do {
            _ = try await search.replaceAll(query)
            Issue.record("stale retained scope plus collapsed selection must fail closed")
        } catch let failure as SearchFailure {
            #expect(failure == .invalidSelection)
        }
        #expect(adapter.snapshot(for: descriptor.bufferID) == acceptedText)
        #expect(workspace.snapshot().activeBuffer?.revision == acceptedRevision)
        #expect(adapter.activeScintillaView?.canUndo == true)
        #expect(adapter.recoverySnapshot(for: descriptor.bufferID) == acceptedRecovery)

        view.undo()
        await Task.yield()
        #expect(adapter.snapshot(for: descriptor.bufferID)?.text == "duck x duck y duck")
        withExtendedLifetime(binding) {}
    }

    @Test
    func publicFacadeDoesNotExposeRawScintillaSurface() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let header = try String(contentsOf: root.appendingPathComponent(
            "Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h"
        ))
        for forbidden in ["SCI_", "SCNotification", "ScintillaView", "sptr_t", "void *", "ILexer"] {
            #expect(!header.contains(forbidden))
        }
    }

    @MainActor
    private func makeHostedView() -> DPScintillaEditorView {
        _ = NSApplication.shared
        ScintillaEditorAdapter.prepareResources()
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderOut(nil)
        return view
    }

    @MainActor
    private func text(_ view: DPScintillaEditorView) -> String? {
        String(data: view.contentUTF8, encoding: .utf8)
    }
}
