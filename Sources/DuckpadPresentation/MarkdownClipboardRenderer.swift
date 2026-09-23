import Foundation
import JavaScriptCore
import DuckpadApplication

/// Uses the bundled Markdown parser without a WebView, network or file access.
@MainActor
public final class MarkdownClipboardRenderer: MarkdownClipboardRendering {
    public static let maximumSourceBytes = 262_144
    private lazy var context: JSContext? = {
        guard let url = DuckpadPresentationResources.bundle?.url(
            forResource: "clipboard", withExtension: "js", subdirectory: "MarkdownPreview"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        guard context.exception == nil else { return nil }
        return context
    }()

    public init() {}

    public func html(for source: String) -> Data? {
        guard !source.isEmpty, source.utf8.count <= Self.maximumSourceBytes,
              let context else { return nil }
        context.exception = nil
        // Pass data as an argument, never interpolate selected text into JavaScript.
        guard let value = context.objectForKeyedSubscript("duckpadClipboardHTML")?.call(withArguments: [source]),
              context.exception == nil, value.isString,
              let html = value.toString(), html.utf8.count <= 8 * 1_048_576 else { return nil }
        return Data(html.utf8)
    }
}
