import CryptoKit
import Foundation
import DuckpadDomain

/// Catalog metadata advertises releases; it never grants trust to a new publisher.
/// The downloaded package must still pass the installer's signature verification.
public struct ExtensionUpdateCatalogClient: Sendable {
    public enum Failure: Error { case unexpectedResponse, invalidCatalog, publisherMismatch }
    private struct Entry: Decodable {
        struct Publisher: Decodable {
            struct Key: Decodable { let id: String; let publicKey: String }
            let id: String; let keys: [Key]
        }
        struct Release: Decodable {
            struct API: Decodable { let minimum: String; let maximumExclusive: String }
            let version: String; let api: API; let url: String; let sha256: String; let keyID: String
        }
        let schemaVersion: Int; let id: String; let repository: String
        let publisher: Publisher; let releases: [Release]
    }
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }
    public func latestUpdate(id: ExtensionID, installedVersion: SemanticVersion, hostAPI: SemanticVersion, publisherID: String, publisherFingerprint: String) async throws -> ExtensionUpdate? {
        guard id.rawValue.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9-]+)+$"#, options: .regularExpression) != nil else { throw Failure.invalidCatalog }
        let url = URL(string: "https://raw.githubusercontent.com/namJeongwan/duckpad-plugins/main/plugins/")!.appendingPathComponent(id.rawValue + ".json")
        let (data, status) = try await fetch(url)
        return try Self.decode(data, statusCode: status, id: id, installedVersion: installedVersion, hostAPI: hostAPI, publisherID: publisherID, publisherFingerprint: publisherFingerprint)
    }

    public func pluginIDs() async throws -> [ExtensionID] {
        let url = URL(string: "https://raw.githubusercontent.com/namJeongwan/duckpad-plugins/main/index.json")!
        let (data, status) = try await fetch(url)
        return try ExtensionCatalogIndex.decode(data, statusCode: status)
    }

    private func fetch(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Duckpad-Plugin-Update-Check", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.unexpectedResponse }
        guard response.expectedContentLength <= 1_048_576 else { throw Failure.invalidCatalog }
        var data = Data()
        for try await byte in stream {
            guard data.count < 1_048_576 else { throw Failure.invalidCatalog }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
    private static func safePath(_ url: URL) -> Bool {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return false }
        return path.split(separator: "/").allSatisfy { component in
            guard let value = String(component).removingPercentEncoding else { return false }
            return value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
        }
    }
    static func decode(_ data: Data, statusCode: Int, id: ExtensionID, installedVersion: SemanticVersion, hostAPI: SemanticVersion, publisherID: String, publisherFingerprint: String) throws -> ExtensionUpdate? {
        if statusCode == 404 { return nil }
        guard statusCode == 200 else { throw Failure.unexpectedResponse }
        guard data.count <= 1_048_576 else { throw Failure.invalidCatalog }
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        guard entry.schemaVersion == 1, entry.id == id.rawValue, entry.releases.count <= 1_024,
              entry.repository.range(of: #"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw Failure.invalidCatalog }
        guard entry.publisher.id == publisherID else { throw Failure.publisherMismatch }
        var matchingKeys: Set<String> = []
        var keyIDs: Set<String> = []
        for key in entry.publisher.keys {
            guard keyIDs.insert(key.id).inserted, let bytes = Data(base64Encoded: key.publicKey), bytes.count == 32 else { throw Failure.invalidCatalog }
            let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if fingerprint == publisherFingerprint { matchingKeys.insert(key.id) }
        }
        guard !matchingKeys.isEmpty else { throw Failure.publisherMismatch }
        var versions: Set<SemanticVersion> = []
        var updates: [ExtensionUpdate] = []
        for release in entry.releases {
            guard let version = SemanticVersion(release.version), version.description == release.version,
                  versions.insert(version).inserted,
                  let minimum = SemanticVersion(release.api.minimum), minimum.description == release.api.minimum,
                  let maximum = SemanticVersion(release.api.maximumExclusive), maximum.description == release.api.maximumExclusive,
                  minimum < maximum, keyIDs.contains(release.keyID),
                  release.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let url = URL(string: release.url), url.scheme == "https", url.host == "github.com",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  release.url.hasPrefix(entry.repository + "/releases/download/v" + release.version + "/"),
                  url.pathExtension == "zip", !url.pathComponents.contains(".."),
                  safePath(url), !release.url.contains("\\") else { throw Failure.invalidCatalog }
            if version > installedVersion, minimum <= hostAPI, hostAPI < maximum, matchingKeys.contains(release.keyID) {
                updates.append(ExtensionUpdate(extensionID: id, version: version, downloadURL: url, sha256: release.sha256, publisherID: publisherID, keyID: release.keyID))
            }
        }
        return updates.max { $0.version < $1.version }
    }
}
