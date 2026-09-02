import DuckpadDomain
import Testing

@Test func createsTypedUntitledScratchWithoutOwningText() throws {
    var session = ScratchSession()
    let tabID = session.addUntitled()
    let document = try session.document(for: tabID)
    let buffer = try session.buffer(for: tabID)
    #expect(session.activeTabID == tabID)
    #expect(session.tabs.count == 1)
    #expect(document.fileURL == nil)
    #expect(document.title == "new 1")
    #expect(document.bufferID == buffer.id)
    #expect(buffer.revision == 0)
    #expect(!buffer.isDirty)
}

@Test func incrementalEditAdvancesOnlyExpectedBufferRevision() throws {
    var session = ScratchSession()
    let first = session.addUntitled()
    let second = session.addUntitled()
    #expect(try session.recordEdit(in: first, expectedRevision: 0) == 1)
    #expect(try session.buffer(for: first).revision == 1)
    #expect(try session.buffer(for: first).isDirty)
    #expect(try session.buffer(for: second).revision == 0)
    #expect(!session.buffers.values.contains { String(describing: $0).contains("paste first") })
}

@Test func staleRevisionIsRejectedWithoutMutation() throws {
    var session = ScratchSession()
    let tab = session.addUntitled()
    #expect(throws: SessionError.self) {
        try session.recordEdit(in: tab, expectedRevision: 7)
    }
    #expect(try session.buffer(for: tab).revision == 0)
    #expect(try !session.buffer(for: tab).isDirty)
}

@Test func revisionOverflowFailsClosed() throws {
    var session = ScratchSession()
    let buffer = BufferMetadata(revision: UInt64.max, isDirty: true)
    let tab = try session.addUntitled(buffer: buffer)
    #expect(throws: SessionError.revisionExhausted(bufferID: buffer.id)) {
        try session.recordEdit(in: tab, expectedRevision: UInt64.max)
    }
    #expect(try session.buffer(for: tab).revision == UInt64.max)
}

@Test func duplicateBufferOwnershipFailsClosedWithoutCorruptingAggregate() throws {
    var session = ScratchSession()
    let shared = BufferMetadata()
    let original = try session.addUntitled(buffer: shared)
    #expect(throws: SessionError.duplicateBufferID(shared.id)) {
        try session.addUntitled(buffer: shared)
    }
    #expect(session.tabs.map(\.id) == [original])
    #expect(try session.buffer(for: original).id == shared.id)
}

@Test func dirtyBufferCannotBeClosedWithoutExplicitDiscard() throws {
    var session = ScratchSession()
    let tab = session.addUntitled()
    _ = try session.recordEdit(in: tab, expectedRevision: 0)
    let bufferID = try session.buffer(for: tab).id
    #expect(throws: SessionError.dirtyBufferRequiresDecision(bufferID)) {
        try session.close(tabID: tab)
    }
    #expect(session.tabs.map(\.id) == [tab])
    #expect(try session.close(tabID: tab, discardingDirty: true) == nil)
}

@Test func closingActiveTabSelectsStableNeighbor() throws {
    var session = ScratchSession()
    let first = session.addUntitled()
    let second = session.addUntitled()
    try session.activate(tabID: first)
    #expect(try session.close(tabID: first) == second)
    #expect(session.tabs.map(\.id) == [second])
}
