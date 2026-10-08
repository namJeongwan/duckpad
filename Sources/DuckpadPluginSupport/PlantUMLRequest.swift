import Foundation

/// A bounded rendering request, never a shell command. Source stays on this Mac.
public struct PlantUMLRequest: Codable, Sendable {
    public var source: String
    public var format: String
    public var javaPath: String?
    public var jarPath: String?
    public var install: Bool
    public init(source: String, format: String = "png", javaPath: String? = nil, jarPath: String? = nil, install: Bool = false) {
        self.source = source; self.format = format; self.javaPath = javaPath; self.jarPath = jarPath; self.install = install
    }
}
