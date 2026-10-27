/// Shared RGB colors for workspace chrome and editor surfaces.
public struct EditorThemeColors: Equatable, Sendable {
    public let editor: Int
    public let panel: Int
    public let chrome: Int
    public let border: Int
    public let selection: Int
    public let foreground: Int
    public let muted: Int
    public let comment: Int
    public let number: Int
    public let keyword: Int
    public let string: Int
    public let operation: Int

    fileprivate init(dark: Bool, highContrast: Bool) {
        editor = dark ? 0x282C33 : 0xFAFAFA
        panel = dark ? 0x2F343E : 0xEBEBEC
        chrome = dark ? 0x3B414D : 0xDCDCDD
        foreground = highContrast ? (dark ? 0xFFFFFF : 0x000000) : (dark ? 0xE8E8E8 : 0x202020)
        border = highContrast ? (dark ? 0xAAB2BF : 0x656B78) : (dark ? 0x363C46 : 0xDFDFE0)
        selection = dark ? 0x454A56 : 0xCACACA
        muted = highContrast ? (dark ? 0xCDD2DB : 0x484D57) : (dark ? 0xA3ABB9 : 0x656B78)
        // RGB counterparts of the native Scintilla syntax roles.
        comment = dark ? 0x7FD47F : 0x327A39
        number = dark ? 0xF8A0D7 : 0x8E2F7C
        keyword = dark ? 0x6BB3FF : 0x003BA2
        string = dark ? 0xE8D67D : 0x7A6A17
        operation = dark ? 0xFFC7A9 : 0x9B4F20
    }
}

public extension EditorThemePalette {
    var colors: EditorThemeColors {
        switch self {
        case .light: .init(dark: false, highContrast: false)
        case .dark: .init(dark: true, highContrast: false)
        case .highContrastLight: .init(dark: false, highContrast: true)
        case .highContrastDark: .init(dark: true, highContrast: true)
        }
    }
}
