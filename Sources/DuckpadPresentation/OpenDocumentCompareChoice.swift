import DuckpadDomain

public struct OpenDocumentCompareChoice: Equatable, Sendable {
    public let tabID: TabID
    public let label: String

    public init(tabID: TabID, label: String) {
        self.tabID = tabID
        self.label = label
    }
}
