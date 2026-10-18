import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Test @MainActor func usagePreferencePersistsOptOutAndRendersAllLanguages() async throws {
    _ = NSApplication.shared
    let controller = DuckpadSettingsWindowController()
    defer { controller.close() }
    var saved = AppSettings.defaults
    var updateTask: Task<Void, Never>?
    controller.onUpdateTaskStarted = { updateTask = $0 }
    controller.present(settings: saved) { value in saved = value; return .saved(value) }
    controller.selectCategory("Privacy")
    let root = try #require(controller.window?.contentView)
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    let controls = descendants(root)
    let toggle = try #require(controls.compactMap { $0 as? NSButton }
        .first { $0.title == L10n.text("Share usage statistics") })
    #expect(toggle.state == .on)
    for enabled in [false, true] {
        toggle.state = enabled ? .on : .off
        let action = try #require(toggle.action)
        #expect(NSApplication.shared.sendAction(action, to: toggle.target, from: toggle))
        await updateTask?.value
        #expect(saved.shareUsageStatistics == enabled)
        #expect(saved.defaultWordWrapEnabled == AppSettings.defaults.defaultWordWrapEnabled)
    }
    var showedLog = false
    controller.onShowUsageStatistics = { showedLog = true }
    let log = try #require(controls.compactMap { $0 as? NSButton }
        .first { $0.title == L10n.text("View statistics transmission log") })
    #expect(NSApplication.shared.sendAction(try #require(log.action), to: log.target, from: log))
    #expect(showedLog)

    for language in AppLanguage.allCases where language != .system {
        let catalog = LocalizationCatalog(language: language)
        controller.refreshLocalization(catalog: catalog)
        #expect(toggle.title == catalog.text("Share usage statistics"))
        #expect(toggle.accessibilityLabel() == toggle.title)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            controller.window?.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            let visible = controls.filter { !$0.isHiddenOrHasHiddenAncestor }
            for view in visible where view is NSButton || view is NSTextField {
                let frame = view.convert(view.bounds, to: root)
                #expect(frame.minX >= -1 && frame.maxX <= root.bounds.width + 1)
                #expect(frame.minY >= -1 && frame.maxY <= root.bounds.height + 1)
            }
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_USAGE_UI_OUTPUT"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let window = try #require(controller.window)
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                // Capture this test window only; layer-backed controls are not
                // faithfully rendered by cacheDisplay(in:to:).
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                    output.appendingPathComponent("\(language.rawValue)-\(appearance.rawValue).png").path]
                try capture.run()
                capture.waitUntilExit()
                #expect(capture.terminationStatus == 0)
            }
        }
    }
}

@Test @MainActor func usageNoticeIsNonmodalLocalizedAndDismissible() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let root = try #require(window.contentView)
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 140))
    root.addSubview(editor)
    let notice = UsageStatisticsNoticeView(frame: .zero)
    root.addSubview(notice)
    NSLayoutConstraint.activate([
        notice.topAnchor.constraint(equalTo: root.topAnchor),
        notice.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        notice.trailingAnchor.constraint(equalTo: root.trailingAnchor),
    ])
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor)
    notice.show()
    #expect(window.firstResponder === editor)
    var opened = false
    notice.onSettings = { opened = true }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for language in AppLanguage.allCases where language != .system {
        let catalog = LocalizationCatalog(language: language)
        notice.refreshLocalization(catalog: catalog)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            #expect(notice.bounds.height > 30 && notice.bounds.height < 220)
            for view in descendants(notice) where view is NSButton || view is NSTextField {
                let frame = view.convert(view.bounds, to: notice)
                #expect(frame.minX >= -1 && frame.maxX <= notice.bounds.width + 1)
                #expect(frame.minY >= -1 && frame.maxY <= notice.bounds.height + 1)
            }
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_USAGE_UI_OUTPUT"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                    output.appendingPathComponent("notice-\(language.rawValue)-\(appearance.rawValue).png").path]
                try capture.run()
                capture.waitUntilExit()
                #expect(capture.terminationStatus == 0)
            }
        }
        let settings = try #require(descendants(notice).compactMap { $0 as? NSButton }
            .first { $0.title == catalog.text("Privacy Settings") })
        #expect(NSApplication.shared.sendAction(try #require(settings.action), to: settings.target, from: settings))
        #expect(opened)
        opened = false
    }
    let dismiss = try #require(descendants(notice).compactMap { $0 as? NSButton }
        .first { $0.title == LocalizationCatalog(language: AppLanguage.allCases.last!).text("Dismiss") })
    #expect(NSApplication.shared.sendAction(try #require(dismiss.action), to: dismiss.target, from: dismiss))
    root.layoutSubtreeIfNeeded()
    #expect(notice.isHidden)
    #expect(notice.bounds.height == 0)
}
