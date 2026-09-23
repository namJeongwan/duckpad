import Foundation

/// Render a selected Markdown fragment without changing its plain-text payload.
@MainActor
public protocol MarkdownClipboardRendering {
    func html(for source: String) -> Data?
}
