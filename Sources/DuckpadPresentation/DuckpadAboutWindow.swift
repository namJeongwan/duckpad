import AppKit

@MainActor
final class DuckpadAboutWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            cancelOperation(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
