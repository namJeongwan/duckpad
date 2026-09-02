import Foundation

public struct BufferMetadata: Equatable, Sendable {
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

public struct ScratchDocument: Equatable, Sendable {
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

public struct WorkspaceTab: Equatable, Sendable {
    public let id: TabID
    public let documentID: DocumentID
    public var isPinned: Bool

    public init(id: TabID = TabID(), documentID: DocumentID, isPinned: Bool = false) {
        self.id = id
        self.documentID = documentID
        self.isPinned = isPinned
    }
}

public enum SessionError: Error, Equatable, Sendable {
    case unknownTab(TabID)
    case brokenDocumentReference(DocumentID)
    case brokenBufferReference(BufferID)
    case dirtyBufferRequiresDecision(BufferID)
    case revisionConflict(bufferID: BufferID, expected: UInt64, actual: UInt64)
    case revisionExhausted(bufferID: BufferID)
    case duplicateBufferID(BufferID)
    case duplicateFileBinding(String)
}

public struct ScratchSession: Equatable, Sendable {
    public let id: SessionID
    public private(set) var tabs: [WorkspaceTab]
    public private(set) var documents: [DocumentID: ScratchDocument]
    public private(set) var buffers: [BufferID: BufferMetadata]
    public private(set) var fileBindings: [DocumentID: FileBinding]
    public private(set) var activeTabID: TabID?
    private var nextUntitledNumber: Int

    public init(id: SessionID = SessionID()) {
        self.id = id
        tabs = []
        documents = [:]
        buffers = [:]
        fileBindings = [:]
        activeTabID = nil
        nextUntitledNumber = 1
    }

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
        return tab.id
    }

    public mutating func activate(tabID: TabID) throws {
        guard tabs.contains(where: { $0.id == tabID }) else {
            throw SessionError.unknownTab(tabID)
        }
        activeTabID = tabID
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
        if let removedDocument = documents.removeValue(forKey: removed.documentID) {
            buffers.removeValue(forKey: removedDocument.bufferID)
            fileBindings.removeValue(forKey: removedDocument.id)
        }
        if activeTabID == tabID {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        return activeTabID
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

    @discardableResult
    public mutating func replaceFileContents(tabID: TabID, binding: FileBinding, title: String) throws -> UInt64 {
        try bindFile(tabID: tabID, binding: binding, title: title)
        let document = try document(for: tabID)
        guard var buffer = buffers[document.bufferID] else {
            throw SessionError.brokenBufferReference(document.bufferID)
        }
        let revision = try buffer.replaceContents()
        buffers[buffer.id] = buffer
        return revision
    }
}
