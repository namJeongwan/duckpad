import Foundation
import DuckpadApplication

extension TabSnapshot {
    var isMarkdownDocument: Bool {
        ["md", "markdown"].contains(URL(fileURLWithPath: fullPath ?? title).pathExtension.lowercased())
    }
}
