import AppKit
import DuckpadApplication
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct WindowFramePersistenceTests {
    @Test @MainActor func freshWorkspaceKeepsItsInitialContentSize() throws {
        _ = NSApplication.shared
        let controller = DuckpadWindowController(
            workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            automaticallyStarts: false
        )
        defer { controller.close() }
        controller.showAndFocus()
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width >= 900)
        #expect(window.contentLayoutRect.height >= 620)
    }

    @Test @MainActor func refocusingAnOpenWorkspaceDoesNotRecenterIt() throws {
        _ = NSApplication.shared
        let controller = DuckpadWindowController(
            workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            automaticallyStarts: false
        )
        defer { controller.close() }
        controller.showAndFocus()
        let window = try #require(controller.window)
        let screen = try #require(window.screen).visibleFrame
        window.setFrameOrigin(NSPoint(x: screen.minX + 30, y: screen.minY + 40))
        let movedFrame = window.frame
        controller.showAndFocus()
        #expect(window.frame == movedFrame)
    }
    @Test @MainActor func resizedFrameSurvivesClosingAndRecreatingControllerAndDefaults() throws {
        _ = NSApplication.shared
        let suite = "duckpad-window-frame-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeController(defaults: defaults, key: "primary")
        first.showAndFocus()
        let firstWindow = try #require(first.window)
        let visible = try #require(firstWindow.screen).visibleFrame
        firstWindow.setFrame(NSRect(
            x: visible.minX + 35, y: visible.minY + 45,
            width: min(1_100, visible.width - 70), height: min(750, visible.height - 90)
        ), display: true)
        let expected = firstWindow.frame
        first.close()

        let relaunchedDefaults = try #require(UserDefaults(suiteName: suite))
        let restored = makeController(defaults: relaunchedDefaults, key: "primary")
        defer { restored.close() }
        restored.showAndFocus()
        #expect(restored.window?.frame == expected)
    }

    @Test @MainActor func additionalWindowsKeepTheirOwnFramesAndNewWindowsUseTheLastFrame() throws {
        _ = NSApplication.shared
        let suite = "duckpad-window-frame-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeController(defaults: defaults, key: "primary")
        first.showAndFocus()
        let firstWindow = try #require(first.window)
        firstWindow.setContentSize(NSSize(width: 950, height: 630))
        let firstFrame = firstWindow.frame
        first.close()

        let second = makeController(defaults: defaults, key: "secondary")
        second.showAndFocus()
        #expect(second.window?.frame == firstFrame)
        second.window?.setContentSize(NSSize(width: 1_050, height: 700))
        let secondFrame = second.window?.frame
        second.close()

        let firstRestored = makeController(defaults: defaults, key: "primary")
        let secondRestored = makeController(defaults: defaults, key: "secondary")
        defer { firstRestored.close(); secondRestored.close() }
        #expect(firstRestored.window?.frame == firstFrame)
        #expect(secondRestored.window?.frame == secondFrame)
    }

    @Test @MainActor func disconnectedDisplayFramesAreBroughtOntoAnAvailableScreen() throws {
        _ = NSApplication.shared
        let suite = "duckpad-window-frame-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["x": 1_000_000.0, "y": 1_000_000.0, "width": 12_000.0, "height": 9_000.0], forKey: "primary")
        let controller = makeController(defaults: defaults, key: "primary")
        defer { controller.close() }
        let frame = try #require(controller.window?.frame)
        #expect(NSScreen.screens.contains { $0.visibleFrame.contains(frame) })
        #expect(frame.width >= 420)
        #expect(frame.height >= 280)
    }

    @Test @MainActor func malformedFrameUsesTheNormalInitialSize() throws {
        _ = NSApplication.shared
        let suite = "duckpad-window-frame-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["x": 0, "y": 0, "width": -200, "height": 0], forKey: "primary")
        let controller = makeController(defaults: defaults, key: "primary")
        defer { controller.close() }
        controller.showAndFocus()
        #expect(controller.window?.contentLayoutRect.size == NSSize(width: 900, height: 620))
    }

    @MainActor private func makeController(defaults: UserDefaults, key: String) -> DuckpadWindowController {
        DuckpadWindowController(
            workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            framePersistence: WindowFramePersistence(defaults: defaults, frameKey: key, fallbackKey: "last"),
            automaticallyStarts: false
        )
    }

}
