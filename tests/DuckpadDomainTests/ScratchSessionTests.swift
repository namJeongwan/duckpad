import DuckpadDomain
import Foundation
import Testing

@Test func createsTypedUntitledScratchWithoutOwningText() throws {
    var session = ScratchSession()
    let tabID = session.addUntitled()
    let document = try session.document(for: tabID)
    let buffer = try session.buffer(for: tabID)
    #expect(session.activeTabID == tabID)
    #expect(session.tabs.count == 1)
    #expect(try session.fileBinding(for: tabID) == nil)
    #expect(document.title == "new 1")
    #expect(document.bufferID == buffer.id)
    #expect(buffer.revision == 0)
    #expect(!buffer.isDirty)
}

@Test func languageOverrideRoundTripsAndSurvivesFileBinding() throws {
    var session = ScratchSession()
    let tab = session.addUntitled()
    let swift = LanguageID(rawValue: "swift")
    try session.setLanguageOverride(.manual(swift), for: tab)
    let binding = FileBinding(
        canonicalPath: "/tmp/sample.txt",
        encoding: .utf8,
        byteOrderMark: .absent,
        lineEnding: .lf,
        observedIdentity: FileIdentity(
            canonicalPath: "/tmp/sample.txt", device: 1, inode: 2,
            byteCount: 0, modifiedNanoseconds: 0, contentToken: "empty"
        )
    )
    try session.bindFile(tabID: tab, binding: binding, title: "sample.txt")
    let decoded = try JSONDecoder().decode(ScratchSession.self, from: JSONEncoder().encode(session))
    #expect(try decoded.languageOverride(for: tab) == .manual(swift))
    var automatic = decoded
    try automatic.setLanguageOverride(.automatic, for: tab)
    #expect(try automatic.languageOverride(for: tab) == .automatic)
}

@Test func legacySessionWithoutLanguageOverridesMigratesToAutomatic() throws {
    var session = ScratchSession()
    let tab = session.addUntitled()
    let encoded = try JSONEncoder().encode(session)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "languageOverrides")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ScratchSession.self, from: legacy)
    #expect(try decoded.languageOverride(for: tab) == .automatic)
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

@Test func closingActiveTabUsesMostRecentlyUsedLiveTab() throws {
    var session = ScratchSession()
    let first = session.addUntitled()
    let second = session.addUntitled()
    let third = session.addUntitled()
    try session.activate(tabID: first)
    try session.activate(tabID: second)
    try session.activate(tabID: third)

    #expect(try session.close(tabID: third) == second)
    #expect(session.activeTabID == second)
    #expect(session.activationHistory.last == second)
    #expect(session.lastUsedTabID == first)
}

@Test func pinAndMoveKeepStableLeadingGroups() throws {
    var session = ScratchSession()
    let first = session.addUntitled()
    let second = session.addUntitled()
    let third = session.addUntitled()
    let fourth = session.addUntitled()

    #expect(try session.setPinned(tabID: third, isPinned: true) == 0)
    #expect(session.tabs.map(\.id) == [third, first, second, fourth])
    #expect(try session.moveTab(tabID: fourth, to: 0) == 1)
    #expect(session.tabs.map(\.id) == [third, fourth, first, second])
    #expect(try session.moveTab(tabID: third, to: 3) == 0)
    #expect(try session.setPinned(tabID: third, isPinned: false) == 0)
    #expect(session.tabs.allSatisfy { !$0.isPinned })
}

@Test func phaseFourSessionWithoutActivationHistoryMigratesToActiveOnlyMRU() throws {
    var session = ScratchSession()
    _ = session.addUntitled()
    let active = session.addUntitled()
    let encoded = try JSONEncoder().encode(session)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "activationHistory")
    let phaseFourJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let restored = try JSONDecoder().decode(ScratchSession.self, from: phaseFourJSON)
    #expect(restored.activeTabID == active)
    #expect(restored.activationHistory == [active])
    #expect(restored.tabs.map(\.id) == session.tabs.map(\.id))
}

@Test func recoveredTabsCannotShareDocumentOrLeaveDanglingStateAfterClose() throws {
    var valid = ScratchSession()
    let first = valid.addUntitled()
    let second = valid.addUntitled()
    let sharedDocument = try valid.document(for: first).id
    var invalidTabs = valid.tabs
    invalidTabs[1] = WorkspaceTab(
        id: invalidTabs[1].id,
        documentID: sharedDocument,
        isPinned: invalidTabs[1].isPinned
    )

    #expect(throws: SessionError.self) {
        try ScratchSession(
            id: valid.id,
            tabs: invalidTabs,
            documents: valid.documents,
            buffers: valid.buffers,
            fileBindings: valid.fileBindings,
            activeTabID: second,
            nextUntitledNumber: valid.recoveryNextUntitledNumber
        )
    }

    _ = try valid.close(tabID: first)
    #expect(valid.tabs.map(\.id) == [second])
    #expect(try valid.document(for: second).id == valid.tabs[0].documentID)
    #expect(try valid.buffer(for: second).id == valid.documents[valid.tabs[0].documentID]?.bufferID)
}
