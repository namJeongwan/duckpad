import Foundation
import DuckpadApplication
import Testing

@MainActor
struct TerminalSessionStoreTests {
    @Test func sessionSelectionPreservesEachLaunchConfiguration() throws {
        let store = TerminalSessionStore()
        let first = try #require(store.create(configuration: .init(workingDirectory: URL(fileURLWithPath: "/tmp/one"))))
        let second = try #require(store.create(configuration: .init(workingDirectory: URL(fileURLWithPath: "/tmp/two"))))
        #expect(first.id != second.id)
        #expect(store.selectedID == second.id)
        store.select(first.id)
        #expect(store.selectedSession?.configuration.workingDirectory.path == "/tmp/one")
        store.select(UUID())
        #expect(store.selectedID == first.id)
        store.remove(second.id)
        #expect(store.selectedID == first.id)
    }

    @Test func closingSelectedSessionChoosesNeighborAndEventuallyClearsSelection() throws {
        let store = TerminalSessionStore()
        let configuration = ShellLaunchConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        let first = try #require(store.create(configuration: configuration))
        let middle = try #require(store.create(configuration: configuration))
        let last = try #require(store.create(configuration: configuration))
        store.select(middle.id)
        store.remove(middle.id)
        #expect(store.selectedID == last.id)
        store.remove(last.id)
        #expect(store.selectedID == first.id)
        store.remove(first.id)
        #expect(store.selectedSession == nil)
        #expect(store.sessions.isEmpty)
        let replacement = try #require(store.create(configuration: configuration))
        #expect(replacement.number == 4)
        #expect(replacement.id != first.id)
    }

    @Test func sessionsBeyondEightPreserveSelectionAndRestoreWithoutEviction() throws {
        let store = TerminalSessionStore()
        let configuration = ShellLaunchConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        for _ in 0..<32 { #expect(store.create(configuration: configuration) != nil) }
        let before = store.sessions
        let selected = store.selectedID
        #expect(before.count == 32)
        store.removeAll()
        store.restore(before, selectedID: selected)
        #expect(store.sessions == before)
        #expect(store.selectedID == selected)
        store.removeAll()
        #expect(store.sessions.isEmpty)
        #expect(store.selectedID == nil)
    }
}
