import Foundation

enum MarkdownPreviewRenderer {
    static func isAllowedLink(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    static func document(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: duckpad-preview:; script-src duckpad-preview:; font-src duckpad-preview:; style-src 'unsafe-inline' duckpad-preview:; base-uri 'none'; form-action 'none'">
        <link rel="stylesheet" href="duckpad-preview://assets/katex.css">
        <link rel="stylesheet" href="duckpad-preview://assets/highlight.css">
        <script src="duckpad-preview://assets/preview.js"></script>
        <style>
        :root { color-scheme: light dark; font: 15px -apple-system, sans-serif; }
        body { margin: 24px; line-height: 1.6; overflow-wrap: anywhere; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.3; margin: 1.3em 0 .5em; }
        h1,h2 { border-bottom: 1px solid #8885; padding-bottom: .25em; }
        a { color: #0065b3; }
        pre,code { font: .9em ui-monospace, monospace; background: #8882; border-radius: 4px; }
        code { padding: .1em .3em; } pre { padding: 12px; overflow-x: auto; } pre code { padding: 0; background: transparent; }
        blockquote { border-left: 3px solid #8888; padding-left: 1em; margin-left: 0; color: #888; }
        table { border-collapse: collapse; max-width: 100%; } td,th { border: 1px solid #8886; padding: 6px 12px; }
        tr.header { font-weight: bold; background: #8882; } img { max-width: 100%; height: auto; }
        .mermaid-diagram svg { max-width: 100%; height: auto; }
        @media (prefers-color-scheme: dark) {
            a { color: #6bb7ff; }
            .hljs-keyword,.hljs-selector-tag { color: #ff7b72; }
            .hljs-string,.hljs-regexp { color: #a5d6ff; }
            .hljs-number,.hljs-literal,.hljs-built_in { color: #79c0ff; }
            .hljs-title,.hljs-title.function_,.hljs-title.class_,.hljs-type { color: #d2a8ff; }
            .hljs-comment { color: #8b949e; }
        }
        hr { border: 0; border-top: 1px solid #8886; } li p { margin: .3em 0; }
        </style></head><body><main id="content">\(body)</main></body></html>
        """
    }

}
