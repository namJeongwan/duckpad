import Foundation
import DuckpadDomain

public struct PreparedExtensionUpdate: Sendable {
    public let installationGeneration: UInt64
    public let release: ExtensionUpdate
    public let package: LoadedExtensionPackage
    public let files: [String: Data]
    public init(release: ExtensionUpdate, package: LoadedExtensionPackage, files: [String: Data], installationGeneration: UInt64 = 0) {
        self.installationGeneration = installationGeneration
        self.release = release; self.package = package; self.files = files
    }
}
