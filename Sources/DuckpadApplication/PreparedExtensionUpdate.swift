import Foundation
import DuckpadDomain

public struct PreparedExtensionUpdate: Sendable {
    public let release: ExtensionUpdate
    public let package: LoadedExtensionPackage
    public let files: [String: Data]
    public init(release: ExtensionUpdate, package: LoadedExtensionPackage, files: [String: Data]) {
        self.release = release; self.package = package; self.files = files
    }
}
