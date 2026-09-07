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

    public init() {}

    public var snapshot: EditorGroupLayoutSnapshot {
        EditorGroupLayoutSnapshot(
            primaryTabIDs: primaryTabIDs,
            secondaryTabIDs: secondaryTabIDs,
            primarySelectedTabID: primarySelectedTabID,
            secondarySelectedTabID: secondarySelectedTabID,
            focusedGroup: focusedGroup,
            orientation: orientation
        )
    }

    public func reconcile(workspace: WorkspaceSnapshot) {
        let previousTabIDs = Set(workspaceTabIDs)
        workspaceTabIDs = workspace.tabs.map(\.id)
        let workspaceTabIDSet = Set(workspaceTabIDs)

        primaryTabIDs = normalized(primaryTabIDs.filter { workspaceTabIDSet.contains($0) })
        secondaryTabIDs = normalized(secondaryTabIDs.filter { workspaceTabIDSet.contains($0) })

        let knownTabIDs = Set(primaryTabIDs).union(secondaryTabIDs)
        let insertedTabIDs = workspaceTabIDs.filter {
            !knownTabIDs.contains($0) && (!previousTabIDs.contains($0) || primaryTabIDs.isEmpty && secondaryTabIDs.isEmpty)
        }
        append(insertedTabIDs, to: focusedGroup)
        normalizeEmptyGroup()
        reconcileSelections()

        guard let activeTabID = workspace.tabs.first(where: \.isActive)?.id else { return }
        let activeGroups = EditorGroupID.allCases.filter { tabIDs(in: $0).contains(activeTabID) }
        switch activeGroups.count {
        case 1:
            focusedGroup = activeGroups[0]
            setSelected(activeTabID, in: focusedGroup)
        case 2:
            setSelected(activeTabID, in: focusedGroup)
        default:
            append([activeTabID], to: focusedGroup)
            setSelected(activeTabID, in: focusedGroup)
        }
    }

    @discardableResult
    public func select(_ tabID: TabID, in group: EditorGroupID) -> Bool {
        guard tabIDs(in: group).contains(tabID) else { return false }
        setSelected(tabID, in: group)
        focusedGroup = group
        return true
    }

    @discardableResult
    public func split(
        tabID: TabID,
        source: EditorGroupID,
        orientation: EditorGroupSplitOrientation,
        operation: EditorGroupDropOperation
    ) -> Bool {
        let destination = source.other
        guard tabIDs(in: source).contains(tabID) else { return false }

        switch operation {
        case .move:
            return move(tabID, from: source, to: destination, orientation: orientation)
        case .copy:
            guard !tabIDs(in: destination).contains(tabID) else { return false }
            append([tabID], to: destination)
            self.orientation = orientation
            setSelected(tabID, in: destination)
            focusedGroup = destination
            return true
        }
    }

    @discardableResult
    public func move(_ tabID: TabID, from source: EditorGroupID, to destination: EditorGroupID) -> Bool {
        guard orientation != nil else { return false }
        return move(tabID, from: source, to: destination, orientation: orientation)
    }

    public func closeSecondaryGroup() {
        append(secondaryTabIDs, to: .primary)
        secondaryTabIDs = []
        secondarySelectedTabID = nil
        focusedGroup = .primary
        orientation = nil
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
        setSelected(tabID, in: destination)
        focusedGroup = destination
        normalizeEmptyGroup()
        reconcileSelections()
        return true
    }

    private func canMove(_ tabID: TabID, from source: EditorGroupID, to destination: EditorGroupID) -> Bool {
        source != destination
            && tabIDs(in: source).contains(tabID)
            && (tabIDs(in: source).count > 1 || tabIDs(in: destination).contains(tabID))
    }

    private func tabIDs(in group: EditorGroupID) -> [TabID] {
        switch group {
        case .primary: primaryTabIDs
        case .secondary: secondaryTabIDs
        }
    }

    private func append(_ tabIDs: [TabID], to group: EditorGroupID) {
        switch group {
        case .primary:
            primaryTabIDs = normalized(primaryTabIDs + tabIDs)
        case .secondary:
            secondaryTabIDs = normalized(secondaryTabIDs + tabIDs)
        }
    }

    private func remove(_ tabID: TabID, from group: EditorGroupID) {
        switch group {
        case .primary:
            primaryTabIDs.removeAll { $0 == tabID }
        case .secondary:
            secondaryTabIDs.removeAll { $0 == tabID }
        }
    }

    private func setSelected(_ tabID: TabID, in group: EditorGroupID) {
        switch group {
        case .primary: primarySelectedTabID = tabID
        case .secondary: secondarySelectedTabID = tabID
        }
    }

    private func normalized(_ tabIDs: [TabID]) -> [TabID] {
        let tabIDSet = Set(tabIDs)
        return workspaceTabIDs.filter { tabIDSet.contains($0) }
    }

    private func normalizeEmptyGroup() {
        guard primaryTabIDs.isEmpty || secondaryTabIDs.isEmpty else { return }
        if primaryTabIDs.isEmpty {
            primaryTabIDs = secondaryTabIDs
            primarySelectedTabID = secondarySelectedTabID
        }
        secondaryTabIDs = []
        secondarySelectedTabID = nil
        focusedGroup = .primary
        orientation = nil
    }

    private func reconcileSelections() {
        if primarySelectedTabID.map({ primaryTabIDs.contains($0) }) != true {
            primarySelectedTabID = primaryTabIDs.first
        }
        if secondarySelectedTabID.map({ secondaryTabIDs.contains($0) }) != true {
            secondarySelectedTabID = secondaryTabIDs.first
        }
    }
}
