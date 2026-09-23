import AppKit

/// Extra representations of a bounded selection. Scintilla remains responsible
/// for the original text and its rectangular-selection clipboard metadata.
@MainActor
enum RichClipboardWriter {
    static let maximumTextBytes = 1_048_576
    static let maximumImageBytes = 65_536
    private static let maximumRepresentationBytes = 8 * 1_048_576

    static func addRepresentations(_ text: NSAttributedString, tabWidth: Int, to board: NSPasteboard) {
        // Do not enrich stale or differently shaped native copy output.
        guard text.string.utf8.count <= maximumTextBytes,
              board.string(forType: .string) == text.string,
              let html = html(text, tabWidth: tabWidth) else { return }
        let rtf = try? text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.addTypes([.html], owner: nil)
        board.setData(html, forType: .html)
        if let rtf, rtf.count <= maximumRepresentationBytes {
            board.addTypes([.rtf], owner: nil)
            board.setData(rtf, forType: .rtf)
        }
    }

    static func html(_ text: NSAttributedString, tabWidth: Int) -> Data? {
        guard text.length > 0, text.string.utf8.count <= maximumTextBytes else { return nil }
        let baseFont = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let height = paragraph?.minimumLineHeight ?? 0
        let lineHeight = height > 0 ? "\(height)px" : "normal"
        var result = "<html><head><meta charset=\"utf-8\"></head><body><!--StartFragment--><pre style=\"\(escape(fontCSS(baseFont)));line-height:\(lineHeight);margin:0;white-space:pre-wrap;tab-size:\(max(1, min(tabWidth, 32)));color:#202020;background-color:#ffffff\">"
        let source = text.string as NSString
        var runs = 0
        var exceededLimit = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, stop in
            runs += 1
            guard runs <= 4096 else { exceededLimit = true; stop.pointee = true; return }
            let font = attributes[.font] as? NSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) ?? NSColor.black.usingColorSpace(.sRGB)!
            let hex = String(format: "#%02x%02x%02x", Int(color.redComponent * 255),
                             Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            let css = fontCSS(font) + ";color:\(hex)"
            result += "<span style=\"\(escape(css))\">\(escape(source.substring(with: range)))</span>"
            if result.utf8.count > maximumRepresentationBytes { exceededLimit = true; stop.pointee = true }
        }
        guard !exceededLimit else { return nil }
        result += "</pre><!--EndFragment--></body></html>"
        return result.data(using: .utf8)
    }

    private static func fontCSS(_ font: NSFont) -> String {
        let traits = NSFontManager.shared.traits(of: font)
        // Cocoa screen points correspond to CSS pixels at browser zoom 100%.
        // CSS pt would enlarge the copied text by 96/72. Escape the CSS string
        // here and the enclosing HTML attribute at the call site.
        let family = (font.familyName ?? "monospace")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "font-family:'\(family)',monospace;font-size:\(font.pointSize)px;font-weight:\(traits.contains(.boldFontMask) ? "bold" : "normal");font-style:\(traits.contains(.italicFontMask) ? "italic" : "normal")"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func copyImage(_ text: NSAttributedString, to board: NSPasteboard) -> Bool {
        guard let png = png(text) else { return false }
        board.clearContents()
        return board.setData(png, forType: .png)
    }

    static func png(_ text: NSAttributedString) -> Data? {
        guard text.length > 0, text.string.utf8.count <= maximumImageBytes else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        // Layout is bounded by input size and excludes wrapping at the editor width.
        let container = NSTextContainer(size: NSSize(width: 100_000, height: 100_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = ceil(used.maxX) + 24
        let height = ceil(max(used.maxY, layout.extraLineFragmentRect.maxY)) + 24
        let scale: CGFloat = 2
        guard width > 24, height > 24, width * scale <= 4096, height * scale <= 4096,
              width * height * scale * scale <= 8_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: NSPoint(x: 12, y: 12))
        layout.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: 12, y: 12))
        context.flushGraphics()
        bitmap.size = NSSize(width: width, height: height)
        return bitmap.representation(using: .png, properties: [:])
    }
}
