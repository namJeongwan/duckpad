import Foundation

public struct FileLoadingProgress: Equatable, Sendable {
    public let path: String
    public let loadedByteCount: Int
    public let totalByteCount: Int?

    public init(path: String, loadedByteCount: Int, totalByteCount: Int?) {
        self.path = path
        self.loadedByteCount = loadedByteCount
        self.totalByteCount = totalByteCount
    }

    public var fractionCompleted: Double {
        guard let totalByteCount else { return 0 }
        guard totalByteCount > 0 else { return 1 }
        return min(1, max(0, Double(loadedByteCount) / Double(totalByteCount)))
    }

    public var percent: Int { Int(fractionCompleted * 100) }
}
