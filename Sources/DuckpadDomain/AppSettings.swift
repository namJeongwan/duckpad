public enum AppAppearanceMode: String, CaseIterable, Codable, Equatable, Sendable {
    case system
    case light
    case dark
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let defaults = AppSettings()

    public var schemaVersion: Int
    public var appearanceMode: AppAppearanceMode
    public var defaultWordWrapEnabled: Bool
    public var defaultWrapMarkerVisible: Bool

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        appearanceMode: AppAppearanceMode = .system,
        defaultWordWrapEnabled: Bool = true,
        defaultWrapMarkerVisible: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.appearanceMode = appearanceMode
        self.defaultWordWrapEnabled = defaultWordWrapEnabled
        self.defaultWrapMarkerVisible = defaultWrapMarkerVisible
    }
}
