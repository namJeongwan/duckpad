import AppKit

@MainActor
public protocol TabPathActionHandling: AnyObject {
    func copyFullPath(_ path: String)
    func openContainingFolder(for path: String)
}

@MainActor
final class NativeTabPathActionHandler: TabPathActionHandling {
    func copyFullPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func openContainingFolder(for path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
