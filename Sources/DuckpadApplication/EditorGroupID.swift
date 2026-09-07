public enum EditorGroupID: String, CaseIterable, Codable, Equatable, Sendable {
    case primary
    case secondary

    public var other: EditorGroupID {
        switch self {
        case .primary: .secondary
        case .secondary: .primary
        }
    }
}
