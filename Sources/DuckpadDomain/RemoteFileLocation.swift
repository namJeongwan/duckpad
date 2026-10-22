import Foundation

/// The host is an OpenSSH destination (including aliases from ~/.ssh/config).
/// Never stores credentials. The path is an absolute path on the remote host.
public struct RemoteFileLocation: Codable, Hashable, Sendable {
    public let host: String
    public let path: String

    public init?(host: String, path: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@[]:")
        guard !host.isEmpty, host.utf8.count <= 512, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              path.hasPrefix("/"), path.utf8.count <= 16_384,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.host = host
        self.path = path
    }

    public var identifier: String {
        "ssh://" + host + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }
    public var title: String { (path as NSString).lastPathComponent + " — " + host }
}
