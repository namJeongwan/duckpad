import AppKit

/// Prints a snapshot, including unsaved edits, without touching the live editor.
@MainActor
final class DocumentPrintController {
    static func makeView(text: String, width: CGFloat) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.isRichText = false
        view.isEditable = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: width, height: 1)
        view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        view.textColor = .black
        view.backgroundColor = .white
        view.string = text
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
            let height = view.layoutManager?.usedRect(for: container).height ?? 1
            view.setFrameSize(NSSize(width: width, height: max(1, ceil(height))))
        }
        return view
    }

    static func print(text: String, title: String, window: NSWindow) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = max(72, info.paperSize.width - info.leftMargin - info.rightMargin)
        let operation = NSPrintOperation(view: makeView(text: text, width: width), printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
