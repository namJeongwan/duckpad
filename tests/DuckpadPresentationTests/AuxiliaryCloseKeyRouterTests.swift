import AppKit
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct AuxiliaryCloseKeyRouterTests {
    private func key(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = .control, repeatKey: Bool = false, characters: String = "w", keyCode: UInt16 = 13) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: keyCode))
    }

    @Test(arguments: ["w", "ㅈ", "\u{17}"])
    func localMonitorUsesControlWWithEnglishAndKoreanInput(characters: String) throws {
        _ = NSApplication.shared
        let dialog = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        dialog.isReleasedWhenClosed = false
        let router = AuxiliaryCloseKeyRouter()
        defer { router.stop(); dialog.close() }
        dialog.makeKeyAndOrderFront(nil)
        #expect(!router.handle(try key(dialog, characters: "x")))
        #expect(dialog.isVisible)
        router.start()
        NSApp.sendEvent(try key(dialog, characters: characters, keyCode: characters == "w" ? 14 : 13))
        #expect(!dialog.isVisible)
    }

    @Test func controlWClosesSheetThenDialogAndRepeatDoesNotCloseParent() throws {
        _ = NSApplication.shared
        let dialog = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        dialog.isReleasedWhenClosed = false
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 150),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let router = AuxiliaryCloseKeyRouter()
        defer { sheet.orderOut(nil); dialog.close() }
        dialog.makeKeyAndOrderFront(nil)
        dialog.beginSheet(sheet, completionHandler: nil)
        #expect(router.handle(try key(sheet)))
        #expect(sheet.sheetParent == nil)
        #expect(dialog.isVisible)
        #expect(router.handle(try key(dialog, repeatKey: true)))
        #expect(dialog.isVisible)
        #expect(!router.handle(try key(dialog, modifiers: .command)))
        #expect(dialog.isVisible)
        #expect(router.handle(try key(dialog)))
        #expect(!dialog.isVisible)
    }

    @Test func controlWCancelsApplicationModalInsteadOfAcceptingIt() throws {
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "Disposable modal test"
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Cancel")
        let router = AuxiliaryCloseKeyRouter()
        let windowNumber = alert.window.windowNumber
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                    timestamp: 0, windowNumber: windowNumber, context: nil,
                    characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
                #expect(router.handle(event))
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        #expect(alert.runModal() == .cancel)
        #expect(!alert.window.isVisible)
    }

    @Test func controlWLeavesEditorWindowAloneWithoutAnAuxiliaryPanel() throws {
        _ = NSApplication.shared
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(!AuxiliaryCloseKeyRouter().handle(try key(window)))
    }
}
