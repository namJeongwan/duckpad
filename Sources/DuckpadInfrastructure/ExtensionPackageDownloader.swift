import Foundation
import CryptoKit
import DuckpadDomain

public struct ExtensionPackageDownloader: Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }
    public func download(_ update: ExtensionUpdate) async throws -> [String: Data] {
        guard update.downloadURL.scheme == "https", update.downloadURL.host == "github.com" else { throw ExtensionFailure.invalidPackagePath }
        let (stream, response) = try await session.bytes(from: update.downloadURL)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https",
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(response.url?.host ?? ""),
              response.expectedContentLength <= ExtensionPackageArchive.maximumBytes else { throw ExtensionFailure.hostUnavailable("plugin download failed") }
        var data = Data()
        data.reserveCapacity(max(0, Int(response.expectedContentLength)))
        for try await byte in stream {
            guard data.count < ExtensionPackageArchive.maximumBytes else { throw ExtensionFailure.limitExceeded("plugin archive") }
            data.append(byte)
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == update.sha256 else { throw ExtensionFailure.signatureMismatch }
        return try ExtensionPackageArchive.decode(data)
    }
}
