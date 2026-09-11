// Manual macOS localization probe. Compile into an .app declaring en/ko
// localizations, then launch with PROBE_LANGUAGE=en or PROBE_LANGUAGE=ko.
// Only this probe's preferences change; file panels are cancelled without I/O.
import AppKit

@MainActor
final class LanguageReloadProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var label: NSTextField!
    private var panel: NSSavePanel?
    private var language = ProcessInfo.processInfo.environment["PROBE_LANGUAGE"] ?? "en"

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        label = NSTextField(labelWithString: "")
        let stack = NSStackView(views: [label,
            NSButton(title: "Open panel", target: self, action: #selector(openPanel)),
            NSButton(title: "Save panel", target: self, action: #selector(savePanel)),
            NSButton(title: "Switch language", target: self, action: #selector(switchLanguage))])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.frame = window.contentView!.bounds.insetBy(dx: 20, dy: 20)
        stack.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(stack)
        refreshLabel()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func refreshLabel() {
        window.title = "Language probe — requested: \(language)"
        let bundle = Bundle(url: Bundle.main.resourceURL!.appendingPathComponent(language + ".lproj"))!
        label.stringValue = bundle.localizedString(forKey: "Sample", value: nil, table: nil)
        print("requested=\(language) preferred=\(Bundle.main.preferredLocalizations) own=\(label.stringValue)")
    }

    @objc private func switchLanguage() {
        language = language == "en" ? "ko" : "en"
        UserDefaults.standard.set([language], forKey: "AppleLanguages")
        refreshLabel()
    }

    @objc private func openPanel() { present(NSOpenPanel()) }
    @objc private func savePanel() { present(NSSavePanel()) }

    private func present(_ panel: NSSavePanel) {
        self.panel = panel
        panel.directoryURL = Bundle.main.bundleURL.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] _ in self?.panel = nil }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

setbuf(stdout, nil)
UserDefaults.standard.set([ProcessInfo.processInfo.environment["PROBE_LANGUAGE"] ?? "en"], forKey: "AppleLanguages")
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = LanguageReloadProbe()
    app.delegate = delegate
    app.run()
}
