import DuckpadApplication

public indirect enum EditorGroupLayoutTree: Equatable, Sendable {
    case leaf(EditorGroupID)
    case split(EditorGroupSplitOrientation, EditorGroupLayoutTree, EditorGroupLayoutTree)

    public var groups: [EditorGroupID] {
        switch self {
        case .leaf(let group): [group]
        case .split(_, let first, let second): first.groups + second.groups
        }
    }

    public var orientation: EditorGroupSplitOrientation? {
        if case .split(let orientation, _, _) = self { return orientation }
        return nil
    }

    func replacing(_ group: EditorGroupID, with replacement: Self) -> Self {
        switch self {
        case .leaf(let value): value == group ? replacement : self
        case .split(let orientation, let first, let second):
            .split(orientation, first.replacing(group, with: replacement), second.replacing(group, with: replacement))
        }
    }

    func retaining(_ groups: Set<EditorGroupID>) -> Self? {
        switch self {
        case .leaf(let group): return groups.contains(group) ? self : nil
        case .split(let orientation, let first, let second):
            let a = first.retaining(groups)
            let b = second.retaining(groups)
            if let a, let b { return .split(orientation, a, b) }
            return a ?? b
        }
    }
}
