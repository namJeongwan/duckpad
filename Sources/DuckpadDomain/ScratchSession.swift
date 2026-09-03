import Foundation

public struct BufferMetadata: Codable, Equatable, Sendable {
    public let id: BufferID
    public private(set) var revision: UInt64
    public private(set) var isDirty: Bool

    public init(id: BufferID = BufferID(), revision: UInt64 = 0, isDirty: Bool = false) {
        self.id = id
        self.revision = revision
        self.isDirty = isDirty
    }

    @discardableResult
    public mutating func recordEdit(expectedRevision: UInt64) throws -> UInt64 {
        guard revision == expectedRevision else {
            throw SessionError.revisionConflict(
                bufferID: id,
                expected: expectedRevision,
                actual: revision
            )
        }
        guard revision < UInt64.max else {
            throw SessionError.revisionExhausted(bufferID: id)
        }
        revision += 1
        isDirty = true
        return revision
    }

    public mutating func markClean() { isDirty = false }

    @discardableResult
    public mutating func replaceContents() throws -> UInt64 {
        guard revision < UInt64.max else { throw SessionError.revisionExhausted(bufferID: id) }
        revision += 1
        isDirty = false
        return revision
    }
}

public struct ScratchDocument: Codable, Equatable, Sendable {
    public let id: DocumentID
    public let bufferID: BufferID
    public var title: String

    public init(
        id: DocumentID = DocumentID(),
        bufferID: BufferID,
        title: String
    ) {
        self.id = id
        self.bufferID = bufferID
        self.title = title
    }
}

public struct WorkspaceTab: Codable, Equatable, Sendable {
    public let id: TabID
    public let documentID: DocumentID
    public var isPinned: Bool

    public init(id: TabID = TabID(), documentID: DocumentID, isPinned: Bool = false) {
        self.id = id
        self.documentID = documentID
        self.isPinned = isPinned
    }
}

/// Complete metadata needed to put a closed tab back into a live session.
/// Editor-owned text and view state remain an Application-layer concern.
public struct ClosedTabState: Equatable, Sendable {
    public let originalIndex: Int
    public let tab: WorkspaceTab
    public let document: ScratchDocument
    public let buffer: BufferMetadata
    public let fileBinding: FileBinding?
    public let languageOverride: LanguageOverride?

    public init(
        originalIndex: Int,
        tab: WorkspaceTab,
        document: ScratchDocument,
        buffer: BufferMetadata,
        fileBinding: FileBinding?,
        languageOverride: LanguageOverride?
    ) {
        self.originalIndex = originalIndex
        self.tab = tab
        self.document = document
        self.buffer = buffer
        self.fileBinding = fileBinding
        self.languageOverride = languageOverride
    }
}

public enum SessionError: Error, Equatable, Sendable {
    case unknownTab(TabID)
    case brokenDocumentReference(DocumentID)
    case brokenBufferReference(BufferID)
    case dirtyBufferRequiresDecision(BufferID)
    case revisionConflict(bufferID: BufferID, expected: UInt64, actual: UInt64)
    case revisionExhausted(bufferID: BufferID)
    case fileBindingConflict(documentID: DocumentID)
    case duplicateBufferID(BufferID)
    case duplicateFileBinding(String)
    case invalidTabDestination(Int)
    case invalidRecoveryState(String)
}

public struct ScratchSession: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, tabs, documents, buffers, fileBindings, languageOverrides, activeTabID, activationHistory, nextUntitledNumber
    }

    public let id: SessionID
    public private(set) var tabs: [WorkspaceTab]
    public private(set) var documents: [DocumentID: ScratchDocument]
    public private(set) var buffers: [BufferID: BufferMetadata]
    public private(set) var fileBindings: [DocumentID: FileBinding]
    public private(set) var languageOverrides: [DocumentID: LanguageOverride]
    public private(set) var activeTabID: TabID?
    public private(set) var activationHistory: [TabID]
    private var nextUntitledNumber: Int

    public init(id: SessionID = SessionID()) {
        self.id = id
        tabs = []
        documents = [:]
        buffers = [:]
        fileBindings = [:]
        languageOverrides = [:]
        activeTabID = nil
        activationHistory = []
        nextUntitledNumber = 1
    }

    public init(
        id: SessionID,
        tabs: [WorkspaceTab],
        documents: [DocumentID: ScratchDocument],
        buffers: [BufferID: BufferMetadata],
        fileBindings: [DocumentID: FileBinding],
        languageOverrides: [DocumentID: LanguageOverride] = [:],
        activeTabID: TabID?,
        activationHistory: [TabID]? = nil,
        nextUntitledNumber: Int
    ) throws {
        guard nextUntitledNumber > 0 else { throw SessionError.invalidRecoveryState("next untitled number") }
        guard Set(tabs.map(\.id)).count == tabs.count else { throw SessionError.invalidRecoveryState("duplicate tab ID") }
        guard Set(tabs.map(\.documentID)).count == tabs.count else {
            throw SessionError.invalidRecoveryState("duplicate document ownership")
        }
        guard !zip(tabs, tabs.dropFirst()).contains(where: { !$0.isPinned && $1.isPinned }) else {
            throw SessionError.invalidRecoveryState("pinned tabs must form a leading group")
        }
        guard documents.allSatisfy({ $0.key == $0.value.id }) else { throw SessionError.invalidRecoveryState("document key mismatch") }
        guard buffers.allSatisfy({ $0.key == $0.value.id }) else { throw SessionError.invalidRecoveryState("buffer key mismatch") }
        guard Set(documents.values.map(\.bufferID)).count == documents.count else { throw SessionError.invalidRecoveryState("duplicate buffer ownership") }
        guard tabs.allSatisfy({ documents[$0.documentID] != nil }) else { throw SessionError.invalidRecoveryState("broken tab document") }
        guard documents.values.allSatisfy({ buffers[$0.bufferID] != nil }) else { throw SessionError.invalidRecoveryState("broken document buffer") }
        guard Set(tabs.map(\.documentID)) == Set(documents.keys),
              Set(documents.values.map(\.bufferID)) == Set(buffers.keys) else {
            throw SessionError.invalidRecoveryState("orphan document or buffer")
        }
        guard fileBindings.keys.allSatisfy({ documents[$0] != nil }) else { throw SessionError.invalidRecoveryState("orphan file binding") }
        guard languageOverrides.keys.allSatisfy({ documents[$0] != nil }) else { throw SessionError.invalidRecoveryState("orphan language override") }
        guard Set(fileBindings.values.map(\.canonicalPath)).count == fileBindings.count else {
            throw SessionError.invalidRecoveryState("duplicate file binding")
        }
        guard activeTabID == nil ? tabs.isEmpty : tabs.contains(where: { $0.id == activeTabID }) else {
            throw SessionError.invalidRecoveryState("invalid active tab")
        }
        let recoveredHistory = activationHistory ?? activeTabID.map { [$0] } ?? []
        guard Set(recoveredHistory).count == recoveredHistory.count,
              recoveredHistory.allSatisfy({ id in tabs.contains(where: { $0.id == id }) }),
              activeTabID == nil ? recoveredHistory.isEmpty : recoveredHistory.last == activeTabID else {
            throw SessionError.invalidRecoveryState("invalid activation history")
        }
        self.id = id
        self.tabs = tabs
        self.documents = documents
        self.buffers = buffers
        self.fileBindings = fileBindings
        self.languageOverrides = languageOverrides
        self.activeTabID = activeTabID
        self.activationHistory = recoveredHistory
        self.nextUntitledNumber = nextUntitledNumber
    }

    /// Phase 4 recovery manifests predate MRU history. Decode those archives
    /// as an active-only history while encoding all new archives explicitly.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(SessionID.self, forKey: .id)
        let tabs = try values.decode([WorkspaceTab].self, forKey: .tabs)
        let documents = try values.decode([DocumentID: ScratchDocument].self, forKey: .documents)
        let buffers = try values.decode([BufferID: BufferMetadata].self, forKey: .buffers)
        let fileBindings = try values.decode([DocumentID: FileBinding].self, forKey: .fileBindings)
        let languageOverrides = try values.decodeIfPresent([DocumentID: LanguageOverride].self, forKey: .languageOverrides) ?? [:]
        let activeTabID = try values.decodeIfPresent(TabID.self, forKey: .activeTabID)
        let activationHistory = try values.decodeIfPresent([TabID].self, forKey: .activationHistory)
        let nextUntitledNumber = try values.decode(Int.self, forKey: .nextUntitledNumber)
        do {
            try self.init(
                id: id,
                tabs: tabs,
                documents: documents,
                buffers: buffers,
                fileBindings: fileBindings,
                languageOverrides: languageOverrides,
                activeTabID: activeTabID,
                activationHistory: activationHistory,
                nextUntitledNumber: nextUntitledNumber
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid Duckpad session: \(error)"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(tabs, forKey: .tabs)
        try values.encode(documents, forKey: .documents)
        try values.encode(buffers, forKey: .buffers)
        try values.encode(fileBindings, forKey: .fileBindings)
        try values.encode(languageOverrides, forKey: .languageOverrides)
        try values.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try values.encode(activationHistory, forKey: .activationHistory)
        try values.encode(nextUntitledNumber, forKey: .nextUntitledNumber)
    }

    public var recoveryNextUntitledNumber: Int { nextUntitledNumber }

    @discardableResult
    public mutating func addUntitled() -> TabID {
        var buffer = BufferMetadata()
        while buffers[buffer.id] != nil {
            buffer = BufferMetadata()
        }
        return addUniqueUntitled(buffer: buffer)
    }

    @discardableResult
    public mutating func addUntitled(buffer: BufferMetadata) throws -> TabID {
        guard buffers[buffer.id] == nil else {
            throw SessionError.duplicateBufferID(buffer.id)
        }
        return addUniqueUntitled(buffer: buffer)
    }

    private mutating func addUniqueUntitled(buffer: BufferMetadata) -> TabID {
        let document = ScratchDocument(
            bufferID: buffer.id,
            title: "new \(nextUntitledNumber)"
        )
        let tab = WorkspaceTab(documentID: document.id)
        nextUntitledNumber += 1
        buffers[buffer.id] = buffer
        documents[document.id] = document
        tabs.append(tab)
        activeTabID = tab.id
        recordActivation(tab.id)
        return tab.id
    }

    @discardableResult
    public mutating func addFile(binding: FileBinding, title: String) throws -> TabID {
        if let existing = tabID(canonicalPath: binding.canonicalPath) {
            try activate(tabID: existing)
            return existing
        }
        var buffer = BufferMetadata()
        while buffers[buffer.id] != nil { buffer = BufferMetadata() }
        let document = ScratchDocument(bufferID: buffer.id, title: title)
        let tab = WorkspaceTab(documentID: document.id)
        buffers[buffer.id] = buffer
        documents[document.id] = document
        fileBindings[document.id] = binding
        tabs.append(tab)
        activeTabID = tab.id
        recordActivation(tab.id)
        return tab.id
    }

    public mutating func activate(tabID: TabID) throws {
        guard tabs.contains(where: { $0.id == tabID }) else {
            throw SessionError.unknownTab(tabID)
        }
        activeTabID = tabID
        recordActivation(tabID)
    }

    /// Reorders a tab without allowing pinned and ordinary groups to cross.
    /// Returns the actual final index after group-boundary clamping.
    @discardableResult
    public mutating func moveTab(tabID: TabID, to proposedIndex: Int) throws -> Int {
        guard let source = tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionError.unknownTab(tabID)
        }
        guard tabs.indices.contains(proposedIndex) else {
            throw SessionError.invalidTabDestination(proposedIndex)
        }
        let tab = tabs[source]
        let pinnedCount = tabs.prefix(while: \.isPinned).count
        let allowed: ClosedRange<Int> = tab.isPinned
            ? 0...max(0, pinnedCount - 1)
            : min(pinnedCount, tabs.count - 1)...(tabs.count - 1)
        let destination = min(max(proposedIndex, allowed.lowerBound), allowed.upperBound)
        guard source != destination else { return source }
        tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        return destination
    }

    /// Pinning is represented in Domain state so recovery restores both the
    /// leading pinned group and stable order within each group.
    @discardableResult
    public mutating func setPinned(tabID: TabID, isPinned: Bool) throws -> Int {
        guard let source = tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionError.unknownTab(tabID)
        }
        guard tabs[source].isPinned != isPinned else { return source }
        var tab = tabs.remove(at: source)
        tab.isPinned = isPinned
        let pinnedCount = tabs.prefix(while: \.isPinned).count
        let destination = pinnedCount
        tabs.insert(tab, at: destination)
        return destination
    }

    @discardableResult
    public mutating func close(tabID: TabID, discardingDirty: Bool = false) throws -> TabID? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionError.unknownTab(tabID)
        }
        let document = try document(for: tabID)
        guard let buffer = buffers[document.bufferID] else {
            throw SessionError.brokenBufferReference(document.bufferID)
        }
        guard !buffer.isDirty || discardingDirty else {
            throw SessionError.dirtyBufferRequiresDecision(buffer.id)
        }
        let removed = tabs.remove(at: index)
        activationHistory.removeAll(where: { $0 == removed.id })
        if let removedDocument = documents.removeValue(forKey: removed.documentID) {
            buffers.removeValue(forKey: removedDocument.bufferID)
            fileBindings.removeValue(forKey: removedDocument.id)
            languageOverrides.removeValue(forKey: removedDocument.id)
        }
        if activeTabID == tabID {
            let deterministicNeighbor = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            activeTabID = activationHistory.reversed().first(where: { historyID in
                tabs.contains(where: { $0.id == historyID })
            }) ?? deterministicNeighbor
            if let activeTabID { recordActivation(activeTabID) }
        }
        return activeTabID
    }

    public func closedTabState(for tabID: TabID) throws -> ClosedTabState {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            throw SessionError.unknownTab(tabID)
        }
        let tab = tabs[index]
        let document = try document(for: tabID)
        guard let buffer = buffers[document.bufferID] else {
            throw SessionError.brokenBufferReference(document.bufferID)
        }
        return ClosedTabState(
            originalIndex: index,
            tab: tab,
            document: document,
            buffer: buffer,
            fileBinding: fileBindings[document.id],
            languageOverride: languageOverrides[document.id]
        )
    }

    /// Restores stable IDs and metadata while respecting the pinned-prefix
    /// invariant. The restored tab becomes active, matching browser/native
    /// Undo Close Tab behavior.
    @discardableResult
    public mutating func restoreClosedTab(_ state: ClosedTabState) throws -> Int {
        guard !tabs.contains(where: { $0.id == state.tab.id }) else {
            throw SessionError.invalidRecoveryState("duplicate restored tab ID")
        }
        guard documents[state.document.id] == nil else {
            throw SessionError.invalidRecoveryState("duplicate restored document ID")
        }
        guard buffers[state.buffer.id] == nil else {
            throw SessionError.duplicateBufferID(state.buffer.id)
        }
        guard state.tab.documentID == state.document.id,
              state.document.bufferID == state.buffer.id else {
            throw SessionError.invalidRecoveryState("broken closed tab state")
        }
        if let binding = state.fileBinding,
           fileBindings.values.contains(where: { $0.canonicalPath == binding.canonicalPath }) {
            throw SessionError.duplicateFileBinding(binding.canonicalPath)
        }

        documents[state.document.id] = state.document
        buffers[state.buffer.id] = state.buffer
        if let binding = state.fileBinding { fileBindings[state.document.id] = binding }
        if let override = state.languageOverride { languageOverrides[state.document.id] = override }

        let pinnedCount = tabs.prefix(while: \.isPinned).count
        let index: Int
        if state.tab.isPinned {
            index = min(max(state.originalIndex, 0), pinnedCount)
        } else {
            index = min(max(state.originalIndex, pinnedCount), tabs.count)
        }
        tabs.insert(state.tab, at: index)
        activeTabID = state.tab.id
        recordActivation(state.tab.id)
        return index
    }

    public var lastUsedTabID: TabID? {
        activationHistory.reversed().first(where: { $0 != activeTabID })
    }

    private mutating func recordActivation(_ tabID: TabID) {
        activationHistory.removeAll(where: { $0 == tabID })
        activationHistory.append(tabID)
    }

    @discardableResult
    public mutating func recordEdit(in tabID: TabID, expectedRevision: UInt64) throws -> UInt64 {
        let document = try document(for: tabID)
        guard var buffer = buffers[document.bufferID] else {
            throw SessionError.brokenBufferReference(document.bufferID)
        }
        let revision = try buffer.recordEdit(expectedRevision: expectedRevision)
        buffers[buffer.id] = buffer
        return revision
    }

    public func document(for tabID: TabID) throws -> ScratchDocument {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            throw SessionError.unknownTab(tabID)
        }
        guard let document = documents[tab.documentID] else {
            throw SessionError.brokenDocumentReference(tab.documentID)
        }
        return document
    }

    public func buffer(for tabID: TabID) throws -> BufferMetadata {
        let document = try document(for: tabID)
        guard let buffer = buffers[document.bufferID] else {
            throw SessionError.brokenBufferReference(document.bufferID)
        }
        return buffer
    }


    public func fileBinding(for tabID: TabID) throws -> FileBinding? {
        let document = try document(for: tabID)
        return fileBindings[document.id]
    }

    public func languageOverride(for tabID: TabID) throws -> LanguageOverride {
        let document = try document(for: tabID)
        return languageOverrides[document.id] ?? .automatic
    }

    public mutating func setLanguageOverride(_ override: LanguageOverride, for tabID: TabID) throws {
        let document = try document(for: tabID)
        switch override {
        case .automatic:
            languageOverrides.removeValue(forKey: document.id)
        case .manual:
            languageOverrides[document.id] = override
        }
    }

    public func tabID(canonicalPath: String) -> TabID? {
        tabs.first { tab in
            fileBindings[tab.documentID]?.canonicalPath == canonicalPath
        }?.id
    }

    public mutating func bindFile(
        tabID: TabID,
        binding: FileBinding,
        title: String,
        cleanAtRevision savedRevision: UInt64? = nil
    ) throws {
        let document = try document(for: tabID)
        if let duplicate = self.tabID(canonicalPath: binding.canonicalPath), duplicate != tabID {
            throw SessionError.duplicateFileBinding(binding.canonicalPath)
        }
        var updated = document
        updated.title = title
        documents[document.id] = updated
        fileBindings[document.id] = binding
        guard var buffer = buffers[document.bufferID] else {
            throw SessionError.brokenBufferReference(document.bufferID)
        }
        if savedRevision == nil || savedRevision == buffer.revision { buffer.markClean() }
        buffers[buffer.id] = buffer
    }

    /// Refreshes sandbox authority without changing the document title,
    /// revision, dirty bit, selection, or activation order.
    public mutating func updateFileBinding(
        tabID: TabID,
        binding: FileBinding,
        expectedBinding: FileBinding
    ) throws {
        let document = try document(for: tabID)
        guard fileBindings[document.id] == expectedBinding else {
            throw SessionError.fileBindingConflict(documentID: document.id)
        }
        if let duplicate = self.tabID(canonicalPath: binding.canonicalPath), duplicate != tabID {
            throw SessionError.duplicateFileBinding(binding.canonicalPath)
        }
        fileBindings[document.id] = binding
    }

    @discardableResult
    public mutating func replaceFileContents(
        tabID: TabID,
        binding: FileBinding,
        title: String,
        expectedRevision: UInt64,
        expectedBinding: FileBinding?
    ) throws -> UInt64 {
        let document = try document(for: tabID)
        guard var buffer = buffers[document.bufferID] else {
            throw SessionError.brokenBufferReference(document.bufferID)
        }
        guard buffer.revision == expectedRevision else {
            throw SessionError.revisionConflict(
                bufferID: buffer.id,
                expected: expectedRevision,
                actual: buffer.revision
            )
        }
        guard fileBindings[document.id] == expectedBinding else {
            throw SessionError.fileBindingConflict(documentID: document.id)
        }
        try bindFile(tabID: tabID, binding: binding, title: title)
        let revision = try buffer.replaceContents()
        buffers[buffer.id] = buffer
        return revision
    }
}
