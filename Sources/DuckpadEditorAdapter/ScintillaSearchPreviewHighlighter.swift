import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadScintillaBridge

/// Independent, bounded lexer surface. It never shares a live document or undo stack.
@MainActor
public final class ScintillaSearchPreviewHighlighter: SearchPreviewSyntaxHighlighting {
    private let detector: LanguageDetector
    private lazy var lexer = DPScintillaEditorView(frame: .zero)

    public init(registry: LanguageRegistry) { detector = LanguageDetector(registry: registry) }

    public func highlight(_ preview: SearchMatchPreview, filename: String?, languageOverride: LanguageOverride = .automatic) -> SearchMatchPreview {
        let text = Data(preview.text.utf8), prefix = Data(preview.syntaxContextPrefix.utf8)
        guard !text.isEmpty, text.count <= 32 * 1_024, prefix.count <= 64 * 1_024 else { return preview.withSyntax([]) }
        let source = prefix + text
        let language = detector.detect(filename: filename, contentPrefix: preview.languageDetectionPrefix ?? source,
                                       override: languageOverride).languageID
        guard let definition = detector.registry[language], definition.lexerName != "null",
              DPScintillaEditorView.supportsLexerNamed(definition.lexerName) else { return preview.withSyntax([]) }
        do { try lexer.loadUTF8(source, revision: 0) } catch { return preview.withSyntax([]) }
        guard lexer.applyLexerNamed(definition.lexerName, keywords: definition.keywordLists,
            tabWidth: 4, useTabs: false, folding: false, braceMatching: false,
            maximumStyleBytes: 96 * 1_024) else { return preview.withSyntax([]) }

        let styles = (0..<text.count).map { lexer.style(atUTF8Position: UInt(prefix.count + $0)) }
        let used = Set(styles)
        lexer.apply(.light)
        let light = Dictionary(uniqueKeysWithValues: used.map { ($0, Self.rgb(lexer.foregroundColor(forStyle: $0))) })
        lexer.apply(.dark)
        let dark = Dictionary(uniqueKeysWithValues: used.map { ($0, Self.rgb(lexer.foregroundColor(forStyle: $0))) })
        var spans: [SearchPreviewSyntaxSpan] = [], start = 0
        while start < styles.count {
            var end = start + 1
            while end < styles.count, styles[end] == styles[start] { end += 1 }
            let lightColor = light[styles[start]]!, darkColor = dark[styles[start]]!
            if lightColor != EditorThemePalette.light.colors.foreground || darkColor != EditorThemePalette.dark.colors.foreground {
                spans.append(.init(range: .init(location: start, length: end - start),
                                   lightForeground: lightColor, darkForeground: darkColor))
            }
            start = end
        }
        return preview.withSyntax(spans)
    }

    private static func rgb(_ bgr: UInt) -> Int {
        let value = Int(bgr) & 0xFFFFFF
        return ((value & 0xFF) << 16) | (value & 0xFF00) | ((value >> 16) & 0xFF)
    }
}
