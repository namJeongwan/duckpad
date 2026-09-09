import DuckpadApplication
import DuckpadDomain

public struct EditorGroupLayoutSnapshot: Equatable, Sendable {
    public let primaryTabIDs: [TabID]
    public let secondaryTabIDs: [TabID]
    public let primarySelectedTabID: TabID?
    public let secondarySelectedTabID: TabID?
    public let focusedGroup: EditorGroupID
    public let orientation: EditorGroupSplitOrientation?
    public let tree: EditorGroupLayoutTree
    public let additionalTabIDs: [EditorGroupID: [TabID]]
    public let additionalSelectedTabIDs: [EditorGroupID: TabID]
    public var visibleGroups: [EditorGroupID] { tree.groups }

    public init(
        primaryTabIDs: [TabID],
        secondaryTabIDs: [TabID],
        primarySelectedTabID: TabID?,
        secondarySelectedTabID: TabID?,
        focusedGroup: EditorGroupID,
        orientation: EditorGroupSplitOrientation?,
        tree: EditorGroupLayoutTree? = nil,
        additionalTabIDs: [EditorGroupID: [TabID]] = [:],
        additionalSelectedTabIDs: [EditorGroupID: TabID] = [:]
    ) {
        self.primaryTabIDs = primaryTabIDs
        self.secondaryTabIDs = secondaryTabIDs
        self.primarySelectedTabID = primarySelectedTabID
        self.secondarySelectedTabID = secondarySelectedTabID
        self.focusedGroup = focusedGroup
        self.orientation = orientation
        self.tree = tree ?? orientation.map { .split($0, .leaf(.primary), .leaf(.secondary)) } ?? .leaf(.primary)
        self.additionalTabIDs = additionalTabIDs
        self.additionalSelectedTabIDs = additionalSelectedTabIDs
    }

    public func tabIDs(in group: EditorGroupID) -> [TabID] {
        switch group {
        case .primary: primaryTabIDs
        case .secondary: secondaryTabIDs
        case .tertiary, .quaternary: additionalTabIDs[group] ?? []
        }
    }

    public func selectedTabID(in group: EditorGroupID) -> TabID? {
        switch group {
        case .primary: primarySelectedTabID
        case .secondary: secondarySelectedTabID
        case .tertiary, .quaternary: additionalSelectedTabIDs[group]
        }
    }
}
