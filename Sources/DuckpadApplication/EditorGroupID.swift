public enum EditorGroupID: String, CaseIterable, Codable, Equatable, Sendable {
    case primary
    case secondary
    case tertiary
    case quaternary

    public var other: EditorGroupID {
        switch self {
        case .primary: .secondary
        case .secondary: .primary
        case .tertiary: .primary
        case .quaternary: .primary
        }
    }
}
