import DuckpadApplication
import DuckpadDomain

public struct EditorGroupLayoutSnapshot: Equatable, Sendable {
    public let primaryTabIDs: [TabID]
    public let secondaryTabIDs: [TabID]
    public let primarySelectedTabID: TabID?
    public let secondarySelectedTabID: TabID?
    public let focusedGroup: EditorGroupID
    public let orientation: EditorGroupSplitOrientation?

    public init(
        primaryTabIDs: [TabID],
        secondaryTabIDs: [TabID],
        primarySelectedTabID: TabID?,
        secondarySelectedTabID: TabID?,
        focusedGroup: EditorGroupID,
        orientation: EditorGroupSplitOrientation?
    ) {
        self.primaryTabIDs = primaryTabIDs
        self.secondaryTabIDs = secondaryTabIDs
        self.primarySelectedTabID = primarySelectedTabID
        self.secondarySelectedTabID = secondarySelectedTabID
        self.focusedGroup = focusedGroup
        self.orientation = orientation
    }

    public func tabIDs(in group: EditorGroupID) -> [TabID] {
        switch group {
        case .primary: primaryTabIDs
        case .secondary: secondaryTabIDs
        }
    }

    public func selectedTabID(in group: EditorGroupID) -> TabID? {
        switch group {
        case .primary: primarySelectedTabID
        case .secondary: secondarySelectedTabID
        }
    }
}
