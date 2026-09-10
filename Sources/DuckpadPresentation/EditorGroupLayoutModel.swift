import DuckpadApplication
import DuckpadDomain

@MainActor
public final class EditorGroupLayoutModel {
    private var workspaceTabIDs: [TabID] = []
    private var primaryTabIDs: [TabID] = []
    private var secondaryTabIDs: [TabID] = []
    private var primarySelectedTabID: TabID?
    private var secondarySelectedTabID: TabID?
    private var focusedGroup: EditorGroupID = .primary
    private var orientation: EditorGroupSplitOrientation?
    private var additionalTabIDs: [EditorGroupID: [TabID]] = [:]
    private var additionalSelectedTabIDs: [EditorGroupID: TabID] = [:]
    private var tree: EditorGroupLayoutTree = .leaf(.primary)

    public init() {}

    init(snapshot: EditorGroupLayoutSnapshot) {
        primaryTabIDs = snapshot.primaryTabIDs
        secondaryTabIDs = snapshot.secondaryTabIDs
        primarySelectedTabID = snapshot.primarySelectedTabID
        secondarySelectedTabID = snapshot.secondarySelectedTabID
        additionalTabIDs = snapshot.additionalTabIDs
        additionalSelectedTabIDs = snapshot.additionalSelectedTabIDs
        focusedGroup = snapshot.focusedGroup
        orientation = snapshot.orientation
        tree = snapshot.tree
        workspaceTabIDs = tree.groups.flatMap { snapshot.tabIDs(in: $0) }
    }

    public var snapshot: EditorGroupLayoutSnapshot {
        EditorGroupLayoutSnapshot(
            primaryTabIDs: primaryTabIDs,
            secondaryTabIDs: secondaryTabIDs,
            primarySelectedTabID: primarySelectedTabID,
            secondarySelectedTabID: secondarySelectedTabID,
            focusedGroup: focusedGroup,
            orientation: orientation,
            tree: tree,
            additionalTabIDs: additionalTabIDs,
            additionalSelectedTabIDs: additionalSelectedTabIDs
        )
    }

    public func reconcile(workspace: WorkspaceSnapshot) {
        let previousTabIDs = Set(workspaceTabIDs)
        workspaceTabIDs = workspace.tabs.map(\.id)
        let workspaceTabIDSet = Set(workspaceTabIDs)

        primaryTabIDs = normalized(primaryTabIDs.filter { workspaceTabIDSet.contains($0) })
        secondaryTabIDs = normalized(secondaryTabIDs.filter { workspaceTabIDSet.contains($0) })
        for group in Array(additionalTabIDs.keys) {
            additionalTabIDs[group] = normalized(tabIDs(in: group).filter { workspaceTabIDSet.contains($0) })
        }

        let knownTabIDs = Set(tree.groups.flatMap { tabIDs(in: $0) })
        let insertedTabIDs = workspaceTabIDs.filter {
            !knownTabIDs.contains($0) && (!previousTabIDs.contains($0) || primaryTabIDs.isEmpty && secondaryTabIDs.isEmpty)
        }
        append(insertedTabIDs, to: focusedGroup)
        normalizeEmptyGroup()
        reconcileSelections()

        guard let activeTabID = workspace.tabs.first(where: \.isActive)?.id else { return }
        let activeGroups = tree.groups.filter { tabIDs(in: $0).contains(activeTabID) }
        switch activeGroups.count {
        case 1:
            focusedGroup = activeGroups[0]
            setSelected(activeTabID, in: focusedGroup)
        case 2...:
            if !activeGroups.contains(focusedGroup) { focusedGroup = activeGroups[0] }
            setSelected(activeTabID, in: focusedGroup)
        default:
            append([activeTabID], to: focusedGroup)
            setSelected(activeTabID, in: focusedGroup)
        }
    }

    @discardableResult
    public func select(_ tabID: TabID, in group: EditorGroupID) -> Bool {
        guard tabIDs(in: group).contains(tabID) else { return false }
        selectKnownMember(tabID, in: group)
        return true
    }

    func selectKnownMember(_ tabID: TabID, in group: EditorGroupID) {
        setSelected(tabID, in: group)
        focusedGroup = group
    }

    @discardableResult
    public func split(
        tabID: TabID,
        source: EditorGroupID,
        orientation: EditorGroupSplitOrientation,
        operation: EditorGroupDropOperation
    ) -> Bool {
        let destination = source.other
        guard tabIDs(in: source).contains(tabID),
              self.orientation == nil || tree.groups.contains(destination) else { return false }

        switch operation {
        case .move:
            return move(tabID, from: source, to: destination, orientation: orientation)
        case .copy:
            guard !tabIDs(in: destination).contains(tabID) else { return false }
            append([tabID], to: destination)
            self.orientation = orientation
            if tree.orientation == nil { tree = .split(orientation, .leaf(.primary), .leaf(.secondary)) }
            setSelected(tabID, in: destination)
            focusedGroup = destination
            return true
        }
    }

    @discardableResult
    public func move(_ tabID: TabID, from source: EditorGroupID, to destination: EditorGroupID) -> Bool {
        guard orientation != nil, tree.groups.contains(destination) else { return false }
        return move(tabID, from: source, to: destination, orientation: orientation)
    }

    public func closeSecondaryGroup() {
        append(tree.groups.filter { $0 != .primary }.flatMap { tabIDs(in: $0) }, to: .primary)
        secondaryTabIDs = []
        secondarySelectedTabID = nil
        additionalTabIDs = [:]
        additionalSelectedTabIDs = [:]
        focusedGroup = .primary
        orientation = nil
        tree = .leaf(.primary)
        reconcileSelections()
    }

    @discardableResult
    public func splitAdjacent(
        tabID: TabID, source: EditorGroupID, target: EditorGroupID,
        zone: EditorGroupDropOverlay.Zone, operation: EditorGroupDropOperation
    ) -> EditorGroupID? {
        guard tree.groups.contains(target), tabIDs(in: source).contains(tabID),
              operation == .copy || tabIDs(in: source).count > 1 else { return nil }
        let destination = EditorGroupID.predefined.first(where: { !tree.groups.contains($0) }) ?? EditorGroupID()
        if operation == .move { remove(tabID, from: source) }
        append([tabID], to: destination)
        let old = EditorGroupLayoutTree.leaf(target)
        let new = EditorGroupLayoutTree.leaf(destination)
        tree = tree.replacing(target, with: .split(zone.orientation, zone.precedesTarget ? new : old, zone.precedesTarget ? old : new))
        orientation = tree.orientation
        setSelected(tabID, in: destination)
        focusedGroup = destination
        reconcileSelections()
        return destination
    }

    @discardableResult
    public func clone(_ tabID: TabID, from source: EditorGroupID, to destination: EditorGroupID) -> Bool {
        guard tree.groups.contains(destination), tabIDs(in: source).contains(tabID),
              !tabIDs(in: destination).contains(tabID) else { return false }
        append([tabID], to: destination)
        setSelected(tabID, in: destination)
        focusedGroup = destination
        return true
    }

    public func closeGroup(_ group: EditorGroupID) {
        guard tree.groups.count > 1, let destination = tree.groups.first(where: { $0 != group }) else { return }
        append(tabIDs(in: group), to: destination)
        for id in tabIDs(in: group) { remove(id, from: group) }
        focusedGroup = destination
        normalizeEmptyGroup()
        reconcileSelections()
    }

    private func move(
        _ tabID: TabID,
        from source: EditorGroupID,
        to destination: EditorGroupID,
        orientation: EditorGroupSplitOrientation?
    ) -> Bool {
        guard canMove(tabID, from: source, to: destination) else { return false }
        remove(tabID, from: source)
        append([tabID], to: destination)
        if let orientation { self.orientation = orientation }
        if tree.orientation == nil, let orientation { tree = .split(orientation, .leaf(.primary), .leaf(.secondary)) }
        setSelected(tabID, in: destination)
        focusedGroup = destination
        normalizeEmptyGroup()
        reconcileSelections()
        return true
    }

    private func canMove(_ tabID: TabID, from source: EditorGroupID, to destination: EditorGroupID) -> Bool {
        source != destination
            && tabIDs(in: source).contains(tabID)
            && (tree.groups.contains(destination) || tabIDs(in: source).count > 1)
    }

    private func tabIDs(in group: EditorGroupID) -> [TabID] {
        switch group {
        case .primary: primaryTabIDs
        case .secondary: secondaryTabIDs
        default: additionalTabIDs[group] ?? []
        }
    }

    private func append(_ tabIDs: [TabID], to group: EditorGroupID) {
        switch group {
        case .primary:
            primaryTabIDs = normalized(primaryTabIDs + tabIDs)
        case .secondary:
            secondaryTabIDs = normalized(secondaryTabIDs + tabIDs)
        default:
            additionalTabIDs[group] = normalized((additionalTabIDs[group] ?? []) + tabIDs)
        }
    }

    private func remove(_ tabID: TabID, from group: EditorGroupID) {
        switch group {
        case .primary:
            primaryTabIDs.removeAll { $0 == tabID }
        case .secondary:
            secondaryTabIDs.removeAll { $0 == tabID }
        default:
            additionalTabIDs[group]?.removeAll { $0 == tabID }
        }
    }

    private func setSelected(_ tabID: TabID, in group: EditorGroupID) {
        switch group {
        case .primary: primarySelectedTabID = tabID
        case .secondary: secondarySelectedTabID = tabID
        default: additionalSelectedTabIDs[group] = tabID
        }
    }

    private func normalized(_ tabIDs: [TabID]) -> [TabID] {
        let tabIDSet = Set(tabIDs)
        return workspaceTabIDs.filter { tabIDSet.contains($0) }
    }

    private func normalizeEmptyGroup() {
        let remaining = Set(tree.groups.filter { !tabIDs(in: $0).isEmpty })
        tree = tree.retaining(remaining) ?? .leaf(.primary)
        if primaryTabIDs.isEmpty, let promoted = tree.groups.first, promoted != .primary {
            primaryTabIDs = tabIDs(in: promoted)
            primarySelectedTabID = snapshot.selectedTabID(in: promoted)
            for id in primaryTabIDs { remove(id, from: promoted) }
            tree = tree.replacing(promoted, with: .leaf(.primary))
            if focusedGroup == promoted { focusedGroup = .primary }
        }
        if !tree.groups.contains(focusedGroup) { focusedGroup = tree.groups.first ?? .primary }
        orientation = tree.orientation
        let visible = Set(tree.groups)
        additionalTabIDs = additionalTabIDs.filter { visible.contains($0.key) }
        additionalSelectedTabIDs = additionalSelectedTabIDs.filter { visible.contains($0.key) }
    }

    private func reconcileSelections() {
        if primarySelectedTabID.map({ primaryTabIDs.contains($0) }) != true {
            primarySelectedTabID = primaryTabIDs.first
        }
        if secondarySelectedTabID.map({ secondaryTabIDs.contains($0) }) != true {
            secondarySelectedTabID = secondaryTabIDs.first
        }
        for group in Array(additionalTabIDs.keys) {
            if additionalSelectedTabIDs[group].map({ tabIDs(in: group).contains($0) }) != true {
                additionalSelectedTabIDs[group] = tabIDs(in: group).first
            }
        }
    }
}
