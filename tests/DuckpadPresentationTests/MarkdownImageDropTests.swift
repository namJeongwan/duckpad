import Foundation
import AppKit
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

struct MarkdownImageDropTests {
    @Test @MainActor func nativePromptReturnsRememberedActionAndCancelDiscardsIt() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for cancel in [false, true] {
            let task = Task { await MarkdownImageDrop.ask(in: window) }
            for _ in 0..<100 {
                if window.attachedSheet != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let sheet = try #require(window.attachedSheet?.contentView)
            let buttons = descendants(sheet).compactMap { $0 as? NSButton }
            let checkbox = try #require(buttons.first { $0.title == L10n.text("Don’t ask again; use this action") })
            checkbox.state = .on
            let action = try #require(buttons.first { $0.title == L10n.text(cancel ? "Cancel" : "Insert into Markdown") })
            action.performClick(nil)
            let result = await task.value
            if cancel { #expect(result == nil) }
            else { #expect(result?.action == .insert); #expect(result?.remember == true) }
        }
    }

    @Test func pathsEscapeMarkdownSyntaxAndUseDocumentRelativeLocations() {
        let doc = URL(fileURLWithPath: "/docs/project/note.md")
        let image = URL(fileURLWithPath: "/docs/pictures/a[1] (#).png")
        #expect(MarkdownImageDrop.markup(for: [image], documentURL: doc) == "![a\\[1\\] (#)](<../pictures/a%5B1%5D%20%28%23%29.png>)")
        #expect(MarkdownImageDrop.markup(for: [URL(fileURLWithPath: "/tmp/image.png")], documentURL: nil) == "![image](<file:///tmp/image.png>)")
        #expect(MarkdownImageDrop.containsOnlyImages([image, URL(fileURLWithPath: "/tmp/x.svg")]))
        #expect(!MarkdownImageDrop.containsOnlyImages([image, doc]))
        #expect(!MarkdownImageDrop.containsOnlyImages([]))
    }

    @Test func legacySettingsAskAndRememberedActionRoundTrips() throws {
        let data = Data(#"{"schemaVersion":1,"appearanceMode":"system","defaultWordWrapEnabled":true,"defaultWrapMarkerVisible":false}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).markdownImageDropAction == 0)
        for action in [0, 1, 2] {
            let settings = AppSettings(markdownImageDropAction: action)
            #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
        #expect(LocalizationCatalog(language: .korean).text("Open in New Tab") == "새 탭에서 열기")
    }
}
