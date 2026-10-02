import AppKit
import DuckpadInfrastructure
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
struct LanguageHighlightingTests {
    @Test @MainActor
    func everyRegisteredLanguageHasVisibleSyntaxColorsAcrossPalettes() throws {
        let definitions = try LanguageManifestLoader().loadBundled().definitions
        #expect(Set(definitions.map { $0.id.rawValue }) == Set(Self.samples.keys))
        let (window, view) = hostedView()
        defer { window.close() }
        for definition in definitions {
            let id = definition.id.rawValue
            let source = try #require(Self.samples[id])
            let bytes = Data(source.utf8)
            try view.loadUTF8(bytes, revision: 7)
            #expect(view.applyLexerNamed(definition.lexerName, keywords: definition.keywordLists,
                tabWidth: 4, useTabs: false, folding: false, braceMatching: false,
                maximumStyleBytes: 1_000_000))
            let styles = Set(bytes.indices.map { view.style(atUTF8Position: UInt($0)) })
            var visibleColorCounts: [Int] = []
            for palette: DPScintillaPalette in [.light, .dark, .highContrastLight, .highContrastDark] {
                view.apply(palette)
                let foreground = view.foregroundColor(forStyle: 0)
                let colors = Set(styles.map { view.foregroundColor(forStyle: $0) })
                visibleColorCounts.append(colors.subtracting([foreground]).count)
                if let directory = ProcessInfo.processInfo.environment["DUCKPAD_HIGHLIGHTING_SNAPSHOTS"] {
                    window.appearance = NSAppearance(named: palette == .dark || palette == .highContrastDark ? .darkAqua : .aqua)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let destination = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("\(id)-\(palette.rawValue).png"))
                }
                if definition.lexerName == "null" {
                    #expect(colors == [foreground], "\(id) remains plain text")
                } else {
                    #expect(colors.subtracting([foreground]).count >= 1,
                        "\(id) has colored syntax in palette \(palette.rawValue); styles \(styles)")
                }
            }
            if ProcessInfo.processInfo.environment["DUCKPAD_HIGHLIGHTING_SNAPSHOTS"] != nil {
                print("HIGHLIGHTING_AUDIT\t\(id)\t\(definition.lexerName)\t\(visibleColorCounts.map(String.init).joined(separator: ","))")
            }
            #expect(view.contentUTF8 == bytes)
            #expect(!view.canUndo)
        }
    }

    @Test @MainActor
    func keywordCompleteLanguagesRecognizeTheirReservedTokens() throws {
        let definitions = try LanguageManifestLoader().loadBundled().definitions
        let (window, view) = hostedView()
        defer { window.close() }
        for definition in definitions where definition.supportTier == .keywordComplete {
            let id = definition.id.rawValue
            let source = try #require(Self.samples[id])
            let (token, expectedStyle) = try #require(Self.keywords[id])
            try view.loadUTF8(Data(source.utf8), revision: 0)
            #expect(view.applyLexerNamed(definition.lexerName, keywords: definition.keywordLists,
                tabWidth: 4, useTabs: false, folding: false, braceMatching: false,
                maximumStyleBytes: 1_000_000))
            let range = try #require(source.range(of: token))
            let offset = source[..<range.lowerBound].utf8.count
            #expect(view.style(atUTF8Position: UInt(offset)) == expectedStyle,
                "\(id) styles \(token) as a recognized keyword")
            for palette: DPScintillaPalette in [.light, .dark, .highContrastLight, .highContrastDark] {
                view.apply(palette)
                #expect(view.foregroundColor(forStyle: expectedStyle) != view.foregroundColor(forStyle: 0),
                    "\(id) keyword color is visible in palette \(palette.rawValue)")
            }
        }
    }

    @Test @MainActor
    func jsonKeysValuesNumbersAndLiteralsUseDistinctColorsAndResetForPlainText() throws {
        let json = try #require(try LanguageManifestLoader().loadBundled().definitions.first { $0.id.rawValue == "json" })
        let source = try #require(Self.samples["json"])
        let (window, view) = hostedView()
        defer { window.close() }
        try view.loadUTF8(Data(source.utf8), revision: 0)
        #expect(view.applyLexerNamed(json.lexerName, keywords: json.keywordLists,
            tabWidth: 4, useTabs: false, folding: false, braceMatching: false,
            maximumStyleBytes: 1_000_000))
        for (token, style) in [("name", 4), ("한글", 2), ("42", 1), ("true", 11), ("null", 11)] {
            let range = try #require(source.range(of: token))
            #expect(view.style(atUTF8Position: UInt(source[..<range.lowerBound].utf8.count)) == style)
        }
        for palette: DPScintillaPalette in [.light, .dark, .highContrastLight, .highContrastDark] {
            view.apply(palette)
            let colors = Set([0, 1, 2, 4, 11].map { view.foregroundColor(forStyle: $0) })
            #expect(colors.count == 5, "JSON token colors differ in palette \(palette.rawValue)")
        }
        #expect(view.applyLexerNamed("null", keywords: [], tabWidth: 4, useTabs: false,
            folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        #expect(view.foregroundColor(forStyle: 4) == view.foregroundColor(forStyle: 0))
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(!view.canUndo)
    }

    @Test @MainActor
    func binarySelectorsAndOracleQuotedStringsUseTheirActualTokenRoles() throws {
        let (window, view) = hostedView()
        defer { window.close() }
        for (lexer, source, token, style, equivalentStyle) in [
            ("smalltalk", "n := 1 + 2.\n", "+", 5, 14), // Binary selector and assignment operator.
            ("sql", "SELECT q'[한글]', 'Duck';\n", "한글", 24, 7), // Oracle q-string and ordinary single-quoted string.
        ] {
            try view.loadUTF8(Data(source.utf8), revision: 0)
            #expect(view.applyLexerNamed(lexer, keywords: [], tabWidth: 4, useTabs: false,
                folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
            let range = try #require(source.range(of: token))
            #expect(view.style(atUTF8Position: UInt(source[..<range.lowerBound].utf8.count)) == style)
            for palette: DPScintillaPalette in [.light, .dark, .highContrastLight, .highContrastDark] {
                view.apply(palette)
                #expect(view.foregroundColor(forStyle: style) == view.foregroundColor(forStyle: equivalentStyle))
                #expect(view.foregroundColor(forStyle: style) != view.foregroundColor(forStyle: 0))
            }
        }
    }

    @MainActor
    private func hostedView() -> (NSWindow, DPScintillaEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private static let samples: [String: String] = [
        "text": "plain text 한글🦆",
        "csv": "name,count\nDuck,42\n",
        "c": "int n = 42; const char *s = \"한글\"; // comment\n",
        "cpp": "class Duck { int n = 42; }; // comment\nconst char *s = \"한글\";\n",
        "objc": "@interface Duck\n@end\nint n = 42; NSString *s = @\"한글\"; // comment\n",
        "csharp": "class Duck { string s = \"한글\"; int n = 42; } // comment\n",
        "java": "class Duck { String s = \"한글\"; int n = 42; } // comment\n",
        "kotlin": "fun duck() { val s = \"한글\"; val n = 42 } // comment\n",
        "javascript": "function duck() { return \"한글\"; } const n = 42; // comment\n",
        "typescript": "interface Duck { n: number; } const s = \"한글\"; const n = 42; // comment\n",
        "css": ".duck:hover { display: block; width: 42px; } /* comment */\n",
        "scss": "$width: 42px; .duck { width: $width; content: \"한글\"; } /* comment */\n",
        "html": "<div title=\"한글\">Duck</div><!-- comment -->\n",
        "php": "<?php function duck() { return \"한글\"; } $n = 42; // comment\n",
        "xml": "<duck title=\"한글\">42</duck><!-- comment -->\n",
        "markdown": "# Duck\n\n**bold** and `한글`\n",
        "asciidoc": "= Duck\n\n*bold* and `한글`\n// comment\n",
        "latex": "\\section{Duck}\n% comment\n$42$\n",
        "yaml": "name: \"한글\"\ncount: 42\nenabled: true\n# comment\n",
        "json": "{\n    \"name\": \"한글🦆\",\n    \"count\": 42,\n    \"enabled\": true,\n    \"empty\": null\n}\n",
        "toml": "[duck]\nname = \"한글\"\ncount = 42\n# comment\n",
        "ini": "[duck]\nname=한글\n; comment\n",
        "sql": "SELECT '한글', 42; -- comment\n",
        "mysql": "SELECT '한글', 42; -- comment\n",
        "python": "def duck():\n    return \"한글\" # comment\ncount = 42\n",
        "ruby": "def duck\n  \"한글\" # comment\nend\ncount = 42\n",
        "perl": "my $duck = \"한글\"; # comment\nmy $n = 42;\n",
        "lua": "local duck = \"한글\" -- comment\nlocal n = 42\n",
        "bash": "if true; then echo \"한글\"; fi # comment\ncount=42\n",
        "powershell": "$duck = \"한글\" # comment\n$n = 42\n",
        "tcl": "set duck \"한글\"\n# comment\nset n 42\n",
        "r": "duck <- \"한글\" # comment\nn <- 42\n",
        "julia": "duck = \"한글\" # comment\nn = 42\n",
        "matlab": "duck = '한글'; % comment\nn = 42;\n",
        "octave": "duck = '한글'; % comment\nn = 42;\n",
        "fortran": "program duck\n! comment\nprint *, '한글', 42\nend program\n",
        "fortran77": "      PROGRAM DUCK\nC comment\n      PRINT *, '한글', 42\n      END\n",
        "rust": "fn duck() { let s = \"한글\"; let n = 42; } // comment\n",
        "swift": "func duck() { let s = \"한글\"; let n = 42 } // comment\n",
        "go": "func duck() { s := \"한글\"; n := 42 } // comment\n",
        "zig": "const duck = \"한글\"; // comment\nconst n = 42;\n",
        "d": "string duck = \"한글\"; // comment\nint n = 42;\n",
        "asm": "mov eax, 42 ; comment\ndb \"duck\"\n",
        "cmake": "# comment\nset(DUCK \"한글\")\nset(COUNT 42)\n",
        "make": "# comment\nDUCK = 42\nall:\n\techo \"한글\"\n",
        "dockerfile": "FROM alpine\n# comment\nRUN echo \"한글\"\n",
        "diff": "--- old\n+++ new\n@@ -1 +1 @@\n-old\n+한글\n",
        "gitcommit": "# comment\nAdd 한글 support\n",
        "coffee": "duck = \"한글\" # comment\nn = 42\n",
        "dart": "var duck = \"한글\"; // comment\nvar n = 42;\n",
        "fsharp": "let duck = \"한글\" // comment\nlet n = 42\n",
        "ocaml": "let duck = \"한글\" (* comment *)\nlet n = 42\n",
        "haskell": "duck = \"한글\" -- comment\nn = 42\n",
        "lisp": "(setq duck \"한글\") ; comment\n(setq n 42)\n",
        "erlang": "duck() -> \"한글\". % comment\nn() -> 42.\n",
        "ada": "-- comment\nDuck : String := \"한글\";\nN : Integer := 42;\n",
        "pascal": "var duck: string; { comment }\nbegin duck := '한글'; n := 42; end;\n",
        "vb": "Dim duck As String = \"한글\" ' comment\nDim n = 42\n",
        "cobol": "       *> comment\n       DISPLAY \"한글\".\n       MOVE 42 TO N.\n",
        "nim": "let duck = \"한글\" # comment\nlet n = 42\n",
        "nix": "{ duck = \"한글\"; n = 42; } # comment\n",
        "batch": "@echo off\nREM comment\nset DUCK=42\necho \"%DUCK%\"\n",
        "autoit": "Local $duck = \"한글\" ; comment\nLocal $n = 42\n",
        "inno": "; comment\n[Setup]\nAppName=Duck\nAppVersion=42\n",
        "nsis": "; comment\nName \"한글\"\nVar count\n",
        "verilog": "// comment\nmodule duck; wire [7:0] n = 42; initial $display(\"한글\"); endmodule\n",
        "vhdl": "-- comment\nconstant duck : string := \"한글\";\nconstant n : integer := 42;\n",
        "graphql": "{ duck(name: \"한글\", count: 42) }\n",
        "protobuf": "syntax = \"proto3\"; // comment\nmessage Duck { string name = 42; }\n",
        "po": "# comment\nmsgid \"Duck\"\nmsgstr \"한글\"\n",
        "registry": "Windows Registry Editor Version 5.00\n; comment\n[HKEY_CURRENT_USER\\Duck]\n\"Name\"=\"한글\"\n",
        "rebol": "REBOL [Title: \"한글\"]\n; comment\nn: 42\n",
        "smalltalk": "\"comment\"\nduck := '한글'.\nn := 42.\n",
        "stata": "// comment\ndisplay \"한글\"\nlocal n = 42\n",
        "sas": "/* comment */\nx = \"한글\";\nn = 42;\n",
        "raku": "my $duck = \"한글\"; # comment\nmy $n = 42;\n",
        "forth": "\\ comment\n: square dup * ;\n42 .\n",
        "tads3": "/* comment */\nfunction duck() { \"한글\"; return 42; }\n",
    ]

    private static let keywords: [String: (String, Int)] = [
        "c": ("int", 5),
        "cpp": ("class", 5),
        "objc": ("interface", 5),
        "csharp": ("class", 5),
        "java": ("class", 5),
        "kotlin": ("fun", 5),
        "javascript": ("function", 5),
        "typescript": ("interface", 5),
        "css": ("display", 6),
        "html": ("div", 1),
        "php": ("return", 121),
        "yaml": ("true", 3),
        "json": ("true", 11),
        "sql": ("SELECT", 5),
        "python": ("def", 5),
        "ruby": ("def", 5),
        "bash": ("if", 4),
        "rust": ("fn", 6),
        "swift": ("func", 5),
        "go": ("func", 5),
    ]
}
