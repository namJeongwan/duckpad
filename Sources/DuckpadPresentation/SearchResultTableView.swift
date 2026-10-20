import AppKit

@MainActor
final class SearchResultTableView: NSTableView {
    var onActivate: (() -> Void)?
    var onDismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) { onActivate?() }
        else if event.keyCode == 53 { onDismiss?() }
        else { super.keyDown(with: event) }
    }
}
