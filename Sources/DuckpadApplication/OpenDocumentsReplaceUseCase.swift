import DuckpadDomain
import Foundation

@MainActor
public protocol OpenDocumentsReplacementEditorPort: SearchEditorPort {
    func canReplaceBuffer(_ buffer: EditorBufferDescriptor) -> Bool
    func replaceBufferBatch(
        _ edits: [SearchReplacementEdit], buffer: EditorBufferDescriptor,
        accept: ([EditorIncrementalEdit]) -> EditorEditOutcome
    ) -> EditorEditOutcome
}

/// Plans all replacements before editing, then applies one undo group per document.
/// Documents that change or become unavailable are reported rather than overwritten.
@MainActor
public final class OpenDocumentsReplaceUseCase {
    private struct Capture: Sendable {
        let tabID: TabID
        let title: String
        let generatedTitle: GeneratedDocumentTitle?
        let buffer: EditorBufferDescriptor
        let contents: EditorRecoveryCapture?
        let skip: OpenDocumentReplacement.Status?
    }
    private struct Plan: Sendable {
        let capture: Capture
        let edits: [SearchReplacementEdit]
        let skip: OpenDocumentReplacement.Status?
    }
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any SearchEditorPort
    private let regexEngine: any RegexEnginePort
    private let limits: SearchLimits

    public init(workspace: ScratchWorkspaceUseCase, editor: any SearchEditorPort,
                regexEngine: any RegexEnginePort, limits: SearchLimits = SearchLimits()) {
        self.workspace = workspace
        self.editor = editor
        self.regexEngine = regexEngine
        self.limits = limits
    }

    public func replaceAll(
        _ query: SearchQuery,
        only tabIDs: Set<TabID>? = nil,
        expectedRevisions: [BufferID: UInt64]? = nil,
        expectedDocuments: [SearchDocumentResult] = [],
        expectedRanges: [BufferID: Set<SearchUTF8Range>]? = nil,
        onProgress: ((OpenDocumentsReplacementResult) -> Void)? = nil
    ) async throws -> OpenDocumentsReplacementResult {
        guard limits.maximumMatches > 0, limits.maximumMatches <= 100_000,
              limits.maximumDocumentBytes > 0, limits.maximumRegularExpressionBytes > 0,
              limits.maximumPatternBytes > 0, limits.maximumPatternBytes <= 64 * 1_024,
              limits.maximumResultBytes > 0, limits.maximumReplacementBytes > 0,
              limits.maximumFinalDocumentBytes > 0 else { throw SearchFailure.invalidLimits }
        let pattern = try SearchPatternCodec.patternData(for: query)
        guard pattern.count <= limits.maximumPatternBytes,
              query.replacement.utf8.count <= limits.maximumReplacementBytes else {
            throw SearchFailure.patternTooLarge(actual: max(pattern.count, query.replacement.utf8.count),
                                              limit: min(limits.maximumPatternBytes, limits.maximumReplacementBytes))
        }
        await workspace.waitForPendingPersistence()
        guard !Task.isCancelled else { throw SearchFailure.cancelled }
        let fileMask = try query.fileMask.map { try SearchFileMask($0) }
        let replacementEditor = editor as? any OpenDocumentsReplacementEditorPort
        let captures = workspace.snapshot().tabs.filter { (tabIDs?.contains($0.id) ?? true) && (fileMask?.matches($0.fullPath ?? $0.title) ?? true) }.map { tab in
            let skip: OpenDocumentReplacement.Status?
            if let expectedRevisions, expectedRevisions[tab.buffer.bufferID] != tab.buffer.revision { skip = .changed }
            else { skip = tab.isReadOnly ? .readOnly
                : (replacementEditor?.canReplaceBuffer(tab.buffer) == true ? nil : .unavailable) }
            return Capture(tabID: tab.id, title: tab.title, generatedTitle: tab.generatedTitle, buffer: tab.buffer,
                           contents: skip == nil ? editor.recoveryCapture(for: tab.buffer.bufferID) : nil, skip: skip)
        }
        let engine = regexEngine, limits = limits
        let task = Task.detached(priority: .userInitiated) {
            // Validate the expression even when every open document is read-only.
            let empty = SearchBufferSnapshot(tabID: TabID(), title: "", bufferID: BufferID(), revision: 0, utf8: Data())
            _ = try SearchEngine.scan(in: empty, query: query, limit: 1, regexEngine: engine)
            var plans: [Plan] = []
            var remainingMatches = limits.maximumMatches
            var remainingResults = limits.maximumResultBytes
            var remainingReplacement = limits.maximumReplacementBytes
            for capture in captures {
                guard !Task.isCancelled else { throw SearchFailure.cancelled }
                if let skip = capture.skip {
                    plans.append(Plan(capture: capture, edits: [], skip: skip)); continue
                }
                do {
                    guard let contents = capture.contents else {
                        plans.append(Plan(capture: capture, edits: [], skip: .unavailable)); continue
                    }
                    let byteLimit = query.options.mode == .regularExpression
                        ? min(limits.maximumDocumentBytes, limits.maximumRegularExpressionBytes) : limits.maximumDocumentBytes
                    if let skip = Self.preflight(contents, byteLimit: byteLimit) {
                        plans.append(Plan(capture: capture, edits: [], skip: skip)); continue
                    }
                    let materialized = try contents.materializedSnapshot()
                    guard materialized.bufferID == capture.buffer.bufferID,
                          materialized.revision == capture.buffer.revision else {
                        plans.append(Plan(capture: capture, edits: [], skip: .unavailable)); continue
                    }
                    guard materialized.utf8.count <= limits.maximumDocumentBytes,
                          query.options.mode != .regularExpression || materialized.utf8.count <= limits.maximumRegularExpressionBytes,
                          remainingMatches > 0, remainingResults > 0 else {
                        plans.append(Plan(capture: capture, edits: [], skip: .limitExceeded)); continue
                    }
                    let snapshot = SearchBufferSnapshot(tabID: capture.tabID, title: capture.title,
                        bufferID: materialized.bufferID, revision: materialized.revision, utf8: materialized.utf8)
                    let scan = try SearchEngine.scan(in: snapshot, query: query, limit: remainingMatches + 1,
                        regexEngine: engine, maximumResultBytes: remainingResults, includeReplacement: true,
                        maximumReplacementBytes: limits.maximumReplacementBytes)
                    guard scan.isComplete, scan.matches.count <= remainingMatches else {
                        plans.append(Plan(capture: capture, edits: [], skip: .limitExceeded)); continue
                    }
                    var edits: [SearchReplacementEdit] = []
                    var finalBytes = snapshot.utf8.count
                    var replacementBytes = 0
                    var exceedsLimit = false
                    for match in scan.matches.reversed() {
                        if let expectedRanges, expectedRanges[capture.buffer.bufferID]?.contains(match.range) != true { continue }
                        let bytes = try SearchEngine.replacement(for: match, in: snapshot, query: query)
                        // Equal-byte replacements are no-ops: do not create dirty tabs or Undo entries.
                        if snapshot.utf8.subdata(in: match.range.location..<match.range.upperBound) == bytes { continue }
                        let (aggregate, overflow) = replacementBytes.addingReportingOverflow(bytes.count)
                        let (nextSize, sizeOverflow) = (finalBytes - match.range.length).addingReportingOverflow(bytes.count)
                        if overflow || sizeOverflow || aggregate > remainingReplacement || nextSize > limits.maximumFinalDocumentBytes {
                            exceedsLimit = true; break
                        }
                        finalBytes = nextSize; replacementBytes = aggregate
                        edits.append(SearchReplacementEdit(range: match.range, replacementUTF8: bytes))
                    }
                    if exceedsLimit || UInt64(edits.count) > UInt64.max - capture.buffer.revision {
                        plans.append(Plan(capture: capture, edits: [], skip: .limitExceeded)); continue
                    }
                    remainingMatches -= scan.matches.count
                    remainingResults -= scan.resultBytes
                    remainingReplacement -= replacementBytes
                    plans.append(Plan(capture: capture, edits: edits, skip: nil))
                } catch let failure as SearchFailure {
                    switch failure {
                    case .documentTooLarge, .tooComplex:
                        plans.append(Plan(capture: capture, edits: [], skip: .limitExceeded))
                    case .timedOut:
                        plans.append(Plan(capture: capture, edits: [], skip: .timedOut))
                    case .invalidUTF8Range:
                        plans.append(Plan(capture: capture, edits: [], skip: .unavailable))
                    default: throw failure
                    }
                } catch {
                    plans.append(Plan(capture: capture, edits: [], skip: .unavailable))
                }
            }
            return plans
        }
        let plans = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { throw SearchFailure.cancelled }
        let present = Set(captures.map(\.tabID))
        var documents = expectedDocuments.filter { !present.contains($0.tabID) }.map {
            OpenDocumentReplacement(tabID: $0.tabID, title: $0.title, status: .unavailable, generatedTitle: $0.generatedTitle)
        }
        for plan in plans {
            let target = plan.capture
            let status: OpenDocumentReplacement.Status
            if Task.isCancelled { status = .cancelled }
            else if workspace.fileContext(tabID: target.tabID)?.buffer != target.buffer { status = .changed }
            else if let skip = plan.skip { status = skip }
            else if plan.edits.isEmpty { status = .noChanges }
            else if let replacementEditor,
                    let reservation = await workspace.reserveEditorBatch(bufferID: target.buffer.bufferID,
                        expectedRevision: target.buffer.revision, editCount: plan.edits.count, requiresActive: false) {
                if Task.isCancelled {
                    workspace.cancelEditorBatch(reservation)
                    status = .cancelled
                } else {
                    let outcome = replacementEditor.replaceBufferBatch(plan.edits, buffer: target.buffer) { [workspace] edits in
                        workspace.commitEditorBatch(reservation, edits: edits)
                    }
                    switch outcome {
                    case .accepted: status = .replaced(plan.edits.count)
                    case .rejected:
                        workspace.cancelEditorBatch(reservation)
                        status = .unavailable
                    }
                }
            } else {
                status = Task.isCancelled ? .cancelled : .changed
            }
            documents.append(OpenDocumentReplacement(tabID: target.tabID, title: target.title, status: status, generatedTitle: target.generatedTitle))
            onProgress?(OpenDocumentsReplacementResult(documents: documents, wasCancelled: Task.isCancelled))
        }
        return OpenDocumentsReplacementResult(documents: documents, wasCancelled: Task.isCancelled)
    }

    /// Bound every intermediate size before replaying deltas or validating a large checkpoint.
    private nonisolated static func preflight(
        _ capture: EditorRecoveryCapture, byteLimit: Int
    ) -> OpenDocumentReplacement.Status? {
        var count = capture.baseUTF8.count
        guard count <= byteLimit else { return .limitExceeded }
        var revision = capture.baseRevision
        for delta in capture.deltas {
            guard revision < UInt64.max, delta.expectedRevision == revision,
                  delta.range.location >= 0, delta.range.length >= 0,
                  delta.range.location <= count, delta.range.length <= count - delta.range.location else { return .unavailable }
            let (next, overflow) = (count - delta.range.length).addingReportingOverflow(delta.replacementUTF8.count)
            guard !overflow, next <= byteLimit else { return .limitExceeded }
            count = next
            revision += 1
        }
        return revision == capture.revision ? nil : .unavailable
    }

}
