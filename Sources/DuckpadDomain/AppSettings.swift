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

    public var editorFontName: String
    public var editorFontSize: Int
    public var liveFileReloadEnabled: Bool

    public var menuBarVisible: Bool
    public var statusBarVisible: Bool
    public var multilineTabsEnabled: Bool
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

    public var overrideLanguageIndentation: Bool
    public var indentationWidth: Int
    public var indentationUsesTabs: Bool
    public var indentationGuidesVisible: Bool
    public var virtualSpaceEnabled: Bool
    public var edgeLineVisible: Bool
    public var edgeColumn: Int

    public var recentFileLimit: Int
    public var recentFilePathMode: Int
    public var fileDialogFollowsDocument: Bool

    public var fillFindWithSelection: Bool
    public var findSelectionMaximumCharacters: Int
    public var monospacedFindFields: Bool

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        appearanceMode: AppAppearanceMode = .system,
        defaultWordWrapEnabled: Bool = true,
        defaultWrapMarkerVisible: Bool = false,
        editorFontName: String = "Menlo",
        editorFontSize: Int = 13,
        liveFileReloadEnabled: Bool = true,
        menuBarVisible: Bool = true,
        statusBarVisible: Bool = true,
        multilineTabsEnabled: Bool = true,
        tabDragEnabled: Bool = true,
        showTabCloseButton: Bool = true,
        showInactiveTabButtons: Bool = false,
        lineNumbersVisible: Bool = true,
        bookmarkMarginVisible: Bool = true,
        highlightCurrentLine: Bool = true,
        caretWidth: Int = 1,
        caretBlinkPeriod: Int = 500,
        scrollBeyondLastLine: Bool = false,
        wrapIndentMode: Int = 0,
        overrideLanguageIndentation: Bool = false,
        indentationWidth: Int = 4,
        indentationUsesTabs: Bool = false,
        indentationGuidesVisible: Bool = true,
        virtualSpaceEnabled: Bool = false,
        edgeLineVisible: Bool = false,
        edgeColumn: Int = 80,
        recentFileLimit: Int = 10,
        recentFilePathMode: Int = 2,
        fileDialogFollowsDocument: Bool = false,
        fillFindWithSelection: Bool = true,
        findSelectionMaximumCharacters: Int = 1024,
        monospacedFindFields: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.appearanceMode = appearanceMode
        self.defaultWordWrapEnabled = defaultWordWrapEnabled
        self.defaultWrapMarkerVisible = defaultWrapMarkerVisible
        self.editorFontName = editorFontName
        self.editorFontSize = editorFontSize
        self.liveFileReloadEnabled = liveFileReloadEnabled
        self.menuBarVisible = menuBarVisible
        self.statusBarVisible = statusBarVisible
        self.multilineTabsEnabled = multilineTabsEnabled
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
        self.overrideLanguageIndentation = overrideLanguageIndentation
        self.indentationWidth = indentationWidth
        self.indentationUsesTabs = indentationUsesTabs
        self.indentationGuidesVisible = indentationGuidesVisible
        self.virtualSpaceEnabled = virtualSpaceEnabled
        self.edgeLineVisible = edgeLineVisible
        self.edgeColumn = edgeColumn
        self.recentFileLimit = recentFileLimit
        self.recentFilePathMode = recentFilePathMode
        self.fileDialogFollowsDocument = fileDialogFollowsDocument
        self.fillFindWithSelection = fillFindWithSelection
        self.findSelectionMaximumCharacters = findSelectionMaximumCharacters
        self.monospacedFindFields = monospacedFindFields
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        appearanceMode = try values.decode(AppAppearanceMode.self, forKey: .appearanceMode)
        defaultWordWrapEnabled = try values.decode(Bool.self, forKey: .defaultWordWrapEnabled)
        defaultWrapMarkerVisible = try values.decode(Bool.self, forKey: .defaultWrapMarkerVisible)
        editorFontName = try values.decodeIfPresent(String.self, forKey: .editorFontName) ?? "Menlo"
        editorFontSize = try values.decodeIfPresent(Int.self, forKey: .editorFontSize) ?? 13
        liveFileReloadEnabled = try values.decodeIfPresent(Bool.self, forKey: .liveFileReloadEnabled) ?? true
        menuBarVisible = try values.decodeIfPresent(Bool.self, forKey: .menuBarVisible) ?? true
        statusBarVisible = try values.decodeIfPresent(Bool.self, forKey: .statusBarVisible) ?? true
        multilineTabsEnabled = try values.decodeIfPresent(Bool.self, forKey: .multilineTabsEnabled) ?? true
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
        overrideLanguageIndentation = try values.decodeIfPresent(Bool.self, forKey: .overrideLanguageIndentation) ?? false
        indentationWidth = try values.decodeIfPresent(Int.self, forKey: .indentationWidth) ?? 4
        indentationUsesTabs = try values.decodeIfPresent(Bool.self, forKey: .indentationUsesTabs) ?? false
        indentationGuidesVisible = try values.decodeIfPresent(Bool.self, forKey: .indentationGuidesVisible) ?? true
        virtualSpaceEnabled = try values.decodeIfPresent(Bool.self, forKey: .virtualSpaceEnabled) ?? false
        edgeLineVisible = try values.decodeIfPresent(Bool.self, forKey: .edgeLineVisible) ?? false
        edgeColumn = try values.decodeIfPresent(Int.self, forKey: .edgeColumn) ?? 80
        recentFileLimit = try values.decodeIfPresent(Int.self, forKey: .recentFileLimit) ?? 10
        recentFilePathMode = try values.decodeIfPresent(Int.self, forKey: .recentFilePathMode) ?? 2
        fileDialogFollowsDocument = try values.decodeIfPresent(Bool.self, forKey: .fileDialogFollowsDocument) ?? false
        fillFindWithSelection = try values.decodeIfPresent(Bool.self, forKey: .fillFindWithSelection) ?? true
        findSelectionMaximumCharacters = try values.decodeIfPresent(Int.self, forKey: .findSelectionMaximumCharacters) ?? 1024
        monospacedFindFields = try values.decodeIfPresent(Bool.self, forKey: .monospacedFindFields) ?? false
    }
}
