import AppKit
import DuckpadApplication

/// Flat workspace surfaces, inspired by Zed's One Light and One Dark themes.
enum WorkspaceColors {
    static let editor = color(\.editor)
    static let panel = color(\.panel)
    static let chrome = color(\.chrome)
    static let border = color(\.border)
    static let selection = color(\.selection)

    private static func color(_ role: KeyPath<EditorThemeColors, Int>) -> NSColor {
        NSColor(name: nil) { appearance in
            let palette: EditorThemePalette = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            let value = palette.colors[keyPath: role]
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}
