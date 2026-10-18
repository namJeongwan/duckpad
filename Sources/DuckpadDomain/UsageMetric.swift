/// Only operational metadata belongs in usage statistics. Never pass document text,
/// paths, command arguments, or error descriptions through this interface.
public struct UsageMetric: Sendable {
    public enum Kind: String, Sendable {
        case firstObserved = "app_first_observed"
        case activeDay = "app_active_day"
        case versionChanged = "app_version_changed"
        case editMinute = "editor_active_minute"
        case feature = "feature_used"
        case pluginInstall = "plugin_installed"
        case pluginUpdate = "plugin_updated"
        case pluginRemove = "plugin_removed"
        case pluginInvoke = "plugin_invoked"
        case pluginPanel = "plugin_panel_opened"
        case format = "format_completed"
    }

    public enum Feature: String, Sendable {
        case find, replace, findInFolder = "find_in_folder", terminal, markdownPreview = "markdown_preview"
    }

    public enum Outcome: String, Sendable { case used, success, failed, cancelled }

    public let kind: Kind
    public let dimension: String
    public let outcome: Outcome
    public let duration: Double?

    public init(_ kind: Kind, dimension: String = "", outcome: Outcome = .used, duration: Double? = nil) {
        self.kind = kind
        self.dimension = dimension
        self.outcome = outcome
        self.duration = duration
    }

    public static func feature(_ feature: Feature) -> UsageMetric {
        .init(.feature, dimension: feature.rawValue)
    }
}
