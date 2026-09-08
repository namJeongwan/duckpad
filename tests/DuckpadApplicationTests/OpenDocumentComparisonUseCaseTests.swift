import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@MainActor
private final class ComparisonEditorFake: EditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private(set) var displayedBuffers: [EditorBufferDescriptor] = []
    private(set) var snapshotRequests: [BufferID] = []

    func display(_ buffer: EditorBufferDescriptor) { displayedBuffers.append(buffer) }
    func install(_ snapshot: EditorTextSnapshot) { snapshots[snapshot.bufferID] = snapshot }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        snapshotRequests.append(bufferID)
        return snapshots[bufferID]
    }
    func retire(bufferID: BufferID) { snapshots.removeValue(forKey: bufferID) }
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {}

    func seed(_ text: String, for descriptor: EditorBufferDescriptor, revision: UInt64? = nil) {
        snapshots[descriptor.bufferID] = EditorTextSnapshot(
            bufferID: descriptor.bufferID,
            revision: revision ?? descriptor.revision,
            text: text
        )
    }
}

private final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingChecks: Int

    init(after checks: Int) { remainingChecks = checks }

    func callAsFunction() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingChecks > 0 else { return true }
        remainingChecks -= 1
        return false
    }
}

@MainActor
private struct ComparisonFixture {
    let workspace: ScratchWorkspaceUseCase
    let editor: ComparisonEditorFake
    let useCase: OpenDocumentComparisonUseCase
    let first: TabSnapshot
    let second: TabSnapshot

    static func make(
        limits: OpenDocumentComparison.Limits = .default,
        isCancelled: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) async throws -> Self {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        _ = await workspace.addScratch()
        let tabs = workspace.snapshot().tabs
        let editor = ComparisonEditorFake()
        editor.seed("left", for: tabs[0].buffer)
        editor.seed("right", for: tabs[1].buffer)
        return Self(
            workspace: workspace,
            editor: editor,
            useCase: OpenDocumentComparisonUseCase(
                workspace: workspace,
                editor: editor,
                limits: limits,
                isCancelled: isCancelled
            ),
            first: tabs[0],
            second: tabs[1]
        )
    }
}

@Test @MainActor func captureReadsTwoExactOpenBuffersWithoutActivation() async throws {
    let fixture = try await ComparisonFixture.make()
    let activeBefore = fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id

    let comparison = try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)

    #expect(comparison.left.tabID == fixture.first.id)
    #expect(comparison.left.title == fixture.first.title)
    #expect(comparison.left.text == "left")
    #expect(comparison.right.tabID == fixture.second.id)
    #expect(comparison.right.text == "right")
    #expect(fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == activeBefore)
    #expect(fixture.editor.displayedBuffers.isEmpty)

    fixture.editor.seed("changed later", for: fixture.first.buffer)
    #expect(comparison.left.text == "left")
}

@Test @MainActor func eligibleTabsExcludeTheSourceAndRetainWorkspaceOrder() async throws {
    let fixture = try await ComparisonFixture.make()

    #expect(fixture.useCase.eligibleTabs(excluding: fixture.first.id).map(\.id) == [fixture.second.id])
}

@Test @MainActor func captureRejectsSameAndMissingTabs() async throws {
    let fixture = try await ComparisonFixture.make()

    #expect(throws: OpenDocumentComparison.Error.sameTab(fixture.first.id)) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.first.id)
    }
    let missing = TabID()
    #expect(throws: OpenDocumentComparison.Error.missingTab(missing)) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: missing)
    }
}

@Test @MainActor func captureRejectsMissingAndStaleEditorSnapshots() async throws {
    let missingFixture = try await ComparisonFixture.make()
    missingFixture.editor.retire(bufferID: missingFixture.second.buffer.bufferID)
    #expect(throws: OpenDocumentComparison.Error.missingSnapshot(missingFixture.second.buffer.bufferID)) {
        try missingFixture.useCase.capture(leftTabID: missingFixture.first.id, rightTabID: missingFixture.second.id)
    }

    let staleFixture = try await ComparisonFixture.make()
    staleFixture.editor.seed("newer", for: staleFixture.second.buffer, revision: staleFixture.second.buffer.revision + 1)
    #expect(throws: OpenDocumentComparison.Error.staleSnapshot(
        bufferID: staleFixture.second.buffer.bufferID,
        expectedRevision: staleFixture.second.buffer.revision,
        actualRevision: staleFixture.second.buffer.revision + 1
    )) {
        try staleFixture.useCase.capture(leftTabID: staleFixture.first.id, rightTabID: staleFixture.second.id)
    }
}

@Test @MainActor func captureEnforcesUTF8ByteLimitIndependentlyPerSide() async throws {
    let limits = OpenDocumentComparison.Limits(maximumUTF8BytesPerSide: 4)
    let fixture = try await ComparisonFixture.make(limits: limits)
    fixture.editor.seed("1234", for: fixture.first.buffer)
    fixture.editor.seed("🙂a", for: fixture.second.buffer)

    #expect(throws: OpenDocumentComparison.Error.inputTooLarge(side: .right, byteCount: 5, maximum: 4)) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }

    fixture.editor.seed("🙂a", for: fixture.first.buffer)
    fixture.editor.seed("1234", for: fixture.second.buffer)
    #expect(throws: OpenDocumentComparison.Error.inputTooLarge(side: .left, byteCount: 5, maximum: 4)) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }
}

@Test @MainActor func captureCountsEmptyAndTrailingLogicalLinesAtTheLineCeiling() async throws {
    let limits = OpenDocumentComparison.Limits(maximumLinesPerSide: 3)
    let fixture = try await ComparisonFixture.make(limits: limits)
    fixture.editor.seed("a\nb\n", for: fixture.first.buffer)
    fixture.editor.seed("a\nb\nc\n", for: fixture.second.buffer)

    #expect(throws: OpenDocumentComparison.Error.tooManyLines(side: .right, lineCount: 4, maximum: 3)) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }
}

@Test @MainActor func captureAcceptsExactByteAndLogicalLineBoundaries() async throws {
    let limits = OpenDocumentComparison.Limits(
        maximumUTF8BytesPerSide: 4,
        maximumLinesPerSide: 3
    )
    let fixture = try await ComparisonFixture.make(limits: limits)
    fixture.editor.seed("a\nb\n", for: fixture.first.buffer)
    fixture.editor.seed("🙂", for: fixture.second.buffer)

    let comparison = try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)

    #expect(comparison.left.text == "a\nb\n")
    #expect(comparison.right.text == "🙂")
}

@Test @MainActor func captureCountsCRLFStandaloneCRAndLFAsLogicalLineBreaks() async throws {
    let limits = OpenDocumentComparison.Limits(maximumLinesPerSide: 4)
    let fixture = try await ComparisonFixture.make(limits: limits)
    fixture.editor.seed("a\r\nb\rc\nd", for: fixture.first.buffer)

    let comparison = try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    #expect(comparison.left.text == "a\r\nb\rc\nd")

    fixture.editor.seed("a\r\nb\rc\nd\r", for: fixture.first.buffer)
    #expect(throws: OpenDocumentComparison.Error.tooManyLines(side: .left, lineCount: 5, maximum: 4)) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }
}

@Test @MainActor func captureAcceptsFiftyThousandLogicalLinesAndRejectsFiftyThousandOne() async throws {
    let fixture = try await ComparisonFixture.make()
    let boundary = Array(repeating: "x", count: 50_000).joined(separator: "\r")
    fixture.editor.seed(boundary, for: fixture.first.buffer)
    _ = try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)

    let overBoundary = boundary + "\r"
    fixture.editor.seed(overBoundary, for: fixture.first.buffer)
    #expect(throws: OpenDocumentComparison.Error.tooManyLines(side: .left, lineCount: 50_001, maximum: 50_000)) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }
}

@Test @MainActor func captureReturnsTypedCancellationWithoutReadingTheEditor() async throws {
    let fixture = try await ComparisonFixture.make()
    let task = Task { @MainActor in
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }
    task.cancel()

    await #expect(throws: OpenDocumentComparison.Error.cancelled) {
        _ = try await task.value
    }
    #expect(fixture.editor.snapshotRequests.isEmpty)
}

@Test @MainActor func delayedCancellationInterruptsLargeRightSideValidation() async throws {
    let cancellation = CaptureCancellation(after: 4)
    let fixture = try await ComparisonFixture.make(isCancelled: cancellation.callAsFunction)
    fixture.editor.seed(String(repeating: "r", count: 5_000), for: fixture.second.buffer)
    let activeBefore = fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id

    #expect(throws: OpenDocumentComparison.Error.cancelled) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }
    #expect(fixture.editor.snapshotRequests == [fixture.first.buffer.bufferID, fixture.second.buffer.bufferID])
    #expect(fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == activeBefore)
    #expect(fixture.editor.displayedBuffers.isEmpty)
}

@Test @MainActor func captureChecksCancellationAfterBothSidesAreValidated() async throws {
    let cancellation = CaptureCancellation(after: 4)
    let fixture = try await ComparisonFixture.make(isCancelled: cancellation.callAsFunction)

    #expect(throws: OpenDocumentComparison.Error.cancelled) {
        try fixture.useCase.capture(leftTabID: fixture.first.id, rightTabID: fixture.second.id)
    }
    #expect(fixture.editor.snapshotRequests == [fixture.first.buffer.bufferID, fixture.second.buffer.bufferID])
}
