public struct OpenDocumentCompareContent: Equatable, Sendable {
    public let title: String
    public let leftTitle: String
    public let rightTitle: String
    public let leftText: String
    public let rightText: String

    public init(
        title: String,
        leftTitle: String,
        rightTitle: String,
        leftText: String,
        rightText: String
    ) {
        self.title = title
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        self.leftText = leftText
        self.rightText = rightText
    }
}
