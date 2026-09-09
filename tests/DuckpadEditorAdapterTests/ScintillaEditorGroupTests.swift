import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
struct ScintillaEditorGroupTests {
    @Test @MainActor func fourClonesHaveIndependentViewsAndPublishEachEditOnce() throws {
        let adapter = ScintillaEditorAdapter()
        defer { adapter.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "base"))
        adapter.display(buffer)
        adapter.setEditorGroupOrientation(.sideBySide)
        var views: [DPScintillaEditorView] = []
        for group in EditorGroupID.allCases {
            adapter.assign(buffer, from: .primary, to: group, cloning: true)
            adapter.display(buffer, in: group)
            adapter.activateEditorGroup(group)
            views.append(try #require(adapter.activeScintillaView))
        }
        #expect(Set(views.map(ObjectIdentifier.init)).count == 4)
        #expect(views.allSatisfy { $0.superview != nil })
        var edits = 0
        adapter.onEdit = { edit in edits += 1; return .accepted(newRevision: edit.expectedRevision + 1) }
        views[3].setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
        views[3].insertCommittedText("!")
        #expect(edits == 1)
        #expect(views.allSatisfy { $0.contentUTF8 == Data("base!".utf8) })
        views[2].undo()
        #expect(edits == 2)
        #expect(views.allSatisfy { $0.contentUTF8 == Data("base".utf8) })
    }

    @Test @MainActor
    func distinctBuffersRemainVisibleAndNormalDisplayRoutesThroughTheActiveGroup() throws {
        let adapter = ScintillaEditorAdapter()
        let primaryRoot = adapter.view
        let secondaryRoot = adapter.secondaryGroupView
        let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let replacement = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: first.bufferID, revision: 0, text: "first"))
        adapter.install(.init(bufferID: second.bufferID, revision: 0, text: "second"))
        adapter.install(.init(bufferID: replacement.bufferID, revision: 0, text: "replacement"))
        adapter.display(first)
        let firstView = try #require(adapter.activeScintillaView)

        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(second, from: nil, to: .secondary, cloning: false)
        adapter.display(second, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondView = try #require(adapter.activeScintillaView)

        #expect(adapter.view === primaryRoot)
        #expect(adapter.secondaryGroupView === secondaryRoot)
        #expect(adapter.hasVisibleGroups)
        #expect(adapter.editorGroupOrientation == .sideBySide)
        #expect(firstView !== secondView)
        #expect(firstView.contentUTF8 == Data("first".utf8))
        #expect(secondView.contentUTF8 == Data("second".utf8))

        adapter.display(replacement)

        #expect(adapter.activeEditorGroup == .secondary)
        #expect(adapter.activeScintillaView?.contentUTF8 == Data("replacement".utf8))
        #expect(firstView.contentUTF8 == Data("first".utf8))
        #expect(secondView.superview == nil)
    }

    @Test @MainActor
    func focusedCloneRedisplayKeepsTheSameNativeViewAndFirstResponder() throws {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        adapter.view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        adapter.secondaryGroupView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let host = NSStackView(views: [adapter.view, adapter.secondaryGroupView])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "shared"))
        adapter.display(buffer)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        secondary.focusEditor()
        let responder = try #require(window.firstResponder)
        #expect(secondary.hasEditorFocus)

        adapter.display(buffer, in: .secondary)

        #expect(adapter.activeScintillaView === secondary)
        #expect(window.firstResponder === responder)
        #expect(secondary.hasEditorFocus)
        #expect(secondary.superview === adapter.secondaryGroupView)
    }

    @Test @MainActor
    func clonePublishesEachSharedDocumentEditOnceAndSharesNativeUndoRedo() throws {
        let adapter = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "base"))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        var acceptedEdits: [EditorIncrementalEdit] = []
        adapter.onEdit = {
            acceptedEdits.append($0)
            return .accepted(newRevision: $0.expectedRevision + 1)
        }

        primary.setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
        primary.insertCommittedText("A")
        secondary.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 0))
        secondary.insertCommittedText("B")
        primary.undo()
        secondary.undo()
        primary.redo()
        secondary.redo()

        #expect(primary !== secondary)
        #expect(primary.contentUTF8 == Data("baseAB".utf8))
        #expect(secondary.contentUTF8 == Data("baseAB".utf8))
        #expect(acceptedEdits.count == 6)
        #expect(adapter.recoveryJournalAppendCount == 6)
        let capture = try #require(adapter.recoveryCapture(for: buffer.bufferID))
        #expect(capture.deltas.count == 6)
        #expect(try capture.materializedSnapshot().utf8 == Data("baseAB".utf8))
        #expect(capture.viewState.secondaryViewState == nil)
        #expect(capture.viewState.splitOrientation == nil)
        let terminationSnapshot = try #require(adapter.recoverySnapshot(for: buffer.bufferID))
        #expect(terminationSnapshot.utf8 == Data("baseAB".utf8))
        #expect(terminationSnapshot.viewState.secondaryViewState == nil)
        #expect(terminationSnapshot.viewState.splitOrientation == nil)

        let saveSnapshot = try #require(adapter.snapshot(for: buffer.bufferID))
        #expect(saveSnapshot.text == "baseAB")
        #expect(saveSnapshot.revision == 6)
        let captureAfterSave = try #require(adapter.recoveryCapture(for: buffer.bufferID))
        #expect(captureAfterSave.baseUTF8 == Data("baseAB".utf8))
        #expect(captureAfterSave.baseRevision == 6)
        #expect(captureAfterSave.deltas.isEmpty)

        adapter.setEditorGroupOrientation(nil)
        let closedRecovery = try #require(adapter.recoverySnapshot(for: buffer.bufferID))
        #expect(closedRecovery.viewState.splitOrientation == nil)
        #expect(closedRecovery.viewState.secondaryViewState == nil)
        let restored = ScintillaEditorAdapter()
        restored.installRecovery(closedRecovery)
        restored.display(.init(bufferID: buffer.bufferID, revision: closedRecovery.revision))
        #expect(restored.activeScintillaView?.contentUTF8 == Data("baseAB".utf8))
        #expect(restored.splitOrientation == nil)
    }

    @Test @MainActor
    func currentGroupRedisplayPreservesCheckpointUndoAndRejectedEditRecovery() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        let initial = EditorBufferDescriptor(bufferID: bufferID, revision: 0)
        adapter.install(.init(bufferID: bufferID, revision: 0, text: "base"))
        adapter.display(initial)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(initial, from: .primary, to: .secondary, cloning: true)
        adapter.display(initial, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        adapter.onEdit = { edit in
            edit.replacement == "X"
                ? .rejected(currentRevision: edit.expectedRevision)
                : .accepted(newRevision: edit.expectedRevision + 1)
        }

        secondary.setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
        secondary.insertCommittedText("A")
        adapter.display(.init(bufferID: bufferID, revision: 1))

        #expect(primary.contentUTF8 == Data("baseA".utf8))
        #expect(secondary.contentUTF8 == Data("baseA".utf8))
        #expect(primary.revision == 1)
        #expect(secondary.revision == 1)
        #expect(secondary.canUndo)

        secondary.undo()
        primary.redo()
        #expect(primary.contentUTF8 == Data("baseA".utf8))
        #expect(primary.revision == 3)
        #expect(secondary.revision == 3)

        secondary.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 0))
        secondary.insertCommittedText("X")
        let recovery = try #require(adapter.recoverySnapshot(for: bufferID))

        #expect(recovery.revision == 3)
        #expect(recovery.utf8 == Data("baseA".utf8))
        #expect(primary.contentUTF8 == Data("baseA".utf8))
        #expect(secondary.contentUTF8 == Data("baseA".utf8))
        #expect(primary.revision == 3)
        #expect(secondary.revision == 3)
        #expect(primary.isInputEnabled)
        #expect(secondary.isInputEnabled)
        let saved = try #require(adapter.snapshot(for: bufferID))
        #expect(saved.revision == 3)
        #expect(saved.text == "baseA")
    }

    @Test @MainActor
    func staleGroupRedisplayDoesNotMutateSharedBytesRevisionOrUndo() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        let initial = EditorBufferDescriptor(bufferID: bufferID, revision: 0)
        adapter.install(.init(bufferID: bufferID, revision: 0, text: "base"))
        adapter.display(initial)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(initial, from: .primary, to: .secondary, cloning: true)
        adapter.display(initial, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

        secondary.setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
        secondary.insertCommittedText("A")
        adapter.display(initial)

        #expect(primary.contentUTF8 == Data("baseA".utf8))
        #expect(secondary.contentUTF8 == Data("baseA".utf8))
        #expect(primary.revision == 1)
        #expect(secondary.revision == 1)
        #expect(secondary.canUndo)

        secondary.undo()
        #expect(primary.contentUTF8 == Data("base".utf8))
        #expect(primary.revision == 2)
        #expect(secondary.revision == 2)
        primary.redo()
        #expect(secondary.contentUTF8 == Data("baseA".utf8))
        #expect(primary.revision == 3)
        #expect(secondary.revision == 3)
        let recovery = try #require(adapter.recoverySnapshot(for: bufferID))
        #expect(recovery.revision == 3)
        #expect(recovery.utf8 == Data("baseA".utf8))
        let saved = try #require(adapter.snapshot(for: bufferID))
        #expect(saved.revision == 3)
        #expect(saved.text == "baseA")
    }

    @Test @MainActor
    func rejectedEditIsRecoveredBeforeImmediateGroupEntryCapturesState() throws {
        let adapter = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "base"))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

        primary.setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
        primary.insertCommittedText("X")
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        let recovery = try #require(adapter.recoverySnapshot(for: buffer.bufferID))

        #expect(adapter.hasVisibleGroups)
        #expect(primary.contentUTF8 == Data("base".utf8))
        #expect(secondary.contentUTF8 == Data("base".utf8))
        #expect(primary.revision == 0)
        #expect(secondary.revision == 0)
        #expect(primary.isInputEnabled)
        #expect(secondary.isInputEnabled)
        #expect(recovery.revision == 0)
        #expect(recovery.utf8 == Data("base".utf8))
    }

    @Test @MainActor
    func rejectedGroupEditRestoresEachViewsSelectionScrollAndFoldState() throws {
        _ = NSApplication.shared
        let source = (["{"] + (0..<80).map {
            "\"key\($0)\": \($0)," + String(repeating: " ", count: 120)
        } + ["\"last\": 0", "}"]).joined(separator: "\n")
        let adapter = ScintillaEditorAdapter()
        adapter.view.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        adapter.secondaryGroupView.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        let host = NSStackView(views: [adapter.view, adapter.secondaryGroupView])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: source))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"), lexerName: "json",
            indentation: .init(width: 4), folding: true, braceMatching: true
        )))
        #expect(primary.restoreContractedFoldHeaderLines([0]).isEmpty)
        primary.restoreCaretUTF8Position(
            2, anchorPosition: 5, firstVisibleLine: 12,
            horizontalScrollOffset: 7, wordWrapEnabled: false
        )
        let preInputOffset = source.utf8.count
        secondary.restoreCaretUTF8Position(
            UInt(preInputOffset), anchorPosition: UInt(preInputOffset), firstVisibleLine: 24,
            horizontalScrollOffset: 11, wordWrapEnabled: false
        )
        let primaryFirstVisibleLine = primary.firstVisibleLine
        let primaryHorizontalScrollOffset = primary.horizontalScrollOffset
        let secondaryFirstVisibleLine = secondary.firstVisibleLine
        let secondaryHorizontalScrollOffset = secondary.horizontalScrollOffset
        _ = adapter.recoveryCapture(for: buffer.bufferID)
        adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

        secondary.insertCommittedText("!")
        let recovery = try #require(adapter.recoverySnapshot(for: buffer.bufferID))

        #expect(primary.contentUTF8 == Data(source.utf8))
        #expect(secondary.contentUTF8 == Data(source.utf8))
        #expect(primary.caretUTF8Position == 2)
        #expect(primary.anchorUTF8Position == 5)
        #expect(primary.firstVisibleLine == primaryFirstVisibleLine)
        #expect(primary.horizontalScrollOffset == primaryHorizontalScrollOffset)
        #expect(primary.hasContractedFolds)
        #expect(secondary.caretUTF8Position == preInputOffset)
        #expect(secondary.anchorUTF8Position == preInputOffset)
        #expect(secondary.firstVisibleLine == secondaryFirstVisibleLine)
        #expect(secondary.horizontalScrollOffset == secondaryHorizontalScrollOffset)
        #expect(!secondary.hasContractedFolds)
        #expect(primary.isInputEnabled)
        #expect(secondary.isInputEnabled)
        #expect(recovery.viewState.secondaryViewState == nil)
        #expect(recovery.viewState.splitOrientation == nil)
    }

    @Test @MainActor
    func rejectedGroupCloserRestoresInitiatorAndPeerStateWithoutEncodingAPeer() throws {
        let source = "{\n    "
        let adapter = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: source))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"), lexerName: "json",
            indentation: .init(width: 4), folding: true, braceMatching: true
        )))
        #expect(primary.restoreContractedFoldHeaderLines([0]).isEmpty)
        primary.restoreCaretUTF8Position(
            0, anchorPosition: 1, firstVisibleLine: 0,
            horizontalScrollOffset: 0, wordWrapEnabled: true
        )
        let preInputOffset = source.utf8.count
        secondary.setPrimarySelectionUTF8Range(NSRange(location: preInputOffset, length: 0))
        adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

        secondary.insertCommittedText("}")
        let recovery = try #require(adapter.recoverySnapshot(for: buffer.bufferID))

        #expect(primary.contentUTF8 == Data(source.utf8))
        #expect(secondary.contentUTF8 == Data(source.utf8))
        #expect(primary.revision == 0)
        #expect(secondary.revision == 0)
        #expect(primary.caretUTF8Position == 0)
        #expect(primary.anchorUTF8Position == 1)
        #expect(primary.hasContractedFolds)
        #expect(secondary.caretUTF8Position == preInputOffset)
        #expect(secondary.anchorUTF8Position == preInputOffset)
        #expect(!secondary.hasContractedFolds)
        #expect(adapter.activeScintillaView === secondary)
        #expect(recovery.utf8 == Data(source.utf8))
        #expect(recovery.viewState.secondaryViewState == nil)
        #expect(recovery.viewState.splitOrientation == nil)
    }

    @Test @MainActor
    func rejectedForwardAndReverseSelectedDeletionsRestoreExactGroupState() throws {
        for isReversed in [false, true] {
            let fixture = try makeClonedGroup(source: "0123456789")
            fixture.primary.restoreCaretUTF8Position(
                8, anchorPosition: 6, firstVisibleLine: 0,
                horizontalScrollOffset: 0, wordWrapEnabled: true
            )
            let expectedAnchor = isReversed ? 5 : 2
            let expectedCaret = isReversed ? 2 : 5
            fixture.secondary.restoreCaretUTF8Position(
                UInt(expectedCaret), anchorPosition: UInt(expectedAnchor), firstVisibleLine: 0,
                horizontalScrollOffset: 0, wordWrapEnabled: true
            )
            fixture.adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

            fixture.secondary.deleteSelectionOrNextCharacter()
            let recovery = try #require(
                fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)
            )

            #expect(fixture.primary.contentUTF8 == Data("0123456789".utf8))
            #expect(fixture.secondary.contentUTF8 == Data("0123456789".utf8))
            #expect(fixture.primary.anchorUTF8Position == 6)
            #expect(fixture.primary.caretUTF8Position == 8)
            #expect(fixture.secondary.anchorUTF8Position == expectedAnchor)
            #expect(fixture.secondary.caretUTF8Position == expectedCaret)
            #expect(fixture.primary.revision == 0)
            #expect(fixture.secondary.revision == 0)
            #expect(recovery.revision == 0)
            #expect(recovery.utf8 == Data("0123456789".utf8))
            let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))
            #expect(saved.revision == 0)
            #expect(saved.text == "0123456789")
        }
    }

    @Test @MainActor
    func rejectedBackwardAndForwardDeletesRestoreExactGroupState() throws {
        _ = NSApplication.shared
        for deletesBackward in [false, true] {
            let fixture = try makeClonedGroup(source: "0123456789")
            let host = NSStackView(views: [
                fixture.adapter.view,
                fixture.adapter.secondaryGroupView
            ])
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            fixture.secondary.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 0))
            fixture.secondary.focusEditor()
            fixture.adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

            if deletesBackward {
                window.firstResponder?.tryToPerform(
                    #selector(NSText.deleteBackward(_:)),
                    with: nil
                )
            } else {
                fixture.secondary.deleteSelectionOrNextCharacter()
            }
            let recovery = try #require(
                fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)
            )
            window.orderOut(nil)

            #expect(fixture.primary.contentUTF8 == Data("0123456789".utf8))
            #expect(fixture.secondary.contentUTF8 == Data("0123456789".utf8))
            #expect(fixture.secondary.anchorUTF8Position == 5)
            #expect(fixture.secondary.caretUTF8Position == 5)
            #expect(fixture.primary.revision == 0)
            #expect(fixture.secondary.revision == 0)
            #expect(recovery.revision == 0)
            #expect(recovery.utf8 == Data("0123456789".utf8))
            let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))
            #expect(saved.revision == 0)
            #expect(saved.text == "0123456789")
        }
    }

    @Test @MainActor
    func rejectedSelectedReplacementRestoresExactForwardSelectionInBothViews() throws {
        let fixture = try makeClonedGroup(source: "0123456789")
        fixture.primary.restoreCaretUTF8Position(
            3, anchorPosition: 7, firstVisibleLine: 0,
            horizontalScrollOffset: 0, wordWrapEnabled: true
        )
        fixture.secondary.restoreCaretUTF8Position(
            6, anchorPosition: 2, firstVisibleLine: 0,
            horizontalScrollOffset: 0, wordWrapEnabled: true
        )
        fixture.adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

        fixture.secondary.insertCommittedText("XY")
        let recovery = try #require(
            fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)
        )

        #expect(fixture.primary.contentUTF8 == Data("0123456789".utf8))
        #expect(fixture.secondary.contentUTF8 == Data("0123456789".utf8))
        #expect(fixture.primary.anchorUTF8Position == 7)
        #expect(fixture.primary.caretUTF8Position == 3)
        #expect(fixture.secondary.anchorUTF8Position == 2)
        #expect(fixture.secondary.caretUTF8Position == 6)
        #expect(fixture.primary.revision == 0)
        #expect(fixture.secondary.revision == 0)
        #expect(recovery.revision == 0)
        #expect(recovery.utf8 == Data("0123456789".utf8))
        let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))
        #expect(saved.revision == 0)
        #expect(saved.text == "0123456789")
    }

    @Test @MainActor
    func rejectedNewlineBeforeBookmarkAndFoldRestoresExactPreMutationLines() throws {
        let source = "prefix\n{\n  \"key\": 1\n}\nsuffix"
        let fixture = try makeClonedGroup(source: source)
        #expect(fixture.adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"), lexerName: "json",
            indentation: .init(width: 2), folding: true, braceMatching: true
        )))
        #expect(fixture.primary.restoreContractedFoldHeaderLines([1]).isEmpty)
        #expect(fixture.secondary.restoreContractedFoldHeaderLines([1]).isEmpty)
        fixture.primary.restoreBookmarkedLines([2])
        fixture.primary.restoreCaretUTF8Position(
            4, anchorPosition: 1, firstVisibleLine: 0,
            horizontalScrollOffset: 0, wordWrapEnabled: true
        )
        fixture.secondary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        fixture.adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

        fixture.secondary.insertCommittedText("\n")
        let recovery = try #require(
            fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)
        )

        #expect(fixture.primary.contentUTF8 == Data(source.utf8))
        #expect(fixture.secondary.contentUTF8 == Data(source.utf8))
        #expect(fixture.primary.anchorUTF8Position == 1)
        #expect(fixture.primary.caretUTF8Position == 4)
        #expect(fixture.secondary.anchorUTF8Position == 0)
        #expect(fixture.secondary.caretUTF8Position == 0)
        #expect(fixture.primary.bookmarkedLines.map(\.intValue) == [2])
        #expect(fixture.secondary.bookmarkedLines.map(\.intValue) == [2])
        #expect(fixture.primary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [1])
        #expect(fixture.secondary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [1])
        #expect(fixture.primary.revision == 0)
        #expect(fixture.secondary.revision == 0)
        #expect(recovery.revision == 0)
        #expect(recovery.utf8 == Data(source.utf8))
        #expect(recovery.viewState.bookmarkedLines == [2])
        #expect(recovery.viewState.foldState.contractedHeaderLines == [1])
        #expect(recovery.viewState.secondaryViewState == nil)
        let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))
        #expect(saved.revision == 0)
        #expect(saved.text == source)
    }

    @Test @MainActor
    func rejectedIndentationAfterAcceptedGroupCloserKeepsPostCloserViewState() throws {
        let source = "{\n      "
        let fixture = try makeClonedGroup(source: source)
        #expect(fixture.adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"), lexerName: "json",
            indentation: .init(width: 4), folding: true, braceMatching: true
        )))
        #expect(fixture.primary.restoreContractedFoldHeaderLines([0]).isEmpty)
        fixture.primary.restoreBookmarkedLines([1])
        fixture.primary.restoreCaretUTF8Position(
            0, anchorPosition: 1, firstVisibleLine: 0,
            horizontalScrollOffset: 0, wordWrapEnabled: true
        )
        let postCloserCaret = source.utf8.count + 1
        fixture.secondary.setPrimarySelectionUTF8Range(
            NSRange(location: source.utf8.count, length: 0)
        )
        var acceptedEdits: [EditorIncrementalEdit] = []
        fixture.adapter.onEdit = { edit in
            if acceptedEdits.isEmpty {
                acceptedEdits.append(edit)
                return .accepted(newRevision: edit.expectedRevision + 1)
            }
            return .rejected(currentRevision: edit.expectedRevision)
        }

        fixture.secondary.insertCommittedText("}")
        let recoveryCapture = try #require(
            fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID)
        )
        let recovery = try recoveryCapture.materializedSnapshot()

        #expect(acceptedEdits.count == 1)
        #expect(acceptedEdits.first?.replacement == "}")
        #expect(fixture.adapter.recoveryJournalAppendCount == 1)
        #expect(recoveryCapture.baseRevision == 1)
        #expect(recoveryCapture.deltas.isEmpty)
        #expect(fixture.primary.contentUTF8 == Data((source + "}").utf8))
        #expect(fixture.secondary.contentUTF8 == Data((source + "}").utf8))
        #expect(fixture.primary.anchorUTF8Position == 1)
        #expect(fixture.primary.caretUTF8Position == 0)
        #expect(fixture.primary.bookmarkedLines.map(\.intValue) == [1])
        #expect(fixture.primary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [0])
        #expect(fixture.secondary.anchorUTF8Position == postCloserCaret)
        #expect(fixture.secondary.caretUTF8Position == postCloserCaret)
        #expect(fixture.primary.revision == 1)
        #expect(fixture.secondary.revision == 1)
        #expect(recovery.revision == 1)
        #expect(recovery.utf8 == Data((source + "}").utf8))
        #expect(recovery.viewState.bookmarkedLines == [1])
        #expect(recovery.viewState.foldState.contractedHeaderLines == [0])
        #expect(recovery.viewState.secondaryViewState == nil)
        let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))
        #expect(saved.revision == 1)
        #expect(saved.text == source + "}")
    }

    @Test @MainActor
    func reentrantGroupCloseAfterRejectedDeletionRestoresStateAndSuspendedSplit() async throws {
        let source = "prefix\n{\n  \"key\": 1\n}\nsuffix"
        let fixture = try makeClonedGroupWithSuspendedSplit(source: source)
        #expect(fixture.adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"), lexerName: "json",
            indentation: .init(width: 2), folding: true, braceMatching: true
        )))
        #expect(fixture.primary.restoreContractedFoldHeaderLines([1]).isEmpty)
        fixture.primary.restoreBookmarkedLines([2])
        fixture.primary.restoreCaretUTF8Position(
            10, anchorPosition: 20, firstVisibleLine: 0,
            horizontalScrollOffset: 0, wordWrapEnabled: true
        )
        fixture.secondary.setPrimarySelectionUTF8Range(
            NSRange(location: 0, length: "prefix\n".utf8.count)
        )
        fixture.adapter.onEdit = { edit in
            fixture.adapter.setEditorGroupOrientation(nil)
            return .rejected(currentRevision: edit.expectedRevision)
        }

        fixture.secondary.deleteSelectionOrNextCharacter()
        for _ in 0..<10 where fixture.adapter.hasVisibleGroups {
            await Task.yield()
        }
        let recovery = try #require(
            fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)
        )
        let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))

        #expect(!fixture.adapter.hasVisibleGroups)
        #expect(fixture.adapter.splitOrientation == .stacked)
        #expect(fixture.primary.contentUTF8 == Data(source.utf8))
        #expect(fixture.primary.revision == 0)
        #expect(fixture.primary.anchorUTF8Position == 20)
        #expect(fixture.primary.caretUTF8Position == 10)
        #expect(fixture.primary.bookmarkedLines.map(\.intValue) == [2])
        #expect(fixture.primary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [1])
        #expect(recovery.revision == 0)
        #expect(recovery.utf8 == Data(source.utf8))
        #expect(recovery.viewState.anchorUTF8 == 20)
        #expect(recovery.viewState.caretUTF8 == 10)
        #expect(recovery.viewState.bookmarkedLines == [2])
        #expect(recovery.viewState.foldState.contractedHeaderLines == [1])
        #expect(recovery.viewState.splitOrientation == .stacked)
        #expect(recovery.viewState.secondaryViewState == fixture.suspendedSecondaryState)
        #expect(saved.revision == 0)
        #expect(saved.text == source)
    }

    @Test @MainActor
    func closeRequestedByAcceptedGroupCloserWaitsForRejectedSmartDedent() async throws {
        let source = "{\n      "
        let fixture = try makeClonedGroupWithSuspendedSplit(source: source)
        #expect(fixture.adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"), lexerName: "json",
            indentation: .init(width: 4), folding: true, braceMatching: true
        )))
        #expect(fixture.primary.restoreContractedFoldHeaderLines([0]).isEmpty)
        fixture.primary.restoreBookmarkedLines([1])
        fixture.primary.restoreCaretUTF8Position(
            3, anchorPosition: 7, firstVisibleLine: 0,
            horizontalScrollOffset: 0, wordWrapEnabled: true
        )
        fixture.secondary.setPrimarySelectionUTF8Range(
            NSRange(location: source.utf8.count, length: 0)
        )
        var editCount = 0
        fixture.adapter.onEdit = { edit in
            editCount += 1
            if editCount == 1 {
                fixture.adapter.setEditorGroupOrientation(nil)
                return .accepted(newRevision: edit.expectedRevision + 1)
            }
            return .rejected(currentRevision: edit.expectedRevision)
        }

        fixture.secondary.insertCommittedText("}")
        for _ in 0..<10 where fixture.adapter.hasVisibleGroups {
            await Task.yield()
        }
        let recoveryCapture = try #require(
            fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID)
        )
        let recovery = try recoveryCapture.materializedSnapshot()
        let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))

        #expect(editCount == 2)
        #expect(fixture.adapter.recoveryJournalAppendCount == 1)
        #expect(!fixture.adapter.hasVisibleGroups)
        #expect(fixture.adapter.splitOrientation == .stacked)
        #expect(fixture.primary.contentUTF8 == Data((source + "}").utf8))
        #expect(fixture.primary.revision == 1)
        #expect(fixture.primary.anchorUTF8Position == 7)
        #expect(fixture.primary.caretUTF8Position == 3)
        #expect(fixture.primary.bookmarkedLines.map(\.intValue) == [1])
        #expect(fixture.primary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [0])
        #expect(recoveryCapture.baseRevision == 1)
        #expect(recoveryCapture.deltas.isEmpty)
        #expect(recovery.revision == 1)
        #expect(recovery.utf8 == Data((source + "}").utf8))
        #expect(recovery.viewState.anchorUTF8 == 7)
        #expect(recovery.viewState.caretUTF8 == 3)
        #expect(recovery.viewState.bookmarkedLines == [1])
        #expect(recovery.viewState.foldState.contractedHeaderLines == [0])
        #expect(recovery.viewState.splitOrientation == .stacked)
        #expect(recovery.viewState.secondaryViewState == fixture.suspendedSecondaryState)
        #expect(saved.revision == 1)
        #expect(saved.text == source + "}")
    }

    @Test @MainActor
    func reentrantCloseAfterRejectedProgrammaticReplacementRestoresGroupAndSplitState() async throws {
        let fixture = try makeProgrammaticCloseFixture()
        defer { fixture.window.orderOut(nil) }
        var callbackCount = 0
        fixture.adapter.onEdit = { edit in
            callbackCount += 1
            fixture.adapter.setEditorGroupOrientation(nil)
            return .rejected(currentRevision: edit.expectedRevision)
        }

        let outcome = fixture.adapter.replaceActive(
            range: .init(location: 0, length: 2),
            with: Data(),
            expectedRevision: 0
        )
        for _ in 0..<10 where fixture.adapter.hasVisibleGroups {
            await Task.yield()
        }

        #expect(outcome == .rejected(currentRevision: 0))
        #expect(callbackCount == 1)
        try expectRejectedProgrammaticCloseRestored(fixture)
    }

    @Test @MainActor
    func reentrantCloseAfterRejectedProgrammaticBatchRestoresGroupAndSplitState() async throws {
        let fixture = try makeProgrammaticCloseFixture()
        defer { fixture.window.orderOut(nil) }
        var callbackCount = 0

        let outcome = fixture.adapter.replaceActiveBatch(
            [.init(range: .init(location: 0, length: 2), replacementUTF8: Data())],
            expectedRevision: 0,
            accept: { edits in
                callbackCount += 1
                fixture.adapter.setEditorGroupOrientation(nil)
                return .rejected(currentRevision: edits.first?.expectedRevision ?? .max)
            }
        )
        for _ in 0..<10 where fixture.adapter.hasVisibleGroups {
            await Task.yield()
        }

        #expect(outcome == .rejected(currentRevision: 0))
        #expect(callbackCount == 1)
        try expectRejectedProgrammaticCloseRestored(fixture)
    }

    @Test @MainActor
    func newerGroupLayoutRequestCancelsADeferredClose() async throws {
        for requestedOrientation in [
            EditorGroupSplitOrientation.sideBySide,
            .stacked,
        ] {
            let fixture = try makeClonedGroup(source: "base")
            fixture.secondary.setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
            fixture.adapter.onEdit = { edit in
                fixture.adapter.setEditorGroupOrientation(nil)
                return .rejected(currentRevision: edit.expectedRevision)
            }

            fixture.secondary.insertCommittedText("X")
            fixture.adapter.setEditorGroupOrientation(requestedOrientation)
            for _ in 0..<10 { await Task.yield() }
            let recovery = try #require(
                fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)
            )

            #expect(fixture.adapter.hasVisibleGroups)
            #expect(fixture.adapter.editorGroupOrientation == requestedOrientation)
            #expect(fixture.primary.contentUTF8 == Data("base".utf8))
            #expect(fixture.secondary.contentUTF8 == Data("base".utf8))
            #expect(fixture.primary.revision == 0)
            #expect(fixture.secondary.revision == 0)
            #expect(recovery.revision == 0)
            #expect(recovery.utf8 == Data("base".utf8))
        }
    }

    @Test @MainActor
    func groupFocusCallbackActivatesTheFocusedGroupBeforeCapabilitiesRun() throws {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: first.bufferID, revision: 0, text: "one"))
        adapter.install(.init(bufferID: second.bufferID, revision: 0, text: "two"))
        adapter.display(first)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.stacked)
        adapter.assign(second, from: nil, to: .secondary, cloning: false)
        adapter.display(second, in: .secondary)
        let secondary = try #require(adapter.secondaryGroupView.subviews.first as? DPScintillaEditorView)
        let host = NSStackView(views: [adapter.view, adapter.secondaryGroupView])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var focusedGroups: [EditorGroupID] = []
        adapter.onEditorGroupFocus = { focusedGroups.append($0) }

        secondary.focusEditor()
        adapter.setWordWrapEnabled(false)
        primary.focusEditor()
        adapter.setWhitespaceVisible(true)

        #expect(focusedGroups == [.secondary, .primary])
        #expect(adapter.activeEditorGroup == .primary)
        #expect(!secondary.isWordWrapEnabled)
        #expect(primary.isWordWrapEnabled)
        #expect(primary.isWhitespaceVisible)
        #expect(!secondary.isWhitespaceVisible)
    }

    @Test @MainActor
    func groupModeSuspendsAndRestoresTheCurrentInternalSplitWithoutLosingOwnerState() throws {
        _ = NSApplication.shared
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 3)
        let suspendedSecondary = SecondaryEditorViewState(
            anchorUTF8: 2,
            caretUTF8: 4,
            firstVisibleLine: 10,
            horizontalScrollOffset: 6,
            wordWrapEnabled: false,
            wrapMarkerVisible: true,
            whitespaceVisible: true,
            lineEndingsVisible: true,
            zoomLevel: -2,
            foldState: .init(contractedHeaderLines: [0])
        )
        let adapter = ScintillaEditorAdapter()
        adapter.view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(
            contentRect: adapter.view.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = adapter.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        adapter.installRecovery(.init(
            bufferID: buffer.bufferID,
            revision: buffer.revision,
            utf8: Data((["int main() {"] + (1..<99).map {
                "// \($0):" + String(repeating: "0123456789", count: 20)
            } + ["}"]).joined(separator: "\n").utf8),
            viewState: .init(
                splitOrientation: .stacked,
                secondaryViewState: suspendedSecondary
            )
        ))
        adapter.display(buffer)
        let owner = try #require(adapter.activeScintillaView)
        let installedSplitState = try #require(
            adapter.recoveryCapture(for: buffer.bufferID)?.viewState.secondaryViewState
        )
        #expect(adapter.splitOrientation == .stacked)

        adapter.setEditorGroupOrientation(.sideBySide)
        #expect(adapter.splitOrientation == nil)
        #expect(adapter.suspendedInternalSplitOrientation == .stacked)
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "cpp"), lexerName: "cpp", keywords: ["int"],
            indentation: .init(width: 4), folding: true, braceMatching: true
        )))
        owner.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        #expect(adapter.collapseCurrentFold())
        owner.restoreCaretUTF8Position(
            8,
            anchorPosition: 5,
            firstVisibleLine: 20,
            horizontalScrollOffset: 9,
            wordWrapEnabled: false
        )
        owner.isWrapMarkerVisible = true
        owner.isWhitespaceVisible = true
        owner.areLineEndingsVisible = true
        owner.zoomLevel = 4
        owner.restoreBookmarkedLines([20])
        let ownerFirstVisibleLine = Int(owner.firstVisibleLine)
        let ownerHorizontalScrollOffset = Int(owner.horizontalScrollOffset)

        adapter.split(orientation: .sideBySide)
        adapter.closeSplit()
        let capture = try #require(adapter.recoveryCapture(for: buffer.bufferID))
        let terminationSnapshot = try #require(adapter.recoverySnapshot(for: buffer.bufferID))

        #expect(adapter.splitOrientation == nil)
        #expect(capture.viewState.anchorUTF8 == 5)
        #expect(capture.viewState.caretUTF8 == 8)
        #expect(capture.viewState.firstVisibleLine == ownerFirstVisibleLine)
        #expect(capture.viewState.horizontalScrollOffset == ownerHorizontalScrollOffset)
        #expect(!capture.viewState.wordWrapEnabled)
        #expect(capture.viewState.wrapMarkerVisible)
        #expect(capture.viewState.whitespaceVisible)
        #expect(capture.viewState.lineEndingsVisible)
        #expect(capture.viewState.zoomLevel == 4)
        #expect(capture.viewState.bookmarkedLines == [20])
        #expect(capture.viewState.foldState.contractedHeaderLines == [0])
        #expect(capture.viewState.splitOrientation == .stacked)
        #expect(capture.viewState.secondaryViewState == installedSplitState)
        #expect(terminationSnapshot.viewState.anchorUTF8 == 5)
        #expect(terminationSnapshot.viewState.caretUTF8 == 8)
        #expect(terminationSnapshot.viewState.splitOrientation == .stacked)
        #expect(terminationSnapshot.viewState.secondaryViewState == installedSplitState)

        adapter.setEditorGroupOrientation(nil)

        #expect(!adapter.hasVisibleGroups)
        #expect(adapter.splitOrientation == .stacked)
        #expect(adapter.activeScintillaView?.caretUTF8Position == 8)
        #expect(adapter.secondaryScintillaView?.caretUTF8Position == 4)
        let restoredState = try #require(adapter.recoverySnapshot(for: buffer.bufferID)?.viewState)
        #expect(restoredState.splitOrientation == .stacked)
        #expect(restoredState.secondaryViewState?.anchorUTF8 == installedSplitState.anchorUTF8)
        #expect(restoredState.secondaryViewState?.caretUTF8 == installedSplitState.caretUTF8)
        #expect(restoredState.secondaryViewState?.wordWrapEnabled == installedSplitState.wordWrapEnabled)
        #expect(restoredState.secondaryViewState?.zoomLevel == installedSplitState.zoomLevel)
        #expect(restoredState.secondaryViewState?.foldState == installedSplitState.foldState)
        let roundTrip = try #require(adapter.recoverySnapshot(for: buffer.bufferID))
        let reopened = ScintillaEditorAdapter()
        reopened.installRecovery(roundTrip)
        reopened.display(.init(bufferID: buffer.bufferID, revision: roundTrip.revision))
        #expect(reopened.splitOrientation == .stacked)
        #expect(reopened.activeScintillaView?.caretUTF8Position == 8)
        #expect(reopened.secondaryScintillaView?.caretUTF8Position == 4)
    }

    @Test @MainActor
    func recoveredSplitsInstalledBeforeOrDuringGroupModeStaySuspendedUntilGroupClose() throws {
        let suspendedState = EditorViewState(
            anchorUTF8: 1,
            caretUTF8: 3,
            splitOrientation: .sideBySide,
            secondaryViewState: .init(anchorUTF8: 2, caretUTF8: 5, zoomLevel: 3)
        )

        for installDuringGroupMode in [false, true] {
            let adapter = ScintillaEditorAdapter()
            let initial = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
            let recovered = EditorBufferDescriptor(bufferID: BufferID(), revision: 7)
            adapter.install(.init(bufferID: initial.bufferID, revision: 0, text: "initial"))
            adapter.display(initial)
            if !installDuringGroupMode {
                adapter.installRecovery(.init(
                    bufferID: recovered.bufferID,
                    revision: recovered.revision,
                    utf8: Data("abcdef".utf8),
                    viewState: suspendedState
                ))
            }
            adapter.setEditorGroupOrientation(.stacked)
            if installDuringGroupMode {
                adapter.installRecovery(.init(
                    bufferID: recovered.bufferID,
                    revision: recovered.revision,
                    utf8: Data("abcdef".utf8),
                    viewState: suspendedState
                ))
            }
            adapter.assign(recovered, from: nil, to: .secondary, cloning: false)
            adapter.display(recovered, in: .secondary)
            adapter.activateEditorGroup(.secondary)

            #expect(adapter.splitOrientation == nil)
            #expect(adapter.secondaryScintillaView == nil)
            #expect(adapter.suspendedInternalSplitOrientation == .sideBySide)
            #expect(adapter.recoveryCapture(for: recovered.bufferID)?.viewState == suspendedState)

            adapter.setEditorGroupOrientation(nil)

            #expect(adapter.splitOrientation == .sideBySide)
            #expect(adapter.activeScintillaView?.caretUTF8Position == 3)
            #expect(adapter.secondaryScintillaView?.caretUTF8Position == 5)
        }
    }

    @Test @MainActor
    func cloneRecoveryUsesTheCanonicalOwnerAndNormalMoveTransfersOwnership() throws {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        adapter.view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        adapter.secondaryGroupView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let host = NSStackView(views: [adapter.view, adapter.secondaryGroupView])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(
            bufferID: buffer.bufferID,
            revision: 0,
            text: (0..<100).map {
                "\($0):" + String(repeating: "0123456789", count: 20)
            }.joined(separator: "\n")
        ))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        primary.restoreCaretUTF8Position(
            2, anchorPosition: 1, firstVisibleLine: 10,
            horizontalScrollOffset: 3, wordWrapEnabled: true
        )
        primary.zoomLevel = 2
        secondary.restoreCaretUTF8Position(
            6, anchorPosition: 4, firstVisibleLine: 20,
            horizontalScrollOffset: 8, wordWrapEnabled: false
        )
        secondary.zoomLevel = 7
        let primaryHorizontalScrollOffset = Int(primary.horizontalScrollOffset)
        let secondaryHorizontalScrollOffset = Int(secondary.horizontalScrollOffset)

        let clonedCapture = try #require(adapter.recoveryCapture(for: buffer.bufferID))
        #expect(clonedCapture.viewState.anchorUTF8 == 1)
        #expect(clonedCapture.viewState.caretUTF8 == 2)
        #expect(clonedCapture.viewState.horizontalScrollOffset == primaryHorizontalScrollOffset)
        #expect(clonedCapture.viewState.zoomLevel == 2)
        #expect(clonedCapture.viewState.secondaryViewState == nil)

        adapter.assign(buffer, from: .primary, to: .secondary, cloning: false)
        let movedCapture = try #require(adapter.recoveryCapture(for: buffer.bufferID))

        #expect(movedCapture.viewState.anchorUTF8 == 4)
        #expect(movedCapture.viewState.caretUTF8 == 6)
        #expect(movedCapture.viewState.horizontalScrollOffset == secondaryHorizontalScrollOffset)
        #expect(!movedCapture.viewState.wordWrapEnabled)
        #expect(movedCapture.viewState.zoomLevel == 7)
        #expect(movedCapture.viewState.secondaryViewState == nil)
    }

    @Test @MainActor
    func commandSearchLanguageInstallInputAndRetirementRouteToTheSelectedGroup() throws {
        let adapter = ScintillaEditorAdapter()
        let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: first.bufferID, revision: 0, text: "alpha"))
        adapter.install(.init(bufferID: second.bufferID, revision: 0, text: "beta beta"))
        adapter.display(first)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(second, from: nil, to: .secondary, cloning: false)
        adapter.display(second, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        secondary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 4))

        adapter.perform(.uppercase)
        let match = try adapter.findActive(.init(
            patternUTF8: Data("beta".utf8),
            options: .init(matchCase: true),
            restrictTo: nil
        ))
        #expect(match == .init(location: 5, length: 4))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "python"), lexerName: "python",
            indentation: .init(width: 2), folding: true, braceMatching: true
        )))

        #expect(secondary.contentUTF8 == Data("BETA beta".utf8))
        #expect(primary.contentUTF8 == Data("alpha".utf8))
        #expect(secondary.lexerName == "python")
        #expect(primary.lexerName == "null")
        adapter.setInputEnabled(false)
        #expect(!primary.isInputEnabled)
        #expect(!secondary.isInputEnabled)
        adapter.setInputEnabled(true)

        adapter.install(.init(bufferID: second.bufferID, revision: 10, text: "installed"))
        #expect(secondary.contentUTF8 == Data("installed".utf8))
        #expect(adapter.snapshot(for: second.bufferID)?.revision == 10)
        adapter.retire(bufferID: second.bufferID)
        #expect(adapter.snapshot(for: second.bufferID) == nil)
        #expect(secondary.superview == nil)
        #expect(secondary.onWillModifyDocument == nil)
        #expect(secondary.onFocus == nil)
    }

    @Test @MainActor
    func groupInvalidationDisconnectsBothRootsViewsAndCallbacksExactlyOnce() throws {
        let adapter = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "shared"))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.onEditorGroupFocus = { _ in }

        adapter.invalidate()
        adapter.invalidate()

        #expect(adapter.activeScintillaView == nil)
        #expect(adapter.secondaryScintillaView == nil)
        #expect(adapter.secondaryGroupView.subviews.isEmpty)
        #expect(!adapter.hasVisibleGroups)
        #expect(adapter.onEdit == nil)
        #expect(adapter.onEditorGroupFocus == nil)
        for view in [primary, secondary] {
            #expect(view.superview == nil)
            #expect(view.onWillModifyDocument == nil)
            #expect(view.onEdit == nil)
            #expect(view.onError == nil)
            #expect(view.onFocus == nil)
            #expect(view.onFoldStateChange == nil)
            #expect(view.onFoldRecoveryProgress == nil)
        }
    }

    @MainActor
    private func makeClonedGroup(
        source: String
    ) throws -> (
        adapter: ScintillaEditorAdapter,
        buffer: EditorBufferDescriptor,
        primary: DPScintillaEditorView,
        secondary: DPScintillaEditorView
    ) {
        let adapter = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: source))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.setEditorGroupOrientation(.sideBySide)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        return (adapter, buffer, primary, secondary)
    }

    @MainActor
    private func makeClonedGroupWithSuspendedSplit(
        source: String
    ) throws -> (
        adapter: ScintillaEditorAdapter,
        buffer: EditorBufferDescriptor,
        primary: DPScintillaEditorView,
        secondary: DPScintillaEditorView,
        suspendedSecondaryState: SecondaryEditorViewState
    ) {
        let adapter = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let suspendedSecondaryState = SecondaryEditorViewState(
            anchorUTF8: 1,
            caretUTF8: 3,
            firstVisibleLine: 0,
            horizontalScrollOffset: 0,
            wordWrapEnabled: false,
            wrapMarkerVisible: true,
            whitespaceVisible: true,
            lineEndingsVisible: true,
            zoomLevel: -1,
            foldState: .init(contractedHeaderLines: [])
        )
        adapter.installRecovery(.init(
            bufferID: buffer.bufferID,
            revision: 0,
            utf8: Data(source.utf8),
            viewState: .init(
                splitOrientation: .stacked,
                secondaryViewState: suspendedSecondaryState
            )
        ))
        adapter.display(buffer)
        adapter.setEditorGroupOrientation(.sideBySide)
        let primary = try #require(adapter.activeScintillaView)
        adapter.assign(buffer, from: .primary, to: .secondary, cloning: true)
        adapter.display(buffer, in: .secondary)
        adapter.activateEditorGroup(.secondary)
        let secondary = try #require(adapter.activeScintillaView)
        return (adapter, buffer, primary, secondary, suspendedSecondaryState)
    }

    @MainActor
    private func makeProgrammaticCloseFixture() throws -> (
        adapter: ScintillaEditorAdapter,
        buffer: EditorBufferDescriptor,
        primary: DPScintillaEditorView,
        suspendedSecondaryState: SecondaryEditorViewState,
        source: String,
        firstVisibleLine: UInt,
        horizontalScrollOffset: UInt,
        window: NSWindow
    ) {
        _ = NSApplication.shared
        let source = (["{"] + (0..<80).map {
            "\"key\($0)\": \($0)," + String(repeating: " ", count: 120)
        } + ["\"last\": 0", "}"]).joined(separator: "\n")
        let group = try makeClonedGroupWithSuspendedSplit(source: source)
        group.adapter.view.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        group.adapter.secondaryGroupView.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        let host = NSStackView(views: [group.adapter.view, group.adapter.secondaryGroupView])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        #expect(group.adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"), lexerName: "json",
            indentation: .init(width: 4), folding: true, braceMatching: true
        )))
        #expect(group.primary.restoreContractedFoldHeaderLines([0]).isEmpty)
        group.primary.restoreBookmarkedLines([40])
        group.primary.restoreCaretUTF8Position(
            50, anchorPosition: 100, firstVisibleLine: 12,
            horizontalScrollOffset: 7, wordWrapEnabled: false
        )
        #expect(!group.primary.canUndo)
        return (
            group.adapter,
            group.buffer,
            group.primary,
            group.suspendedSecondaryState,
            source,
            group.primary.firstVisibleLine,
            group.primary.horizontalScrollOffset,
            window
        )
    }

    @MainActor
    private func expectRejectedProgrammaticCloseRestored(
        _ fixture: (
            adapter: ScintillaEditorAdapter,
            buffer: EditorBufferDescriptor,
            primary: DPScintillaEditorView,
            suspendedSecondaryState: SecondaryEditorViewState,
            source: String,
            firstVisibleLine: UInt,
            horizontalScrollOffset: UInt,
            window: NSWindow
        )
    ) throws {
        let recovery = try #require(
            fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)
        )
        let saved = try #require(fixture.adapter.snapshot(for: fixture.buffer.bufferID))

        #expect(!fixture.adapter.hasVisibleGroups)
        #expect(fixture.adapter.splitOrientation == .stacked)
        #expect(fixture.primary.contentUTF8 == Data(fixture.source.utf8))
        #expect(fixture.primary.revision == 0)
        #expect(fixture.primary.anchorUTF8Position == 100)
        #expect(fixture.primary.caretUTF8Position == 50)
        #expect(fixture.primary.firstVisibleLine == fixture.firstVisibleLine)
        #expect(fixture.primary.horizontalScrollOffset == fixture.horizontalScrollOffset)
        #expect(fixture.primary.bookmarkedLines.map(\.intValue) == [40])
        #expect(fixture.primary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [0])
        #expect(!fixture.primary.canUndo)
        #expect(recovery.revision == 0)
        #expect(recovery.utf8 == Data(fixture.source.utf8))
        #expect(recovery.viewState.anchorUTF8 == 100)
        #expect(recovery.viewState.caretUTF8 == 50)
        #expect(recovery.viewState.firstVisibleLine == Int(fixture.firstVisibleLine))
        #expect(recovery.viewState.horizontalScrollOffset == Int(fixture.horizontalScrollOffset))
        #expect(recovery.viewState.bookmarkedLines == [40])
        #expect(recovery.viewState.foldState.contractedHeaderLines == [0])
        #expect(recovery.viewState.splitOrientation == .stacked)
        #expect(recovery.viewState.secondaryViewState == fixture.suspendedSecondaryState)
        #expect(saved.revision == 0)
        #expect(saved.text == fixture.source)
    }
}
