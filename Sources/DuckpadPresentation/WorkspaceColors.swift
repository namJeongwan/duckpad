import AppKit

/// Flat workspace surfaces, inspired by Zed's One Light and One Dark themes.
enum WorkspaceColors {
    static let editor = color(light: 0xFAFAFA, dark: 0x282C33)
    static let panel = color(light: 0xEBEBEC, dark: 0x2F343E)
    static let chrome = color(light: 0xDCDCDD, dark: 0x3B414D)
    static let border = color(light: 0xDFDFE0, dark: 0x363C46)
    static let selection = color(light: 0xCACACA, dark: 0x454A56)

    private static func color(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}
