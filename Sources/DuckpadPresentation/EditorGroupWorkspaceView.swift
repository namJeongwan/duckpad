import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
public final class EditorGroupWorkspaceView: NSView {
    public enum Action: Equatable, Sendable {
        case select(TabID, EditorGroupID)
        case reorder(TabID, EditorGroupID, Int)
        case split(TabID, EditorGroupID, EditorGroupSplitOrientation, EditorGroupDropOperation)
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
    private let modifierFlagsProvider: () -> NSEvent.ModifierFlags
    private var layoutSnapshot: EditorGroupLayoutSnapshot?
    private let groupPasteboardType = NSPasteboard.PasteboardType(EditorGroupDragPayload.pasteboardType)

    public convenience init(primaryEditorHost: NSView, secondaryEditorHost: NSView) {
        self.init(
            primaryEditorHost: primaryEditorHost,
            secondaryEditorHost: secondaryEditorHost,
            modifierFlagsProvider: { NSEvent.modifierFlags }
        )
    }

    init(
        primaryEditorHost: NSView,
        secondaryEditorHost: NSView,
        modifierFlagsProvider: @escaping () -> NSEvent.ModifierFlags
    ) {
        self.secondaryEditorHost = secondaryEditorHost
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

        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropOverlay, positioned: .above, relativeTo: splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: primaryPane.editorHostView.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: primaryPane.editorHostView.trailingAnchor),
            dropOverlay.topAnchor.constraint(equalTo: primaryPane.editorHostView.topAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: primaryPane.editorHostView.bottomAnchor),
        ])
        registerForDraggedTypes([groupPasteboardType])
        bind(primaryPane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func apply(workspace: WorkspaceSnapshot, layout: EditorGroupLayoutSnapshot) {
        layoutSnapshot = layout
        cancelDrop()

        if let orientation = layout.orientation {
            ensureSecondaryPane()
            splitView.isVertical = orientation == .sideBySide
        } else {
            removeSecondaryPane()
        }

        let tabsByID = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0) })
        primaryPane.apply(
            tabs: layout.primaryTabIDs.compactMap { tabsByID[$0] },
            selectedTabID: layout.primarySelectedTabID,
            focused: layout.focusedGroup == .primary
        )
        secondaryPane?.apply(
            tabs: layout.secondaryTabIDs.compactMap { tabsByID[$0] },
            selectedTabID: layout.secondarySelectedTabID,
            focused: layout.focusedGroup == .secondary
        )
    }

    public func requestFocus(_ group: EditorGroupID) {
        guard group == .primary || secondaryPane != nil else { return }
        onAction?(.focus(group))
    }

    @discardableResult
    public func applyFocus(layout: EditorGroupLayoutSnapshot) -> Bool {
        if layout.orientation == nil {
            guard layout.focusedGroup == .primary, secondaryPane == nil else { return false }
        } else {
            guard secondaryPane != nil else { return false }
        }
        layoutSnapshot = layout
        primaryPane.setFocused(layout.focusedGroup == .primary)
        secondaryPane?.setFocused(layout.focusedGroup == .secondary)
        return true
    }

    public func validateEdgeDrop(
        payload: EditorGroupDragPayload,
        location: NSPoint,
        optionPressed: Bool
    ) -> EditorGroupDropOperation? {
        guard let layoutSnapshot,
              layoutSnapshot.orientation == nil,
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
              layoutSnapshot.orientation == nil,
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
        onAction?(.split(payload.tabID, payload.sourceGroup, zone.orientation, operation))
        return true
    }

    public func cancelDrop() {
        dropOverlay.dismiss()
    }

    public func tearDown() {
        unregisterDraggedTypes()
        cancelDrop()
        removeSecondaryPane()
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
        secondaryPane == nil ? [.primary] : Set(EditorGroupID.allCases)
    }

    private func ensureSecondaryPane() {
        guard secondaryPane == nil else { return }
        let pane = EditorGroupPaneView(groupID: .secondary, editorHostView: secondaryEditorHost)
        secondaryPane = pane
        bind(pane)
        splitView.addArrangedSubview(pane)
    }

    private func removeSecondaryPane() {
        guard let pane = secondaryPane else { return }
        splitView.removeArrangedSubview(pane)
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
        dropOverlay.convert(sender.draggingLocation, from: nil)
    }

    private func sourceRequestsCopy(_ sender: any NSDraggingInfo) -> Bool {
        let mask = sender.draggingSourceOperationMask
        return mask.contains(.copy)
            && (!mask.contains(.move) || modifierFlagsProvider().contains(.option))
    }
}
