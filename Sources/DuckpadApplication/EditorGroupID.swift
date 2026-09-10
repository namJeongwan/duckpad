import Foundation

/// Stable window-local identity. The original four names remain readable in
/// existing drag payloads; additional groups receive independent UUIDs.
public struct EditorGroupID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let primary = Self(named: "primary")
    public static let secondary = Self(named: "secondary")
    public static let tertiary = Self(named: "tertiary")
    public static let quaternary = Self(named: "quaternary")
    public static let predefined: [Self] = [.primary, .secondary, .tertiary, .quaternary]

    private init(named value: String) { rawValue = value }
    public init() { rawValue = "group-" + UUID().uuidString.lowercased() }
    public init?(rawValue: String) {
        guard Self.predefined.contains(where: { $0.rawValue == rawValue }) ||
            (rawValue.hasPrefix("group-") && UUID(uuidString: String(rawValue.dropFirst(6)))?.uuidString.lowercased() == String(rawValue.dropFirst(6))) else { return nil }
        self.rawValue = rawValue
    }
    public var other: Self { self == .primary ? .secondary : .primary }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid editor group")
        }
        self = identifier
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
