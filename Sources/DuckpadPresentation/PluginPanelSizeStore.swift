import AppKit
import DuckpadDomain

@MainActor
final class PluginPanelSizeStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    func width(for command: ExtensionCommandID) -> CGFloat {
        let saved = defaults.double(forKey: key(command))
        return saved.isFinite && saved > 0 ? saved : 340
    }

    func save(_ width: CGFloat, for command: ExtensionCommandID) {
        guard width.isFinite, width > 0 else { return }
        defaults.set(Double(width), forKey: key(command))
    }

    private func key(_ command: ExtensionCommandID) -> String {
        "duckpad.plugin.panel.width." + command.rawValue
    }
}
