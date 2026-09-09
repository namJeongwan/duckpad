import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
public final class EditorGroupWorkspaceView: NSView {
    public enum Action: Equatable, Sendable {
        case select(TabID, EditorGroupID)
        case reorder(TabID, EditorGroupID, Int)
        case split(TabID, EditorGroupID, EditorGroupSplitOrientation, EditorGroupDropOperation)
        case splitAdjacent(TabID, EditorGroupID, EditorGroupID, EditorGroupDropOverlay.Zone, EditorGroupDropOperation)
        case move(TabID, EditorGroupID, EditorGroupID)
        case clone(TabID, EditorGroupID, EditorGroupID)
        case focus(EditorGroupID)
        case close(TabID, EditorGroupID)
        case context(TabID, EditorGroupID, TabContextAction)
    }

    public let splitView = NSSplitView(frame: .zero)
    public let primaryPane: EditorGroupPaneView
    public let dropOverlay = EditorGroupDropOverlay(frame: .zero)
    public private(set) var secondaryPane: EditorGroupPaneView?
    public var onAction: ((Action) -> Void)?

    private let secondaryEditorHost: NSView
    private let additionalEditorHosts: [EditorGroupID: NSView]
    private var additionalPanes: [EditorGroupID: EditorGroupPaneView] = [:]
    private var renderedTree: EditorGroupLayoutTree?
    private var needsInitialDividerLayout = false
    private var dividerFractions: [(EditorGroupLayoutTree, CGFloat)] = []
    private var dropTarget: EditorGroupID = .primary

    public func pane(for group: EditorGroupID) -> EditorGroupPaneView? {
        switch group {
        case .primary: primaryPane
        case .secondary: secondaryPane
        case .tertiary, .quaternary: additionalPanes[group]
        }
    }
    private let modifierFlagsProvider: () -> NSEvent.ModifierFlags
    private var layoutSnapshot: EditorGroupLayoutSnapshot?
    private let groupPasteboardType = NSPasteboard.PasteboardType(EditorGroupDragPayload.pasteboardType)

    public convenience init(primaryEditorHost: NSView, secondaryEditorHost: NSView, additionalEditorHosts: [EditorGroupID: NSView] = [:]) {
        self.init(
            primaryEditorHost: primaryEditorHost,
            secondaryEditorHost: secondaryEditorHost,
            modifierFlagsProvider: { NSEvent.modifierFlags },
            additionalEditorHosts: additionalEditorHosts
        )
    }

    init(
        primaryEditorHost: NSView,
        secondaryEditorHost: NSView,
        modifierFlagsProvider: @escaping () -> NSEvent.ModifierFlags,
        additionalEditorHosts: [EditorGroupID: NSView] = [:]
    ) {
        self.secondaryEditorHost = secondaryEditorHost
        self.additionalEditorHosts = additionalEditorHosts
        self.modifierFlagsProvider = modifierFlagsProvider
        primaryPane = EditorGroupPaneView(groupID: .primary, editorHostView: primaryEditorHost)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.addArrangedSubview(primaryPane)
        addSubview(splitView)

        dropOverlay.translatesAutoresizingMaskIntoConstraints = true
        addSubview(dropOverlay, positioned: .above, relativeTo: splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([groupPasteboardType])
        bind(primaryPane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func apply(workspace: WorkspaceSnapshot, layout: EditorGroupLayoutSnapshot) {
        layoutSnapshot = layout
        cancelDrop()

        if renderedTree != layout.tree {
            rebuildPanes(for: layout.tree)
            renderedTree = layout.tree
        }

        let tabsByID = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0) })
        for group in layout.visibleGroups {
            pane(for: group)?.apply(
                tabs: layout.tabIDs(in: group).compactMap { tabsByID[$0] },
                selectedTabID: layout.selectedTabID(in: group),
                focused: layout.focusedGroup == group
            )
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()
        if needsInitialDividerLayout, splitView.bounds.width > 0, splitView.bounds.height > 0 {
            needsInitialDividerLayout = false
            balanceDividers(in: splitView, tree: renderedTree ?? .leaf(.primary))
        }
        positionDropOverlay(in: dropTarget)
    }

    private func balanceDividers(in split: NSSplitView, tree: EditorGroupLayoutTree) {
        if case .split(let orientation, let first, let second) = tree, split.arrangedSubviews.count == 2 {
            let length = split.isVertical ? split.bounds.width : split.bounds.height
            let fraction = dividerFractions.first { old, _ in
                guard case .split(let axis, let a, let b) = old, axis == orientation else { return false }
                return Set(first.groups).isSuperset(of: a.groups) && Set(second.groups).isSuperset(of: b.groups)
            }?.1 ?? 0.5
            split.setPosition((length - split.dividerThickness) * fraction, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            for (node, child) in zip([first, second], split.arrangedSubviews) {
                if let nested = child as? NSSplitView { balanceDividers(in: nested, tree: node) }
            }
        } else { split.adjustSubviews() }
    }

    private func positionDropOverlay(in group: EditorGroupID) {
        guard let host = pane(for: group)?.editorHostView else { return }
        dropTarget = group
        dropOverlay.frame = host.convert(host.bounds, to: self)
        dropOverlay.layoutSubtreeIfNeeded()
    }

    public func requestFocus(_ group: EditorGroupID) {
        guard visibleGroups.contains(group) else { return }
        onAction?(.focus(group))
    }

    @discardableResult
    public func applyFocus(layout: EditorGroupLayoutSnapshot) -> Bool {
        guard renderedTree == layout.tree else { return false }
        layoutSnapshot = layout
        for group in layout.visibleGroups { pane(for: group)?.setFocused(layout.focusedGroup == group) }
        return true
    }

    public func validateEdgeDrop(
        payload: EditorGroupDragPayload,
        location: NSPoint,
        optionPressed: Bool
    ) -> EditorGroupDropOperation? {
        guard let layoutSnapshot,
              layoutSnapshot.visibleGroups.count < 4,
              layoutSnapshot.visibleGroups.contains(dropTarget),
              layoutSnapshot.tabIDs(in: payload.sourceGroup).contains(payload.tabID),
              dropOverlay.zone(at: location) != nil else { return nil }
        let operation = EditorGroupDragPayload.dropOperation(optionPressed: optionPressed)
        if operation == .move, layoutSnapshot.tabIDs(in: payload.sourceGroup).count <= 1 {
            return nil
        }
        return operation
    }

    @discardableResult
    public func updateEdgeDrop(
        payload: EditorGroupDragPayload,
        location: NSPoint,
        optionPressed: Bool
    ) -> EditorGroupDropOperation? {
        guard let layoutSnapshot,
              layoutSnapshot.visibleGroups.count < 4,
              layoutSnapshot.visibleGroups.contains(dropTarget),
              layoutSnapshot.tabIDs(in: payload.sourceGroup).contains(payload.tabID) else {
            cancelDrop()
            return nil
        }
        let operation = validateEdgeDrop(
            payload: payload,
            location: location,
            optionPressed: optionPressed
        )
        dropOverlay.present(highlighting: operation == nil ? nil : dropOverlay.zone(at: location))
        return operation
    }

    @discardableResult
    public func performEdgeDrop(
        payload: EditorGroupDragPayload,
        location: NSPoint,
        optionPressed: Bool
    ) -> Bool {
        defer { cancelDrop() }
        guard let operation = validateEdgeDrop(
            payload: payload,
            location: location,
            optionPressed: optionPressed
        ), let zone = dropOverlay.zone(at: location) else { return false }
        if layoutSnapshot?.orientation == nil, zone == .right || zone == .down {
            onAction?(.split(payload.tabID, payload.sourceGroup, zone.orientation, operation))
        } else {
            onAction?(.splitAdjacent(payload.tabID, payload.sourceGroup, dropTarget, zone, operation))
        }
        return true
    }

    public func cancelDrop() {
        dropOverlay.dismiss()
    }

    public func tearDown() {
        unregisterDraggedTypes()
        cancelDrop()
        removeSecondaryPane()
        for pane in additionalPanes.values { pane.tearDown(); pane.removeFromSuperview() }
        additionalPanes.removeAll()
        primaryPane.tearDown()
        layoutSnapshot = nil
        onAction = nil
    }

    public func validateTabDrop(
        payload: EditorGroupDragPayload,
        destinationGroup: EditorGroupID,
        insertionIndex: Int,
        optionPressed: Bool
    ) -> EditorGroupDropOperation? {
        guard let layoutSnapshot,
              visibleGroups.contains(destinationGroup),
              layoutSnapshot.tabIDs(in: payload.sourceGroup).contains(payload.tabID),
              (0...layoutSnapshot.tabIDs(in: destinationGroup).count).contains(insertionIndex) else {
            return nil
        }
        if payload.sourceGroup == destinationGroup { return .move }
        let operation = EditorGroupDragPayload.dropOperation(optionPressed: optionPressed)
        let destinationContainsTab = layoutSnapshot.tabIDs(in: destinationGroup).contains(payload.tabID)
        if operation == .copy, destinationContainsTab { return nil }
        if operation == .move,
           layoutSnapshot.tabIDs(in: payload.sourceGroup).count <= 1,
           !destinationContainsTab {
            return nil
        }
        return operation
    }

    @discardableResult
    public func performTabDrop(
        payload: EditorGroupDragPayload,
        destinationGroup: EditorGroupID,
        insertionIndex: Int,
        optionPressed: Bool
    ) -> Bool {
        guard let layoutSnapshot,
              let operation = validateTabDrop(
                  payload: payload,
                  destinationGroup: destinationGroup,
                  insertionIndex: insertionIndex,
                  optionPressed: optionPressed
              ) else { return false }
        if payload.sourceGroup == destinationGroup {
            let sourceTabs = layoutSnapshot.tabIDs(in: destinationGroup)
            guard let sourceIndex = sourceTabs.firstIndex(of: payload.tabID),
                  let destination = TabDropDestination.finalIndex(
                      sourceIndex: sourceIndex,
                      insertionIndex: insertionIndex,
                      itemCount: sourceTabs.count
                  ) else { return false }
            onAction?(.reorder(payload.tabID, destinationGroup, destination))
        } else if operation == .copy {
            onAction?(.clone(payload.tabID, payload.sourceGroup, destinationGroup))
        } else {
            onAction?(.move(payload.tabID, payload.sourceGroup, destinationGroup))
        }
        return true
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateNativeDrag(sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateNativeDrag(sender)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        cancelDrop()
    }

    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = nativePayload(from: sender) else { return false }
        return validateEdgeDrop(
            payload: payload,
            location: dropLocation(from: sender),
            optionPressed: sourceRequestsCopy(sender)
        ) != nil
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = nativePayload(from: sender) else {
            cancelDrop()
            return false
        }
        return performEdgeDrop(
            payload: payload,
            location: dropLocation(from: sender),
            optionPressed: sourceRequestsCopy(sender)
        )
    }

    public override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        cancelDrop()
    }

    private var visibleGroups: Set<EditorGroupID> {
        Set(layoutSnapshot?.visibleGroups ?? [.primary])
    }

    private func rebuildPanes(for tree: EditorGroupLayoutTree) {
        dividerFractions.removeAll(keepingCapacity: true)
        func capture(_ node: EditorGroupLayoutTree, from split: NSSplitView) {
            guard case .split(_, let first, let second) = node,
                  split.arrangedSubviews.count == 2 else { return }
            let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
            let firstFrame = split.arrangedSubviews[0].frame
            if length > 0 {
                let fraction = (split.isVertical ? firstFrame.width : firstFrame.height) / length
                dividerFractions.append((node, min(0.9, max(0.1, fraction))))
            }
            for (child, view) in zip([first, second], split.arrangedSubviews) {
                if let nested = view as? NSSplitView { capture(child, from: nested) }
            }
        }
        if let renderedTree { capture(renderedTree, from: splitView) }
        let groups = Set(tree.groups)
        if groups.contains(.secondary), secondaryPane == nil {
            let pane = EditorGroupPaneView(groupID: .secondary, editorHostView: secondaryEditorHost)
            secondaryPane = pane
            bind(pane)
        }
        for group in [EditorGroupID.tertiary, .quaternary] {
            if groups.contains(group), additionalPanes[group] == nil {
                let pane = EditorGroupPaneView(groupID: group, editorHostView: additionalEditorHosts[group] ?? NSView())
                additionalPanes[group] = pane
                bind(pane)
            } else if !groups.contains(group), let pane = additionalPanes.removeValue(forKey: group) {
                pane.tearDown()
                pane.removeFromSuperview()
            }
        }
        if !groups.contains(.secondary) { removeSecondaryPane() }
        for pane in [primaryPane, secondaryPane].compactMap({ $0 }) + Array(additionalPanes.values) {
            if let parent = pane.superview as? NSSplitView { parent.removeArrangedSubview(pane) }
            pane.removeFromSuperview()
        }
        for view in splitView.arrangedSubviews { splitView.removeArrangedSubview(view); view.removeFromSuperview() }
        func populate(_ tree: EditorGroupLayoutTree, in split: NSSplitView) {
            switch tree {
            case .leaf(let group):
                if let pane = pane(for: group) {
                    pane.translatesAutoresizingMaskIntoConstraints = true
                    pane.frame = split.bounds
                    split.addArrangedSubview(pane)
                }
            case .split(let orientation, let first, let second):
                split.isVertical = orientation == .sideBySide
                for node in [first, second] {
                    if case .leaf(let group) = node, let pane = pane(for: group) {
                        pane.translatesAutoresizingMaskIntoConstraints = true
                        pane.frame = split.bounds
                        split.addArrangedSubview(pane)
                    } else {
                        let nested = NSSplitView(frame: split.bounds)
                        nested.dividerStyle = .thin
                        split.addArrangedSubview(nested)
                        populate(node, in: nested)
                    }
                }
            }
            split.adjustSubviews()
        }
        populate(tree, in: splitView)
        needsInitialDividerLayout = true
    }

    private func removeSecondaryPane() {
        guard let pane = secondaryPane else { return }
        (pane.superview as? NSSplitView)?.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        pane.tearDown()
        secondaryPane = nil
    }

    private func bind(_ pane: EditorGroupPaneView) {
        let group = pane.groupID
        pane.tabStrip.onActivate = { [weak self] tabID in self?.onAction?(.select(tabID, group)) }
        pane.tabStrip.onClose = { [weak self] tabID in self?.onAction?(.close(tabID, group)) }
        pane.tabStrip.onMove = { [weak self] tabID, index in self?.onAction?(.reorder(tabID, group, index)) }
        pane.tabStrip.onContextAction = { [weak self] tabID, action in
            self?.onAction?(.context(tabID, group, action))
        }
        pane.tabStrip.onValidateGroupDrop = { [weak self] payload, index, operation in
            self?.validateTabDrop(
                payload: payload,
                destinationGroup: group,
                insertionIndex: index,
                optionPressed: operation == .copy
            ) != nil
        }
        pane.tabStrip.onGroupDrop = { [weak self] payload, index, operation in
            self?.performTabDrop(
                payload: payload,
                destinationGroup: group,
                insertionIndex: index,
                optionPressed: operation == .copy
            ) ?? false
        }
    }

    private func updateNativeDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let payload = nativePayload(from: sender) else {
            cancelDrop()
            return []
        }
        let optionPressed = sourceRequestsCopy(sender)
        guard let operation = updateEdgeDrop(
            payload: payload,
            location: dropLocation(from: sender),
            optionPressed: optionPressed
        ) else { return [] }
        return operation == .copy ? .copy : .move
    }

    private func nativePayload(from sender: any NSDraggingInfo) -> EditorGroupDragPayload? {
        guard let data = sender.draggingPasteboard.data(forType: groupPasteboardType) else { return nil }
        return EditorGroupDragPayload(data: data)
    }

    private func dropLocation(from sender: any NSDraggingInfo) -> NSPoint {
        let point = convert(sender.draggingLocation, from: nil)
        if let group = layoutSnapshot?.visibleGroups.first(where: { group in
            guard let host = pane(for: group)?.editorHostView else { return false }
            return host.convert(host.bounds, to: self).contains(point)
        }) { positionDropOverlay(in: group) }
        return dropOverlay.convert(sender.draggingLocation, from: nil)
    }

    private func sourceRequestsCopy(_ sender: any NSDraggingInfo) -> Bool {
        let mask = sender.draggingSourceOperationMask
        return mask.contains(.copy)
            && (!mask.contains(.move) || modifierFlagsProvider().contains(.option))
    }
}
