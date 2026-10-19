import AppKit
import Darwin
import GhosttyKit
import DuckpadLocalization
import DuckpadDomain
@testable import DuckpadTerminalAdapter
import Testing

@Suite(.serialized) @MainActor
struct InspectorLocaleChangeTests {
    @Test func openInspectorRecreatesItsFontAtlasWhenSwitchingFromEnglishToCJK() throws {
        _ = NSApplication.shared
        let language = L10n.catalog.language
        defer { L10n.configure(language: language) }
        L10n.configure(language: .english)
        #expect(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0)
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        var callbacks = ghostty_runtime_config_s()
        callbacks.wakeup_cb = { _ in }
        callbacks.action_cb = { _, _, _ in false }
        callbacks.read_clipboard_cb = { _, _, _ in false }
        let app = try #require(ghostty_app_new(&callbacks, config))
        defer { ghostty_app_free(app) }
        var master: Int32 = -1, slave: Int32 = -1
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { Darwin.close(slave); Darwin.close(master) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        let terminal = try #require(host.contentView)
        terminal.wantsLayer = true
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(terminal).toOpaque()
        surfaceConfig.font_size = 12
        let surface = try "DUCKPAD_HOST_PTY_FD".withCString { name in
            try String(master).withCString { value in
                var variable = ghostty_env_var_s(key: name, value: value)
                return try withUnsafeMutablePointer(to: &variable) {
                    surfaceConfig.env_vars = $0; surfaceConfig.env_var_count = 1
                    return try #require(ghostty_surface_new(app, &surfaceConfig))
                }
            }
        }
        defer { ghostty_surface_free(surface) }
        ghostty_surface_set_size(surface, 760, 480)
        let controller = try #require(GhosttyInspectorController(surface: surface))
        defer { controller.shutdown() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let frame = window.frame
        for nextLanguage in [DuckpadDomain.AppLanguage.korean, .japanese, .simplifiedChinese, .english] {
            let previousView = try #require(window.contentView)
            L10n.configure(language: nextLanguage)
            controller.refreshLocalization()
            #expect(window.contentView !== previousView)
            #expect(window.contentView is GhosttyInspectorView)
            #expect(window.frame == frame)
            #expect(window.title == L10n.text("Terminal Inspector"))
            #expect(ghostty_surface_inspector(surface) != nil)
            #expect(window.isVisible)
        }
    }
}
