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
        self.utf8 = utf8
        isValidated = false
    }

    init(validatedUTF8: Data) {
        utf8 = validatedUTF8
        isValidated = true
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.utf8 == rhs.utf8 }
}
