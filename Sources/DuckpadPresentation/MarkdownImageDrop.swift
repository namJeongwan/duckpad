import AppKit
import DuckpadLocalization
import UniformTypeIdentifiers

enum MarkdownImageDropAction: Int, Sendable { case ask, insert, open }
struct MarkdownImageDropDecision: Sendable {
    let action: MarkdownImageDropAction
    let remember: Bool
}

enum MarkdownImageDrop {
    static func containsOnlyImages(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { $0.isFileURL && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    static func markup(for urls: [URL], documentURL: URL?) -> String {
        urls.map { url in
            let label = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let destination: String
            if let directory = documentURL?.deletingLastPathComponent().standardizedFileURL {
                let base = directory.pathComponents
                let path = url.standardizedFileURL.pathComponents
                let common = zip(base, path).prefix { $0 == $1 }.count
                let relative = Array(repeating: "..", count: base.count - common) + path.dropFirst(common)
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                destination = relative.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
            } else {
                destination = url.absoluteString
                    .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            }
            return "![\(label)](<\(destination)>)"
        }.joined(separator: "\n")
    }

    @MainActor static func ask(in window: NSWindow) async -> MarkdownImageDropDecision? {
        let alert = NSAlert()
        alert.messageText = L10n.text("How would you like to use these images?")
        alert.addButton(withTitle: L10n.text("Insert into Markdown"))
        alert.addButton(withTitle: L10n.text("Open in New Tab"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.text("Don’t ask again; use this action")
        let response = await alert.beginSheetModal(for: window)
        guard response != .alertThirdButtonReturn else { return nil }
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return nil }
        return .init(action: response == .alertFirstButtonReturn ? .insert : .open,
                     remember: alert.suppressionButton?.state == .on)
    }
}
