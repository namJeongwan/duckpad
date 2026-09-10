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

    public var menuBarVisible: Bool
    public var statusBarVisible: Bool
    public var tabDragEnabled: Bool
    public var showTabCloseButton: Bool
    public var showInactiveTabButtons: Bool
    public var lineNumbersVisible: Bool
    public var bookmarkMarginVisible: Bool
    public var highlightCurrentLine: Bool
    public var caretWidth: Int
    public var caretBlinkPeriod: Int
    public var scrollBeyondLastLine: Bool
    public var wrapIndentMode: Int

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        appearanceMode: AppAppearanceMode = .system,
        defaultWordWrapEnabled: Bool = true,
        defaultWrapMarkerVisible: Bool = false,
        menuBarVisible: Bool = true,
        statusBarVisible: Bool = true,
        tabDragEnabled: Bool = true,
        showTabCloseButton: Bool = true,
        showInactiveTabButtons: Bool = false,
        lineNumbersVisible: Bool = true,
        bookmarkMarginVisible: Bool = true,
        highlightCurrentLine: Bool = true,
        caretWidth: Int = 1,
        caretBlinkPeriod: Int = 500,
        scrollBeyondLastLine: Bool = false,
        wrapIndentMode: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.appearanceMode = appearanceMode
        self.defaultWordWrapEnabled = defaultWordWrapEnabled
        self.defaultWrapMarkerVisible = defaultWrapMarkerVisible
        self.menuBarVisible = menuBarVisible
        self.statusBarVisible = statusBarVisible
        self.tabDragEnabled = tabDragEnabled
        self.showTabCloseButton = showTabCloseButton
        self.showInactiveTabButtons = showInactiveTabButtons
        self.lineNumbersVisible = lineNumbersVisible
        self.bookmarkMarginVisible = bookmarkMarginVisible
        self.highlightCurrentLine = highlightCurrentLine
        self.caretWidth = caretWidth
        self.caretBlinkPeriod = caretBlinkPeriod
        self.scrollBeyondLastLine = scrollBeyondLastLine
        self.wrapIndentMode = wrapIndentMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        appearanceMode = try values.decode(AppAppearanceMode.self, forKey: .appearanceMode)
        defaultWordWrapEnabled = try values.decode(Bool.self, forKey: .defaultWordWrapEnabled)
        defaultWrapMarkerVisible = try values.decode(Bool.self, forKey: .defaultWrapMarkerVisible)
        menuBarVisible = try values.decodeIfPresent(Bool.self, forKey: .menuBarVisible) ?? true
        statusBarVisible = try values.decodeIfPresent(Bool.self, forKey: .statusBarVisible) ?? true
        tabDragEnabled = try values.decodeIfPresent(Bool.self, forKey: .tabDragEnabled) ?? true
        showTabCloseButton = try values.decodeIfPresent(Bool.self, forKey: .showTabCloseButton) ?? true
        showInactiveTabButtons = try values.decodeIfPresent(Bool.self, forKey: .showInactiveTabButtons) ?? false
        lineNumbersVisible = try values.decodeIfPresent(Bool.self, forKey: .lineNumbersVisible) ?? true
        bookmarkMarginVisible = try values.decodeIfPresent(Bool.self, forKey: .bookmarkMarginVisible) ?? true
        highlightCurrentLine = try values.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine) ?? true
        caretWidth = try values.decodeIfPresent(Int.self, forKey: .caretWidth) ?? 1
        caretBlinkPeriod = try values.decodeIfPresent(Int.self, forKey: .caretBlinkPeriod) ?? 500
        scrollBeyondLastLine = try values.decodeIfPresent(Bool.self, forKey: .scrollBeyondLastLine) ?? false
        wrapIndentMode = try values.decodeIfPresent(Int.self, forKey: .wrapIndentMode) ?? 0
    }
}
