import AppKit
import GhosttyKit
import DuckpadApplication
import DuckpadPresentation

/// Created on the first terminal request, never on the editor's startup path.
@MainActor
public final class GhosttyRuntime: NSObject {
    private(set) var app: ghostty_app_t?
    private var initialized = false
    weak var focusedSurface: GhosttySurfaceView?
    private let surfaces = NSHashTable<GhosttySurfaceView>.weakObjects()
    private var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duckpad/terminal.conf")
    }

    public func makeSurface(configuration: ShellLaunchConfiguration) -> TerminalSurfaceView {
        initialize()
        let view = GhosttySurfaceView(runtime: self, configuration: configuration)
        surfaces.add(view)
        return view
    }

    public func refreshLocalization() {
        for surface in surfaces.allObjects { surface.inspectorController?.refreshLocalization() }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
            setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0,
              let config = ghostty_config_new() else { return }
        defer { ghostty_config_free(config) }
        if let url = Bundle.module.url(forResource: "terminal", withExtension: "conf") {
            url.path.withCString { ghostty_config_load_file(config, $0) }
        }
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            configurationURL.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_finalize(config)
        var callbacks = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(), supports_selection_clipboard: false,
            wakeup_cb: duckpadGhosttyWakeup,
            action_cb: { app, target, action in
                MainActor.assumeIsolated {
                    guard let app, let pointer = ghostty_app_userdata(app) else { return false }
                    return Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue().handle(target: target, action: action)
                }
            },
            read_clipboard_cb: { pointer, _, state in
                MainActor.assumeIsolated {
                    guard let pointer, let state else { return false }
                    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(pointer).takeUnretainedValue()
                    guard let surface = view.surface, let text = NSPasteboard.general.string(forType: .string) else { return false }
                    text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
                    return true
                }
            },
            confirm_read_clipboard_cb: { pointer, text, state, _ in
                MainActor.assumeIsolated {
                    guard let pointer, let text, let state else { return }
                    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(pointer).takeUnretainedValue()
                    view.confirmPaste(String(cString: text), state: state)
                }
            },
            write_clipboard_cb: { _, _, contents, count, confirm in
                MainActor.assumeIsolated {
                    guard !confirm, let contents else { return }
                    for i in 0..<count {
                        let content = contents[i]
                        guard let mime = content.mime, String(cString: mime) == "text/plain", let data = content.data else { continue }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(cString: data), forType: .string)
                        break
                    }
                }
            },
            close_surface_cb: { pointer, _ in
                guard let pointer else { return }
                MainActor.assumeIsolated {
                    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(pointer).takeUnretainedValue()
                    // Do not free a surface while its callback is on the stack.
                    DispatchQueue.main.async { [weak view] in view?.onAction?(.closeSurface) }
                }
            }
        )
        app = ghostty_app_new(&callbacks, config)
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        focusChanged()
    }

    func openConfiguration() {
        do {
            try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: configurationURL.path) {
                try "# Duckpad terminal — Ghostty configuration\n".write(to: configurationURL, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(configurationURL)
        } catch { NSApp.presentError(error) }
    }

    func reloadConfiguration() {
        guard let app, let config = ghostty_config_new() else { return }
        defer { ghostty_config_free(config) }
        if let url = Bundle.module.url(forResource: "terminal", withExtension: "conf") {
            url.path.withCString { ghostty_config_load_file(config, $0) }
        }
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            configurationURL.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_finalize(config)
        ghostty_app_update_config(app, config)
        for view in surfaces.allObjects {
            if let surface = view.surface { ghostty_surface_update_config(surface, config) }
        }
    }

    @objc private func focusChanged() { if let app { ghostty_app_set_focus(app, NSApp.isActive) } }
    @objc private func keyboardChanged() { if let app { ghostty_app_keyboard_changed(app) } }
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        if let app { ghostty_app_free(app) }
    }
}

private func duckpadGhosttyWakeup(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue()
    DispatchQueue.main.async { if let app = runtime.app { ghostty_app_tick(app) } }
}
