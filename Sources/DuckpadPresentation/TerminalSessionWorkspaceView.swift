import AppKit
import DuckpadApplication

indirect enum TerminalPaneLayout: Equatable {
    case surface(UUID)
    case split(vertical: Bool, TerminalPaneLayout, TerminalPaneLayout)

    var ids: [UUID] {
        switch self {
        case .surface(let id): return [id]
        case .split(_, let first, let second): return first.ids + second.ids
        }
    }
    func replacing(_ id: UUID, with replacement: TerminalPaneLayout?) -> TerminalPaneLayout? {
        switch self {
        case .surface(let current): return current == id ? replacement : self
        case .split(let vertical, let first, let second):
            let a = first.replacing(id, with: replacement), b = second.replacing(id, with: replacement)
            if let a, let b { return .split(vertical: vertical, a, b) }
            return a ?? b
        }
    }
}

@MainActor
final class TerminalSessionWorkspaceView: NSView {
    struct Snapshot {
        let layout: TerminalPaneLayout
        let selectedID: UUID
    }
    private let factory: (ShellLaunchConfiguration) -> TerminalSurfaceView?
    private let configuration: ShellLaunchConfiguration
    private var surfaces: [UUID: TerminalSurfaceView] = [:]
    private(set) var paneLayout: TerminalPaneLayout?
    private(set) var selectedID: UUID?
    private var zoomed = false
    var onAction: ((UUID, TerminalAction) -> Void)?
    var onExit: ((UUID) -> Void)?

    init(configuration: ShellLaunchConfiguration, factory: @escaping (ShellLaunchConfiguration) -> TerminalSurfaceView?) {
        self.configuration = configuration
        self.factory = factory
        super.init(frame: .zero)
        if let id = makeSurface(configuration) {
            paneLayout = .surface(id); selectedID = id
            rebuild()
        }
    }
    required init?(coder: NSCoder) { nil }
    var selectedSurface: TerminalSurfaceView? { selectedID.flatMap { surfaces[$0] } }
    var needsCloseConfirmation: Bool { paneLayout?.ids.contains { surfaces[$0]?.needsCloseConfirmation == true } ?? false }
    var snapshot: Snapshot? {
        guard let paneLayout, let selectedID else { return nil }
        return Snapshot(layout: paneLayout, selectedID: selectedID)
    }
    func surface(_ id: UUID) -> TerminalSurfaceView? { surfaces[id] }
    func focus() { if let selectedSurface { window?.makeFirstResponder(selectedSurface) } }
    func restore(_ snapshot: Snapshot) {
        paneLayout = snapshot.layout; selectedID = snapshot.selectedID; zoomed = false
        rebuild()
    }
    func split(_ direction: TerminalDirection) {
        guard let selectedID, let root = paneLayout, root.ids.count < 16 else { NSSound.beep(); return }
        let config = ShellLaunchConfiguration(workingDirectory: selectedSurface?.workingDirectory ?? configuration.workingDirectory)
        guard let id = makeSurface(config) else { return }
        let original = TerminalPaneLayout.surface(selectedID), added = TerminalPaneLayout.surface(id)
        let before = direction == .left || direction == .up
        paneLayout = root.replacing(selectedID, with: .split(vertical: direction == .left || direction == .right,
                                                           before ? added : original, before ? original : added))
        self.selectedID = id; zoomed = false
        rebuild(); focus()
    }
    @discardableResult func remove(_ id: UUID) -> Bool {
        guard let root = paneLayout, root.ids.contains(id) else { return false }
        paneLayout = root.replacing(id, with: nil)
        if selectedID == id { selectedID = paneLayout?.ids.first }
        zoomed = false
        rebuild(); focus()
        return paneLayout == nil
    }
    func focus(_ direction: TerminalDirection) {
        guard let selectedID, let ids = paneLayout?.ids, let index = ids.firstIndex(of: selectedID) else { return }
        // Cycling must restore attached panes too, not only directional moves.
        if zoomed { zoomed = false; rebuild(); layoutSubtreeIfNeeded() }
        let target: UUID?
        if direction == .next || direction == .previous {
            target = ids[(index + (direction == .next ? 1 : ids.count - 1)) % ids.count]
        } else if let current = surfaces[selectedID] {
            let center = current.convert(NSPoint(x: current.bounds.midX, y: current.bounds.midY), to: self)
            target = ids.filter { $0 != selectedID }.compactMap { id -> (UUID, CGFloat)? in
                guard let view = surfaces[id] else { return nil }
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: self)
                let dx = point.x - center.x, dy = point.y - center.y
                let forward: CGFloat, across: CGFloat
                switch direction {
                case .left: forward = -dx; across = dy
                case .right: forward = dx; across = dy
                case .up: forward = -dy; across = dx
                default: forward = dy; across = dx
                }
                guard forward > 1 else { return nil }
                return (id, forward + abs(across) * 2)
            }.min { $0.1 < $1.1 }?.0
        } else { target = nil }
        if let target { self.selectedID = target; focus() }
    }
    func resize(_ direction: TerminalDirection, amount: Int) {
        guard let selectedSurface else { return }
        if zoomed { zoomed = false; rebuild() }
        let vertical = direction == .left || direction == .right
        var child: NSView = selectedSurface
        while let parent = child.superview, parent !== self {
            if let split = parent as? NSSplitView, split.isVertical == vertical {
                let current = split.arrangedSubviews[0].frame
                let position = vertical ? current.width : current.height
                let extent = vertical ? split.bounds.width : split.bounds.height
                let delta = CGFloat(amount) * (vertical ? 8 : 16) * (direction == .left || direction == .up ? -1 : 1)
                split.setPosition(min(max(40, position + delta), max(40, extent - 40)), ofDividerAt: 0)
                return
            }
            child = parent
        }
    }
    func equalize() { zoomed = false; rebuild(); focus() }
    func toggleZoom() { zoomed.toggle(); rebuild(); focus() }
    func prune(keeping ids: Set<UUID>) {
        let live = Set(paneLayout?.ids ?? []).union(ids)
        for id in Array(surfaces.keys) where !live.contains(id) { surfaces.removeValue(forKey: id)?.shutdown() }
    }
    func shutdown() { surfaces.values.forEach { $0.shutdown() }; surfaces.removeAll() }
    override var isFlipped: Bool { true }

    private func makeSurface(_ configuration: ShellLaunchConfiguration) -> UUID? {
        guard let view = factory(configuration) else { return nil }
        let id = UUID()
        surfaces[id] = view
        view.onFocus = { [weak self] in self?.selectedID = id }
        view.onAction = { [weak self] action in self?.onAction?(id, action) }
        view.onExit = { [weak self] in self?.onExit?(id) }
        return id
    }
    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        guard let root = paneLayout else { return }
        func make(_ node: TerminalPaneLayout) -> NSView {
            switch node {
            case .surface(let id): return surfaces[id] ?? NSView()
            case .split(let vertical, let first, let second):
                let split = TerminalPaneSplitView(frame: bounds)
                split.isVertical = vertical
                split.dividerStyle = .thin
                let children = [make(first), make(second)]
                // A new engine view starts at zero size. Seed both panes before
                // attaching them: AppKit otherwise remembers a collapsed pane
                // when the new view installs its Metal layer on the next turn.
                let available = max(0, (split.isVertical ? bounds.width : bounds.height) - split.dividerThickness)
                let extent = available / 2
                for (index, child) in children.enumerated() {
                    child.removeFromSuperview()
                    child.autoresizingMask = [.width, .height]
                    let offset = CGFloat(index) * (extent + split.dividerThickness)
                    child.frame = split.isVertical
                        ? NSRect(x: offset, y: 0, width: extent, height: bounds.height)
                        : NSRect(x: 0, y: offset, width: bounds.width, height: extent)
                    split.addArrangedSubview(child)
                }
                return split
            }
        }
        let view = zoomed ? (selectedSurface ?? make(root)) : make(root)
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        func equalize(_ view: NSView) {
            guard let split = view as? NSSplitView else { return }
            split.adjustSubviews()
            split.setPosition((split.isVertical ? split.bounds.width : split.bounds.height) / 2, ofDividerAt: 0)
            split.arrangedSubviews.forEach(equalize)
        }
        equalize(view)
    }
}

private final class TerminalPaneSplitView: NSSplitView {
    override var isFlipped: Bool { true }
}
