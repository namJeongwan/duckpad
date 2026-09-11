public struct OpenDocumentCompareContent: Equatable, Sendable {
    public let title: String
    public let leftTitle: String
    public let rightTitle: String
    public let leftText: String
    public let rightText: String
    public let titleKey: String?
    public let titleArguments: [String]
    public let leftTitleKey: String?
    public let leftTitleArguments: [String]
    public let rightTitleKey: String?
    public let rightTitleArguments: [String]

    public init(
        title: String,
        leftTitle: String,
        rightTitle: String,
        leftText: String,
        rightText: String,
        titleKey: String? = nil,
        titleArguments: [String] = [],
        leftTitleKey: String? = nil,
        leftTitleArguments: [String] = [],
        rightTitleKey: String? = nil,
        rightTitleArguments: [String] = []
    ) {
        self.title = title
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        self.leftText = leftText
        self.rightText = rightText
        self.titleKey = titleKey
        self.titleArguments = titleArguments
        self.leftTitleKey = leftTitleKey
        self.leftTitleArguments = leftTitleArguments
        self.rightTitleKey = rightTitleKey
        self.rightTitleArguments = rightTitleArguments
    }
}
