import Foundation

/// Bounded diagram source and runtime selection; no command or argument input.
public struct D2Request: Codable, Sendable {
    public static let maximumFrameBytes = 4 * 1024 * 1024
    public let source: String
    public let executablePath: String?
    public let install: Bool
    public let dark: Bool
    public init(source: String, executablePath: String? = nil, install: Bool = false, dark: Bool = false) {
        self.source = source; self.executablePath = executablePath; self.install = install; self.dark = dark
    }
}
