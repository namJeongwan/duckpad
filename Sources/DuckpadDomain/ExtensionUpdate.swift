import Foundation

public struct ExtensionUpdate: Equatable, Sendable {
    public let extensionID: ExtensionID
    public let version: SemanticVersion
    public let downloadURL: URL
    public let sha256: String
    public let publisherID: String
    public let keyID: String
    public init(extensionID: ExtensionID, version: SemanticVersion, downloadURL: URL, sha256: String, publisherID: String, keyID: String) {
        self.extensionID = extensionID; self.version = version; self.downloadURL = downloadURL
        self.sha256 = sha256; self.publisherID = publisherID; self.keyID = keyID
    }
}
