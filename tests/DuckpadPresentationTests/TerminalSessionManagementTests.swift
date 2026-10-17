import AppKit
import DuckpadApplication
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct TerminalSessionManagementTests {
    @Test func bulkTargetsAreRelativeToClickedTab() throws {
        let store = TerminalSessionStore()
        let config = ShellLaunchConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        for _ in 0..<5 { store.create(configuration: config) }
        let ids = store.sessions.map(\.id)
        #expect(TerminalSessionCloseScope.left.targets(in: store.sessions, relativeTo: ids[2]) == Array(ids.prefix(2)))
        #expect(TerminalSessionCloseScope.right.targets(in: store.sessions, relativeTo: ids[2]) == Array(ids.suffix(2)))
        #expect(TerminalSessionCloseScope.others.targets(in: store.sessions, relativeTo: ids[2]) == ids.filter { $0 != ids[2] })
        #expect(TerminalSessionCloseScope.all.targets(in: store.sessions, relativeTo: nil) == ids)
        #expect(TerminalSessionCloseScope.left.targets(in: store.sessions, relativeTo: ids[0]).isEmpty)
        #expect(TerminalSessionCloseScope.right.targets(in: store.sessions, relativeTo: ids[4]).isEmpty)
    }

    @Test func cancellationDoesNotRememberSuppressionAndAcceptedPreferencePersists() throws {
        _ = NSApplication.shared
        let suite = "duckpad.test.terminal.confirm.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let confirmation = TerminalCloseConfirmation(defaults: defaults)
        confirmation.present = { alert in
            alert.suppressionButton?.state = .on
            return .alertSecondButtonReturn
        }
        #expect(!confirmation.confirm(multiple: false, catalog: L10n.catalog))
        #expect(confirmation.isEnabled)
        confirmation.present = { alert in
            #expect(alert.showsSuppressionButton)
            alert.suppressionButton?.state = .on
            return .alertFirstButtonReturn
        }
        #expect(confirmation.confirm(multiple: true, catalog: L10n.catalog))
        let nextWindow = TerminalCloseConfirmation(defaults: defaults)
        nextWindow.present = { _ in Issue.record("Suppressed confirmation must not open a dialog"); return .alertSecondButtonReturn }
        #expect(nextWindow.confirm(multiple: false, catalog: L10n.catalog))
        nextWindow.isEnabled = true
        #expect(confirmation.isEnabled)
    }

    @Test func bulkCloseIsAtomicOneConfirmationAndOneUndoStep() throws {
        _ = NSApplication.shared
        let suite = "duckpad.test.terminal.bulk.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let confirmation = TerminalCloseConfirmation(defaults: defaults)
        var alertCount = 0
        var approve = false
        confirmation.present = { _ in alertCount += 1; return approve ? .alertFirstButtonReturn : .alertSecondButtonReturn }
        let sessions = TerminalSessionStore()
        let panel = TerminalPanelView(sessions: sessions, surfaceFactory: { _ in LiveSessionSurface() }, closeConfirmation: confirmation)
        defer { panel.shutdown() }
        let config = ShellLaunchConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))
        for _ in 0..<5 { sessions.create(configuration: config); panel.reload() }
        let original = sessions.sessions
        let clicked = original[2].id
        panel.closeSessions(.others, relativeTo: clicked)
        #expect(sessions.sessions == original)
        #expect(alertCount == 1)
        approve = true
        panel.closeSessions(.others, relativeTo: clicked)
        #expect(sessions.sessions.map(\.id) == [clicked])
        #expect(alertCount == 2)
        panel.handle(.undo)
        #expect(sessions.sessions == original)
        panel.closeSessions(.all, relativeTo: clicked)
        #expect(sessions.sessions.isEmpty)
        #expect(alertCount == 3)
        let emptyMenu = panel.makeSessionMenu(relativeTo: nil)
        #expect(emptyMenu.items.filter { TerminalSessionCloseScope(rawValue: $0.identifier?.rawValue ?? "") != nil }.allSatisfy { !$0.isEnabled })
        panel.handle(.undo)
        #expect(sessions.sessions == original)
    }
}

@MainActor private final class LiveSessionSurface: TerminalSurfaceView {
    override var needsCloseConfirmation: Bool { true }
}
