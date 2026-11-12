import AppKit
import DuckpadNativeABI

@main @MainActor final class ControllerSmoke: NSObject, NSApplicationDelegate {
    private var plugin: DiagramPlugin?
    private var closed = false
    private let source = "client -> server: 한글 🦆"
    static func main() {
        let app = NSApplication.shared, delegate = ControllerSmoke()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var api = DuckpadHostV1()
            api.abi_version = 1; api.struct_size = UInt32(MemoryLayout<DuckpadHostV1>.size)
            api.context = Unmanaged.passUnretained(self).toOpaque()
            api.read_document = { context, buffer, capacity in
                let address = UInt(bitPattern: context!)
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<ControllerSmoke>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
                    let bytes = Array(owner.source.utf8)
                    if let buffer { guard capacity >= bytes.count else { return -1 }; for (i, byte) in bytes.enumerated() { buffer[i] = byte } }
                    return Int64(bytes.count)
                }
            }
            api.close_panel = { context in
                let address = UInt(bitPattern: context!)
                MainActor.assumeIsolated {
                    let owner = Unmanaged<ControllerSmoke>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
                    owner.closed = true; owner.plugin?.panel.removeFromSuperview()
                }
            }
            let host = DuckpadHost(&api)!
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-ui-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: storage) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            for name in ["D2", "Mermaid"] {
                let renderer = ControlledRenderer(settings: name == "D2")
                self.plugin = DiagramPlugin(host: host, config: ["resourceDirectory": CommandLine.arguments[1] + "/" + name,
                    "storageDirectory": storage.appendingPathComponent(name).path, "language": "ko"],
                    definition: DiagramDefinition(name: name, fileExtensions: ["txt"], sample: "a -> b"), renderer: renderer)
                let plugin = self.plugin!
                window.contentView = plugin.show(); window.makeKeyAndOrderFront(nil)
                for language in ["en", "ko", "ja", "zh-Hans", "de", "fr", "it", "pt-BR"] {
                    plugin.setLanguage(language)
                    for width: CGFloat in [300, 560] {
                        window.setContentSize(NSSize(width: width, height: 720)); window.contentView?.layoutSubtreeIfNeeded()
                        for button in self.buttons(plugin.panel) where !button.isHiddenOrHasHiddenAncestor {
                            let frame = button.convert(button.bounds, to: plugin.panel)
                            precondition(frame.minX >= -1 && frame.maxX <= plugin.panel.bounds.width + 1, "Controls outside narrow panel: \(name), \(language)")
                        }
                    }
                }
                plugin.setLanguage("ko"); plugin.panel.onSettings?()
                precondition(NSApp.windows.contains { $0.isVisible && $0 !== window } == renderer.hasRuntimeSettings)
                NSApp.windows.filter { $0 !== window }.forEach { $0.close() }
                plugin.panel.onRender?(); await Task.yield(); renderer.succeed()
                try? await Task.sleep(for: .milliseconds(50))
                precondition(self.buttons(plugin.panel).contains { $0.title == "PNG" && $0.isEnabled })
                plugin.panel.onExpand?()
                let expanded = NSApp.windows.first { $0.isVisible && $0 !== window }!
                let koreanTitle = expanded.title
                plugin.setLanguage("en")
                precondition(expanded.title == name + " preview" && expanded.title != koreanTitle)
                expanded.close()
                plugin.panel.onRender?(); await Task.yield()
                precondition(!self.buttons(plugin.panel).contains { $0.title == "PNG" && $0.isEnabled }, "Stale export must be disabled")
                plugin.panel.onClose?(); renderer.succeed()
                try? await Task.sleep(for: .milliseconds(50))
                precondition(self.closed && !self.buttons(plugin.panel).contains { $0.title == "PNG" && $0.isEnabled }, "Late render must not restore closed preview")
                for character in ["w", "ㅈ", "\u{17}"] {
                    self.closed = false; window.contentView = plugin.show(); window.makeKeyAndOrderFront(nil)
                    NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                        charactersIgnoringModifiers: character, isARepeat: false, keyCode: 13)!, atStart: false)
                    try? await Task.sleep(for: .milliseconds(100))
                    precondition(self.closed && plugin.panel.window == nil && window.isVisible)
                }
                plugin.stop(); plugin.stop()
                precondition(host.documentText() == self.source)
                print("PASS: \(name), eight locales at 300/560pt, settings, stale exports, late replies, Ctrl+W with Korean input, teardown and unchanged source")
            }
            window.close(); self.plugin = nil; fflush(stdout); NSApp.terminate(nil)
        }
    }
    private func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
}
