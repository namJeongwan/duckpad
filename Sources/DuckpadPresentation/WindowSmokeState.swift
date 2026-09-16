import DuckpadDomain

public struct TabWorkspaceSmokeState: Equatable, Sendable {
    public let tabCount: Int
    public let rowCount: Int
    public let selectedTabIsVisible: Bool
}

public struct SearchPanelSmokeState: Equatable, Sendable {
    public let isVisible: Bool
    public let height: Double
}

public struct LanguageStatusSmokeState: Equatable, Sendable {
    public let text: String
    public let isWarning: Bool
}

public struct FileFormatStatusSmokeState: Equatable, Sendable {
    public let text: String
    public let encoding: TextFileEncoding
    public let byteOrderMark: ByteOrderMark
    public let lineEnding: LineEnding
    public let isEnabled: Bool
}

public struct ExtensionStatusSmokeState: Equatable, Sendable {
    public let text: String
    public let isWarning: Bool
    public let commandCount: Int
}

public struct WorkspaceChromeSmokeState: Equatable, Sendable {
    public let documentCount: Int
    public let bannerHeight: Double
    public let tabStripHeight: Double
    public let statusBarHeight: Double
    public let editorOverlapsStatusBar: Bool
    public let interactionsEnabled: Bool
    public let languageStatusEnabled: Bool
    public let extensionStatusEnabled: Bool
}

public struct WorkspaceSidebarSmokeState: Equatable, Sendable {
    public let isVisible: Bool
    public let rootCount: Int
    public let arrangedPaneCount: Int
}
