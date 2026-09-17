import Foundation

/// Immutable bytes carry validation only when constructed from a Swift String
/// or a materialization whose UTF-8 boundaries have already been checked.
public struct EditorRecoveryCheckpoint: Equatable, Sendable {
    public let utf8: Data
    let isValidated: Bool

    public init(text: String) {
        utf8 = Data(text.utf8)
        isValidated = true
    }

    public init(utf8: Data) {
        // A caller may supply memory-mapped or externally backed Data. Own the
        // bytes so later file changes cannot alter this immutable checkpoint.
        self.utf8 = utf8.withUnsafeBytes { Data($0) }
        isValidated = false
    }

    init(validatedUTF8: Data) {
        utf8 = validatedUTF8
        isValidated = true
    }

    /// Trusted checkpoints have already been validated during construction.
    public var isValidUTF8: Bool {
        isValidated || String(data: utf8, encoding: .utf8) != nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.utf8 == rhs.utf8 }
}
