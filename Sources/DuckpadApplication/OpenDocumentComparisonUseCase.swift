import DuckpadDomain

@MainActor
public final class OpenDocumentComparisonUseCase {
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let limits: OpenDocumentComparison.Limits
    private let isCancelled: @Sendable () -> Bool

    public init(
        workspace: ScratchWorkspaceUseCase,
        editor: any EditorPort,
        limits: OpenDocumentComparison.Limits = .default,
        isCancelled: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) {
        self.workspace = workspace
        self.editor = editor
        self.limits = limits
        self.isCancelled = isCancelled
    }

    public func eligibleTabs(excluding sourceTabID: TabID) -> [TabSnapshot] {
        workspace.snapshot().tabs.filter { $0.id != sourceTabID }
    }

    public func capture(
        leftTabID: TabID,
        rightTabID: TabID
    ) throws(OpenDocumentComparison.Error) -> OpenDocumentComparison {
        guard leftTabID != rightTabID else { throw .sameTab(leftTabID) }
        let tabs = workspace.snapshot().tabs
        guard let leftTab = tabs.first(where: { $0.id == leftTabID }) else {
            throw .missingTab(leftTabID)
        }
        guard let rightTab = tabs.first(where: { $0.id == rightTabID }) else {
            throw .missingTab(rightTabID)
        }

        let left = try capture(leftTab, side: .left)
        let right = try capture(rightTab, side: .right)
        try checkCancellation()
        return OpenDocumentComparison(left: left, right: right)
    }

    private func capture(
        _ tab: TabSnapshot,
        side: OpenDocumentComparison.Side
    ) throws(OpenDocumentComparison.Error) -> OpenDocumentComparison.Document {
        try checkCancellation()
        let descriptor = tab.buffer
        guard let snapshot = editor.snapshot(for: descriptor.bufferID) else {
            throw .missingSnapshot(descriptor.bufferID)
        }
        guard snapshot.bufferID == descriptor.bufferID else {
            throw .missingSnapshot(descriptor.bufferID)
        }
        guard snapshot.revision == descriptor.revision else {
            throw .staleSnapshot(
                bufferID: descriptor.bufferID,
                expectedRevision: descriptor.revision,
                actualRevision: snapshot.revision
            )
        }

        let measurement = try measure(snapshot.text)
        let byteCount = measurement.byteCount
        guard byteCount <= limits.maximumUTF8BytesPerSide else {
            throw .inputTooLarge(
                side: side,
                byteCount: byteCount,
                maximum: limits.maximumUTF8BytesPerSide
            )
        }
        let lineCount = measurement.lineCount
        guard lineCount <= limits.maximumLinesPerSide else {
            throw .tooManyLines(
                side: side,
                lineCount: lineCount,
                maximum: limits.maximumLinesPerSide
            )
        }

        return OpenDocumentComparison.Document(
            tabID: tab.id,
            title: tab.title,
            fullPath: tab.fullPath,
            bufferID: descriptor.bufferID,
            revision: descriptor.revision,
            text: snapshot.text
        )
    }

    private func measure(
        _ text: String
    ) throws(OpenDocumentComparison.Error) -> (byteCount: Int, lineCount: Int) {
        var byteCount = 0
        var lineCount = 1
        var previousWasCarriageReturn = false
        for byte in text.utf8 {
            if byteCount.isMultiple(of: 4_096) { try checkCancellation() }
            byteCount += 1
            if byte == 0x0D {
                lineCount += 1
                previousWasCarriageReturn = true
            } else if byte == 0x0A {
                if !previousWasCarriageReturn { lineCount += 1 }
                previousWasCarriageReturn = false
            } else {
                previousWasCarriageReturn = false
            }
        }
        return (byteCount, lineCount)
    }

    private func checkCancellation() throws(OpenDocumentComparison.Error) {
        if isCancelled() { throw .cancelled }
    }
}
