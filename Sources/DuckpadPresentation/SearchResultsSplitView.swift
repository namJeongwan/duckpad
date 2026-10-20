import AppKit

/// Uses the same explicit arrangement as the terminal workspace split.
@MainActor
final class SearchResultsSplitView: NSSplitView, NSSplitViewDelegate {
    private var preferredFraction: CGFloat = 0.4
    private var arranging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = false; dividerStyle = .thin; delegate = self
    }
    required init?(coder: NSCoder) { nil }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { arrange() }
    override func layout() { super.layout(); arrange() }

    private func arrange() {
        guard !arranging, arrangedSubviews.count == 2 else { return }
        arranging = true
        defer { arranging = false }
        let available = max(0, bounds.height - dividerThickness)
        let top = available >= 240 ? min(available - 140, max(80, available * preferredFraction)) : available / 2
        arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        arrangedSubviews[1].frame = NSRect(x: 0, y: top + dividerThickness, width: bounds.width, height: max(0, available - top))
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(80, max(0, bounds.height / 2))
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(bounds.height / 2, bounds.height - dividerThickness - 140)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arranging, arrangedSubviews.count == 2, bounds.height > dividerThickness,
              NSApp.currentEvent?.type == .leftMouseDragged else { return }
        preferredFraction = arrangedSubviews[0].frame.height / (bounds.height - dividerThickness)
    }
}
