import DuckpadDomain
import Foundation

public struct FileWorkspaceContext: Equatable, Sendable {
    public let tabID: TabID
    public let title: String
    public let buffer: EditorBufferDescriptor
    public let binding: FileBinding?

    public init(tabID: TabID, title: String, buffer: EditorBufferDescriptor, binding: FileBinding?) {
        self.tabID = tabID
        self.title = title
        self.buffer = buffer
        self.binding = binding
    }
}

public enum FileOperationFailure: Error, Equatable, Sendable {
    case cancelled
    case noActiveDocument
    case unsavedChanges(TabID)
    case editorSnapshotUnavailable(BufferID)
    case editorRevisionMismatch(bufferID: BufferID, expected: UInt64, actual: UInt64)
    case codec(TextFileCodecError)
    case store(TextFileStoreError)
    case workspace(PersistenceFailure)
    case session(SessionError)
    case comparisonTooLarge(actual: Int, limit: Int)
    case comparisonInvalidated
}

public enum FileOpenOutcome: Equatable, Sendable {
    case opened(TabID)
    case activatedExisting(TabID)
    case failed(FileOperationFailure)
}

public enum FileSaveOutcome: Equatable, Sendable {
    case saved(TabID)
    case requiresDestination(TabID)
    case conflict(tabID: TabID, current: FileIdentity?)
    case cancelled(TabID)
    case failed(FileOperationFailure)
}

public enum FileConflictResolution: Equatable, Sendable {
    case overwrite
    case reload
    case compare
    case cancel
}

public struct ExternalFileComparison: Equatable, Sendable {
    public let tabID: TabID
    public let path: String
    public let localText: String
    public let externalText: String
    public let localRevision: UInt64
    public let externalIdentity: FileIdentity

    public init(
        tabID: TabID,
        path: String,
        localText: String,
        externalText: String,
        localRevision: UInt64,
        externalIdentity: FileIdentity
    ) {
        self.tabID = tabID
        self.path = path
        self.localText = localText
        self.externalText = externalText
        self.localRevision = localRevision
        self.externalIdentity = externalIdentity
    }
}

public enum FileComparisonOutcome: Equatable, Sendable {
    case ready(ExternalFileComparison)
    case failed(FileOperationFailure)
}

public enum FolderSearchActivationOutcome: Equatable, Sendable {
    case activated(TabID)
    case stale(String)
    case failed(FileOperationFailure)
}

/// Coordinates file I/O while the editor remains the sole live-text authority.
/// MainActor isolation serializes open/save decisions and keeps UI publication ordered.
@MainActor
public final class FileDocumentUseCase {
    public static let defaultMaximumComparisonBytes = 32 * 1_024 * 1_024
    private struct PendingConflict {
        let context: FileWorkspaceContext
        let url: URL
        let conversion: TextFileConversion?
        let currentIdentity: FileIdentity?
        let securityScopedBookmark: Data?
    }

    private let changeMonitor: (any FileChangeMonitoring)?
    private var liveReloadEnabled = false
    private var liveReloadSuspended = false
    private var liveReloadTask: Task<Void, Never>?
    private var pendingLivePaths = Set<String>()
    public private(set) var externalChanges: [TabID: LiveFileChange] = [:]
    public var onExternalChanges: (() -> Void)?
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let store: any TextFileStore
    private let securityScopeOwnerID = UUID()
    private let maximumComparisonBytes: Int
    private var pendingConflict: PendingConflict?
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        workspace: ScratchWorkspaceUseCase,
        editor: any EditorPort,
        store: any TextFileStore,
        maximumComparisonBytes: Int = FileDocumentUseCase.defaultMaximumComparisonBytes,
        changeMonitor: (any FileChangeMonitoring)? = nil
    ) {
        precondition(maximumComparisonBytes > 0)
        self.workspace = workspace
        self.editor = editor
        self.store = store
        self.maximumComparisonBytes = maximumComparisonBytes
        self.changeMonitor = changeMonitor
        changeMonitor?.onChange = { [weak self] paths in self?.queueLiveReload(paths) }
    }

    public func suspendLiveReload() {
        liveReloadSuspended = true
        changeMonitor?.stop()
        liveReloadTask?.cancel()
        pendingLivePaths.removeAll()
    }

    public func resumeLiveReload() {
        liveReloadSuspended = false
        updateLiveReloadDocuments()
    }

    public func waitForLiveReload() async {
        await liveReloadTask?.value
        // Includes an already accepted explicit Reload action.
        await acquireOperation()
        releaseOperation()
    }

    public func setLiveReloadEnabled(_ enabled: Bool) {
        liveReloadEnabled = enabled
        if !enabled {
            changeMonitor?.stop()
            liveReloadTask?.cancel()
            pendingLivePaths.removeAll()
        } else { updateLiveReloadDocuments() }
    }

    public func updateLiveReloadDocuments() {
        let tabs = workspace.snapshot().tabs
        let ids = Set(tabs.map(\.id))
        externalChanges = externalChanges.filter { ids.contains($0.key) }
        guard liveReloadEnabled, !liveReloadSuspended, workspace.snapshot().startup == .ready else { return }
        changeMonitor?.watch(paths: Set(tabs.compactMap { workspace.fileContext(tabID: $0.id)?.binding?.canonicalPath }))
    }

    public func dismissExternalChange(for tabID: TabID) {
        externalChanges.removeValue(forKey: tabID)
        onExternalChanges?()
    }

    private func queueLiveReload(_ paths: Set<String>) {
        guard liveReloadEnabled, !liveReloadSuspended else { return }
        pendingLivePaths.formUnion(paths)
        guard liveReloadTask == nil else { return }
        liveReloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.liveReloadTask = nil
                if self.liveReloadEnabled && !self.liveReloadSuspended && !self.pendingLivePaths.isEmpty { self.queueLiveReload([]) }
            }
            while !self.pendingLivePaths.isEmpty && self.liveReloadEnabled && !self.liveReloadSuspended && !Task.isCancelled {
                let paths = self.pendingLivePaths
                self.pendingLivePaths.removeAll()
                let ids = self.workspace.snapshot().tabs.compactMap { tab -> TabID? in
                    guard let path = self.workspace.fileContext(tabID: tab.id)?.binding?.canonicalPath,
                          paths.contains(path) else { return nil }
                    return tab.id
                }
                for id in ids where !Task.isCancelled { await self.refreshFromDisk(tabID: id) }
            }
        }
    }

    /// Clean documents reload automatically. Explicit discard applies only to
    /// the exact revision reviewed by the user; concurrent edits always win.
    public func refreshFromDisk(tabID: TabID, discardingRevision: UInt64? = nil) async {
        await acquireOperation()
        defer { releaseOperation() }
        guard !Task.isCancelled, !liveReloadSuspended, let context = workspace.fileContext(tabID: tabID), let binding = context.binding else { return }
        do {
            let url = URL(fileURLWithPath: binding.canonicalPath)
            let read = try await store.read(from: url)
            guard !Task.isCancelled, !liveReloadSuspended, let current = workspace.fileContext(tabID: tabID), current.binding == binding else { return }
            if read.identity == binding.observedIdentity {
                externalChanges.removeValue(forKey: tabID)
                onExternalChanges?()
                return
            }
            let dirty = workspace.snapshot().tabs.first(where: { $0.id == tabID })?.isDirty == true
            guard !dirty || discardingRevision == current.buffer.revision else {
                externalChanges[tabID] = .conflict
                onExternalChanges?()
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                TextFileCodec.decodeForDisplay(read.data, assuming: binding.encoding)
            }.value
            guard !Task.isCancelled, !liveReloadSuspended else { return }
            let retained = try await store.prepareSecurityScopedAccess(to: url, ownerID: securityScopeOwnerID)
            let updated = FileBinding(canonicalPath: read.identity.canonicalPath, encoding: decoded.encoding,
                byteOrderMark: decoded.byteOrderMark, lineEnding: decoded.lineEnding,
                observedIdentity: read.identity, securityScopedBookmark: retained.bookmark ?? binding.securityScopedBookmark)
            guard !Task.isCancelled, !liveReloadSuspended else { return }
            let state = editor.recoveryCapture(for: current.buffer.bufferID)?.viewState ?? EditorViewState()
            let bytes = Data(decoded.text.utf8)
            let result = await workspace.replaceFileContents(tabID: tabID, binding: updated, title: current.title,
                expectedRevision: current.buffer.revision, expectedBinding: binding,
                installContents: { [editor] descriptor in
                    editor.installRecovery(EditorRecoverySnapshot(bufferID: descriptor.bufferID,
                        revision: descriptor.revision, utf8: bytes, viewState: state))
                })
            switch result {
            case .applied: externalChanges.removeValue(forKey: tabID)
            case .rejected(.unknownTab): externalChanges.removeValue(forKey: tabID)
            case .rejected: externalChanges[tabID] = .conflict
            case .persistenceFailed: externalChanges[tabID] = .unavailable
            }
        } catch {
            if workspace.fileContext(tabID: tabID)?.binding == binding { externalChanges[tabID] = .unavailable }
        }
        onExternalChanges?()
    }

    /// Reacquires every recovered document bookmark before the window becomes
    /// interactive. Invalid bookmarks leave the recovery buffer intact and are
    /// reported by path so the user can still Save As to reauthorize it.
    @discardableResult
    public func restoreSecurityScopedAccessForOpenDocuments() async -> [String] {
        var failures: [String] = []
        for tab in workspace.snapshot().tabs {
            guard let context = workspace.fileContext(tabID: tab.id),
                  let binding = context.binding else { continue }
            do {
                let updated = try await store.restoreSecurityScopedAccess(
                    for: binding,
                    ownerID: securityScopeOwnerID
                )
                guard updated != binding else { continue }
                switch await workspace.updateFileBindingIfCurrent(
                    tabID: tab.id,
                    binding: updated,
                    expectedBinding: binding
                ) {
                case .applied:
                    break
                case .persistenceFailed(let failure):
                    failures.append("\(binding.canonicalPath): \(failure)")
                    await store.releaseSecurityScopedAccess(
                        forCanonicalPath: updated.canonicalPath,
                        ownerID: securityScopeOwnerID
                    )
                case .rejected(let error):
                    failures.append("\(binding.canonicalPath): \(error)")
                    await store.releaseSecurityScopedAccess(
                        forCanonicalPath: updated.canonicalPath,
                        ownerID: securityScopeOwnerID
                    )
                }
            } catch {
                failures.append("\(binding.canonicalPath): \(error)")
            }
        }
        return failures
    }

    public func releaseSecurityScopedAccess(for binding: FileBinding) async {
        await store.releaseSecurityScopedAccess(
            forCanonicalPath: binding.canonicalPath,
            ownerID: securityScopeOwnerID
        )
    }

    public func releaseAllSecurityScopedAccess() async {
        await store.releaseAllSecurityScopedAccess(ownerID: securityScopeOwnerID)
    }

    public func releaseSecurityScopedAccessForClosedDocuments() async {
        let retained = Set(workspace.snapshot().tabs.compactMap {
            workspace.fileContext(tabID: $0.id)?.binding?.canonicalPath
        })
        await store.reconcileSecurityScopedAccess(
            retainingCanonicalPaths: retained,
            ownerID: securityScopeOwnerID
        )
    }

    public func clearPersistedSecurityScopedBookmarks() async -> TextFileStoreError? {
        do {
            try await store.clearPersistedSecurityScopedBookmarks()
            return nil
        } catch { return error }
    }

    public func open(
        _ url: URL,
        assuming encodingHint: TextFileEncoding? = nil
    ) async -> FileOpenOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        return await openWithoutAcquiring(url, assuming: encodingHint)
    }

    /// Opens one external request as an indivisible ordered batch. Other file
    /// operations wait until every member has resolved, preventing two Finder
    /// requests from interleaving their tab order.
    public func open(
        _ urls: [URL],
        assuming encodingHint: TextFileEncoding? = nil
    ) async -> [FileOpenOutcome] {
        await acquireOperation()
        defer { releaseOperation() }
        var outcomes: [FileOpenOutcome] = []
        outcomes.reserveCapacity(urls.count)
        for url in urls {
            outcomes.append(await openWithoutAcquiring(url, assuming: encodingHint))
        }
        return outcomes
    }

    private func openWithoutAcquiring(
        _ url: URL,
        assuming encodingHint: TextFileEncoding?
    ) async -> FileOpenOutcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        var preparedPath: String?
        do {
            let access = try await store.prepareSecurityScopedAccess(
                to: url,
                ownerID: securityScopeOwnerID
            )
            preparedPath = access.url.standardizedFileURL.path
            let canonical = try await store.canonicalURL(for: access.url)
            preparedPath = canonical.path
            guard !Task.isCancelled else {
                await store.releaseSecurityScopedAccess(
                    forCanonicalPath: canonical.path,
                    ownerID: securityScopeOwnerID
                )
                return .failed(.cancelled)
            }
            let outcome = try await openCanonical(
                canonical,
                prepared: nil,
                encodingHint: encodingHint,
                securityScopedBookmark: access.bookmark
            )
            if case .failed = outcome, workspace.tabID(canonicalPath: canonical.path) == nil {
                await store.releaseSecurityScopedAccess(
                    forCanonicalPath: canonical.path,
                    ownerID: securityScopeOwnerID
                )
            }
            return outcome
        } catch let error {
            if let preparedPath, workspace.tabID(canonicalPath: preparedPath) == nil {
                await store.releaseSecurityScopedAccess(
                    forCanonicalPath: preparedPath,
                    ownerID: securityScopeOwnerID
                )
            }
            return .failed(.store(error))
        }
    }

    public func open(
        _ workspaceRead: WorkspaceFileRead,
        assuming encodingHint: TextFileEncoding? = nil
    ) async -> FileOpenOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        var preparedPath: String?
        do {
            let access = try await store.prepareSecurityScopedAccess(
                to: workspaceRead.url,
                ownerID: securityScopeOwnerID
            )
            preparedPath = access.url.standardizedFileURL.path
            let canonical = try await store.canonicalURL(for: access.url)
            preparedPath = canonical.path
            guard canonical.isFileURL,
                  workspaceRead.result.identity.canonicalPath == canonical.path else {
                await store.releaseSecurityScopedAccess(
                    forCanonicalPath: canonical.path,
                    ownerID: securityScopeOwnerID
                )
                return .failed(.store(.invalidPath(workspaceRead.url.path)))
            }
            let outcome = try await openCanonical(
                canonical,
                prepared: workspaceRead.result,
                encodingHint: encodingHint,
                securityScopedBookmark: access.bookmark
            )
            if case .failed = outcome, workspace.tabID(canonicalPath: canonical.path) == nil {
                await store.releaseSecurityScopedAccess(
                    forCanonicalPath: canonical.path,
                    ownerID: securityScopeOwnerID
                )
            }
            return outcome
        } catch let error {
            if let preparedPath, workspace.tabID(canonicalPath: preparedPath) == nil {
                await store.releaseSecurityScopedAccess(
                    forCanonicalPath: preparedPath,
                    ownerID: securityScopeOwnerID
                )
            }
            return .failed(.store(error))
        }
    }

    private func openCanonical(
        _ canonical: URL,
        prepared: FileReadResult?,
        encodingHint: TextFileEncoding?,
        securityScopedBookmark: Data?
    ) async throws(TextFileStoreError) -> FileOpenOutcome {
        let existing = workspace.tabID(canonicalPath: canonical.path)
        if let existing, encodingHint == nil {
            switch await workspace.activate(tabID: existing) {
            case .applied: return .activatedExisting(existing)
            case .persistenceFailed(let failure): return .failed(.workspace(failure))
            case .rejected(let error): return .failed(.session(error))
            }
        }
        let reopening = existing.flatMap { workspace.fileContext(tabID: $0) }
        if let existing, workspace.snapshot().tabs.first(where: { $0.id == existing })?.isDirty != false {
            return .failed(.unsavedChanges(existing))
        }
        let read: FileReadResult
        if let prepared { read = prepared }
        else { read = try await store.read(from: canonical) }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let decoded: DecodedTextFile
        if let encodingHint {
            do {
                decoded = try TextFileCodec.decode(read.data, assuming: encodingHint)
            } catch { return .failed(.codec(error)) }
        } else {
            decoded = TextFileCodec.decodeForDisplay(read.data)
        }
        let binding = FileBinding(
            canonicalPath: read.identity.canonicalPath,
            encoding: decoded.encoding,
            byteOrderMark: decoded.byteOrderMark,
            lineEnding: decoded.lineEnding,
            observedIdentity: read.identity,
            securityScopedBookmark: securityScopedBookmark ?? reopening?.binding?.securityScopedBookmark
        )
        guard !Task.isCancelled else { return .failed(.cancelled) }
        if let reopening {
            switch await workspace.replaceFileContents(
                tabID: reopening.tabID,
                binding: binding,
                title: canonical.lastPathComponent,
                expectedRevision: reopening.buffer.revision,
                expectedBinding: reopening.binding
            ) {
            case .applied:
                guard let refreshed = workspace.fileContext(tabID: reopening.tabID) else {
                    return .failed(.comparisonInvalidated)
                }
                editor.install(EditorTextSnapshot(
                    bufferID: refreshed.buffer.bufferID,
                    revision: refreshed.buffer.revision,
                    text: decoded.text
                ))
                switch await workspace.activate(tabID: reopening.tabID) {
                case .applied: return .activatedExisting(reopening.tabID)
                case .persistenceFailed(let failure): return .failed(.workspace(failure))
                case .rejected(let error): return .failed(.session(error))
                }
            case .persistenceFailed(let failure): return .failed(.workspace(failure))
            case .rejected(.revisionConflict(let bufferID, let expected, let actual)):
                return .failed(.editorRevisionMismatch(bufferID: bufferID, expected: expected, actual: actual))
            case .rejected(.unknownTab), .rejected(.fileBindingConflict):
                return .failed(.comparisonInvalidated)
            case .rejected(let error): return .failed(.session(error))
            }
        }
        switch await workspace.addOpenedFile(binding: binding, title: canonical.lastPathComponent) {
        case .applied:
            guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
            editor.install(EditorTextSnapshot(
                bufferID: context.buffer.bufferID,
                revision: context.buffer.revision,
                text: decoded.text
            ))
            return .opened(context.tabID)
        case .persistenceFailed(let failure): return .failed(.workspace(failure))
        case .rejected(let error): return .failed(.session(error))
        }
    }

    public func activateFolderSearchMatch(
        document: FolderSearchDocumentResult,
        match: FolderSearchMatch
    ) async -> FolderSearchActivationOutcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let outcome = await open(URL(fileURLWithPath: document.path))
        let tabID: TabID
        switch outcome {
        case .opened(let opened), .activatedExisting(let opened): tabID = opened
        case .failed(let failure): return .failed(failure)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard let selectionEditor = editor as? any EditorSelectionPort,
              let context = workspace.fileContext(tabID: tabID),
              workspace.snapshot().tabs.first(where: { $0.id == tabID })?.isDirty == false,
              context.binding?.canonicalPath == document.path,
              context.binding?.observedIdentity == document.identity,
              let snapshot = selectionEditor.snapshot(for: context.buffer.bufferID),
              snapshot.revision == context.buffer.revision,
              match.range.location >= 0,
              match.range.length >= 0,
              match.range.location <= snapshot.text.utf8.count,
              match.range.length <= snapshot.text.utf8.count - match.range.location else {
            return .stale(document.path)
        }
        selectionEditor.selectAndReveal(match.range)
        selectionEditor.focus()
        return .activated(tabID)
    }

    public func saveActive(
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext? = nil
    ) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
        guard expectedContext == nil || expectedContext == context else {
            return .failed(.comparisonInvalidated)
        }
        guard let binding = context.binding else { return .requiresDestination(context.tabID) }
        // Merely viewing a permissively decoded file must not rewrite its
        // original bytes when Save is pressed without an edit or conversion.
        if conversion == nil,
           workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == false {
            return .saved(context.tabID)
        }
        return await save(context: context, to: URL(fileURLWithPath: binding.canonicalPath), conversion: conversion, overwrite: false)
    }

    public func saveAs(
        _ url: URL,
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext? = nil,
        renewingAccess: Bool = false
    ) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let context = workspace.activeFileContext() else { return .failed(.noActiveDocument) }
        guard expectedContext == nil || expectedContext == context else {
            return .failed(.comparisonInvalidated)
        }
        return await save(context: context, to: url, conversion: conversion, overwrite: false, renewingAccess: renewingAccess)
    }

    /// Writes a point-in-time copy without rebinding the tab or marking it clean.
    /// The caller is expected to obtain overwrite consent (for example through
    /// `NSSavePanel`) before setting `overwrite` to true.
    public func saveCopy(
        _ url: URL,
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext? = nil,
        renewingAccess: Bool = false
    ) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let context = workspace.activeFileContext() else {
            return .failed(.noActiveDocument)
        }
        guard expectedContext == nil || expectedContext == context else {
            return .failed(.comparisonInvalidated)
        }
        let transientOwnerID = UUID()
        let access: SecurityScopedFileAccess
        let canonical: URL
        do {
            if renewingAccess {
                access = try await store.renewSecurityScopedAccess(to: url, ownerID: transientOwnerID)
            } else {
                access = try await store.prepareSecurityScopedAccess(to: url, ownerID: transientOwnerID)
            }
            canonical = try await store.canonicalURL(for: access.url)
        } catch let error {
            return .failed(.store(error))
        }
        let outcome: FileSaveOutcome
        if workspace.tabID(canonicalPath: canonical.path) != nil {
            outcome = .failed(.session(.duplicateFileBinding(canonical.path)))
        } else if let snapshot = editor.snapshot(for: context.buffer.bufferID) {
            if snapshot.revision != context.buffer.revision {
                outcome = .failed(.editorRevisionMismatch(
                    bufferID: context.buffer.bufferID,
                    expected: context.buffer.revision,
                    actual: snapshot.revision
                ))
            } else {
                let format = outputFormat(context: context, conversion: conversion)
                let text = TextFileCodec.convert(snapshot.text, to: format.lineEnding)
                let data = TextFileCodec.encode(
                    text,
                    encoding: format.encoding,
                    byteOrderMark: format.byteOrderMark
                )
                do {
                    let destinationIdentity = try await store.currentIdentity(for: canonical)
                    _ = try await store.writeAtomically(
                        data,
                        to: canonical,
                        expectedIdentity: destinationIdentity,
                        overwrite: false
                    )
                    _ = try await store.prepareSecurityScopedAccess(to: canonical, ownerID: transientOwnerID)
                    outcome = .saved(context.tabID)
                } catch let error {
                    outcome = .failed(.store(error))
                }
            }
        } else {
            outcome = .failed(.editorSnapshotUnavailable(context.buffer.bufferID))
        }
        await store.releaseSecurityScopedAccess(
            forCanonicalPath: canonical.path,
            ownerID: transientOwnerID
        )
        return outcome
    }

    public func resolveConflict(_ resolution: FileConflictResolution) async -> FileSaveOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let pendingConflict else {
            return .failed(.noActiveDocument)
        }
        let context = pendingConflict.context
        switch resolution {
        case .cancel:
            self.pendingConflict = nil
            return .cancelled(context.tabID)
        case .overwrite:
            return await save(
                context: context,
                to: pendingConflict.url,
                conversion: pendingConflict.conversion,
                overwrite: true
            )
        case .compare:
            return .conflict(tabID: context.tabID, current: pendingConflict.currentIdentity)
        case .reload:
            do {
                let read = try await store.read(from: pendingConflict.url)
                let retainedAccess = try await store.prepareSecurityScopedAccess(
                    to: pendingConflict.url, ownerID: securityScopeOwnerID
                )
                let decoded = TextFileCodec.decodeForDisplay(read.data)
                let updated = FileBinding(
                    canonicalPath: read.identity.canonicalPath,
                    encoding: decoded.encoding,
                    byteOrderMark: decoded.byteOrderMark,
                    lineEnding: decoded.lineEnding,
                    observedIdentity: read.identity,
                    securityScopedBookmark: retainedAccess.bookmark ?? pendingConflict.securityScopedBookmark
                        ?? (context.binding?.canonicalPath == pendingConflict.url.path ? context.binding?.securityScopedBookmark : nil)
                )
                switch await workspace.replaceFileContents(
                    tabID: context.tabID,
                    binding: updated,
                    title: URL(fileURLWithPath: updated.canonicalPath).lastPathComponent,
                    expectedRevision: context.buffer.revision,
                    expectedBinding: context.binding
                ) {
                case .applied:
                    guard let refreshed = workspace.fileContext(tabID: context.tabID) else { return .failed(.noActiveDocument) }
                    editor.install(EditorTextSnapshot(bufferID: refreshed.buffer.bufferID, revision: refreshed.buffer.revision, text: decoded.text))
                    self.pendingConflict = nil
                    return .saved(context.tabID)
                case .persistenceFailed(let failure): return .failed(.workspace(failure))
                case .rejected(.revisionConflict(let bufferID, let expected, let actual)):
                    return .failed(.editorRevisionMismatch(
                        bufferID: bufferID,
                        expected: expected,
                        actual: actual
                    ))
                case .rejected(.unknownTab), .rejected(.fileBindingConflict):
                    return .failed(.comparisonInvalidated)
                case .rejected(let error): return .failed(.session(error))
                }
            } catch let error {
                return .failed(.store(error))
            }
        }
    }

    public func pendingExternalComparison() async -> FileComparisonOutcome {
        await acquireOperation()
        defer { releaseOperation() }
        guard let pendingConflict,
              let context = workspace.fileContext(tabID: pendingConflict.context.tabID) else {
            return .failed(.noActiveDocument)
        }
        guard let snapshot = editor.snapshot(for: context.buffer.bufferID) else {
            return .failed(.editorSnapshotUnavailable(context.buffer.bufferID))
        }
        guard snapshot.revision == context.buffer.revision else {
            return .failed(.editorRevisionMismatch(
                bufferID: context.buffer.bufferID,
                expected: context.buffer.revision,
                actual: snapshot.revision
            ))
        }
        guard snapshot.text.utf8.count <= maximumComparisonBytes else {
            return .failed(.comparisonTooLarge(
                actual: snapshot.text.utf8.count,
                limit: maximumComparisonBytes
            ))
        }
        do {
            let read = try await store.read(from: pendingConflict.url)
            guard let refreshed = workspace.fileContext(tabID: context.tabID),
                  refreshed == context,
                  let refreshedSnapshot = editor.snapshot(for: refreshed.buffer.bufferID),
                  refreshedSnapshot.revision == snapshot.revision else {
                return .failed(.comparisonInvalidated)
            }
            guard read.data.count <= maximumComparisonBytes else {
                return .failed(.comparisonTooLarge(
                    actual: read.data.count,
                    limit: maximumComparisonBytes
                ))
            }
            let decoded = TextFileCodec.decodeForDisplay(
                read.data,
                assuming: context.binding?.encoding
            )
            return .ready(ExternalFileComparison(
                tabID: context.tabID,
                path: read.identity.canonicalPath,
                localText: snapshot.text,
                externalText: decoded.text,
                localRevision: snapshot.revision,
                externalIdentity: read.identity
            ))
        } catch let error {
            return .failed(.store(error))
        }
    }

    private func save(
        context: FileWorkspaceContext,
        to url: URL,
        conversion: TextFileConversion?,
        overwrite: Bool,
        renewingAccess: Bool = false
    ) async -> FileSaveOutcome {
        let access: SecurityScopedFileAccess
        let canonical: URL
        do {
            if renewingAccess {
                access = try await store.renewSecurityScopedAccess(to: url, ownerID: securityScopeOwnerID)
            } else {
                access = try await store.prepareSecurityScopedAccess(to: url, ownerID: securityScopeOwnerID)
            }
            canonical = try await store.canonicalURL(for: access.url)
        } catch let error {
            return .failed(.store(error))
        }
        let oldPath = context.binding?.canonicalPath
        let outcome = await savePrepared(
            context: context,
            to: canonical,
            conversion: conversion,
            overwrite: overwrite,
            securityScopedBookmark: access.bookmark
        )
        if case .saved = outcome {
            if let oldPath, oldPath != canonical.path {
                await store.releaseSecurityScopedAccess(
                    forCanonicalPath: oldPath,
                    ownerID: securityScopeOwnerID
                )
            }
        } else if oldPath != canonical.path {
            await store.releaseSecurityScopedAccess(
                forCanonicalPath: canonical.path,
                ownerID: securityScopeOwnerID
            )
        }
        return outcome
    }

    private func savePrepared(
        context: FileWorkspaceContext,
        to url: URL,
        conversion: TextFileConversion?,
        overwrite: Bool,
        securityScopedBookmark: Data?
    ) async -> FileSaveOutcome {
        guard workspace.fileContext(tabID: context.tabID) == context else {
            pendingConflict = nil
            return .failed(.comparisonInvalidated)
        }
        if let duplicate = workspace.tabID(canonicalPath: url.path), duplicate != context.tabID {
            return .failed(.session(.duplicateFileBinding(url.path)))
        }
        guard let snapshot = editor.snapshot(for: context.buffer.bufferID) else {
            return .failed(.editorSnapshotUnavailable(context.buffer.bufferID))
        }
        guard snapshot.revision == context.buffer.revision else {
            return .failed(.editorRevisionMismatch(
                bufferID: context.buffer.bufferID,
                expected: context.buffer.revision,
                actual: snapshot.revision
            ))
        }
        let format = outputFormat(context: context, conversion: conversion)
        let encoding = format.encoding
        let bom = format.byteOrderMark
        let lineEnding = format.lineEnding
        // Bound EOL is a durable format choice, not a one-shot transformation.
        // Normal saves therefore normalize to the binding selected by a prior conversion.
        let text = TextFileCodec.convert(snapshot.text, to: lineEnding)
        let data = TextFileCodec.encode(text, encoding: encoding, byteOrderMark: bom)
        let expected = !overwrite && context.binding?.canonicalPath == url.path ? context.binding?.observedIdentity : nil
        do {
            let receipt = try await store.writeAtomically(data, to: url, expectedIdentity: expected, overwrite: overwrite)
            let retainedAccess = try await store.prepareSecurityScopedAccess(to: url, ownerID: securityScopeOwnerID)
            let identity = receipt.identity
            let binding = FileBinding(
                canonicalPath: identity.canonicalPath,
                encoding: encoding,
                byteOrderMark: bom,
                lineEnding: lineEnding == .none ? inferLineEnding(text) : lineEnding,
                observedIdentity: identity,
                securityScopedBookmark: retainedAccess.bookmark ?? securityScopedBookmark
                    ?? (context.binding?.canonicalPath == url.path ? context.binding?.securityScopedBookmark : nil)
            )
            switch await workspace.bindSavedFileIfCurrent(
                tabID: context.tabID,
                binding: binding,
                title: url.lastPathComponent,
                savedRevision: snapshot.revision,
                expectedBufferID: context.buffer.bufferID,
                expectedBinding: context.binding
            ) {
            case .applied:
                pendingConflict = nil
                return .saved(context.tabID)
            case .persistenceFailed(let failure): return .failed(.workspace(failure))
            case .rejected(.fileBindingConflict), .rejected(.unknownTab):
                pendingConflict = nil
                return .failed(.comparisonInvalidated)
            case .rejected(let error): return .failed(.session(error))
            }
        } catch .conflict(let current) {
            pendingConflict = PendingConflict(
                context: context,
                url: url,
                conversion: conversion,
                currentIdentity: current,
                securityScopedBookmark: securityScopedBookmark
            )
            return .conflict(tabID: context.tabID, current: current)
        } catch let error {
            return .failed(.store(error))
        }
    }

    private func inferLineEnding(_ text: String) -> LineEnding {
        (try? TextFileCodec.decode(Data(text.utf8)).lineEnding) ?? .none
    }

    private func outputFormat(
        context: FileWorkspaceContext,
        conversion: TextFileConversion?
    ) -> TextFileConversion {
        TextFileConversion(
            encoding: conversion?.encoding ?? context.binding?.encoding ?? .utf8,
            byteOrderMark: conversion?.byteOrderMark ?? context.binding?.byteOrderMark ?? .absent,
            lineEnding: conversion?.lineEnding ?? context.binding?.lineEnding ?? .none
        )
    }

    private func acquireOperation() async {
        if !operationBusy {
            operationBusy = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty { operationBusy = false }
        else { operationWaiters.removeFirst().resume() }
    }
}
