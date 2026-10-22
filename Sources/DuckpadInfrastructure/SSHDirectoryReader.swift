import DuckpadApplication
import DuckpadDomain
import Foundation

public struct SSHDirectoryReader: Sendable {
    private let pool: SSHConnectionPool
    private let configuration: URL?
    public init(pool: SSHConnectionPool, configuration: URL? = nil) { self.pool = pool; self.configuration = configuration }
    public func list(host: String, path: String?) async throws -> RemoteDirectoryListing {
        guard RemoteFileLocation(host: host, path: path ?? "/") != nil else { throw FileObservationError.invalidResponse }
        let data = try await pool.execute(host: host, configuration: configuration,
            command: Self.command(path: path), maximumOutput: 2 * 1_024 * 1_024)
        return try Self.parse(data)
    }
    static func command(path: String?) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        LC_ALL=C; export LC_ALL
        cd -P \(path.map(quote) ?? "\"$HOME\"") 2>/dev/null || { printf 'DUCKPADDIRERROR1\\000'; exit 0; }
        printf 'DUCKPADDIR1\\000%s\\000' "$PWD"
        count=0
        for name in .[!.]* ..?* *; do
            [ -e "$name" ] || [ -L "$name" ] || continue
            if [ "$count" -ge 5000 ]; then printf 'T\\000'; exit 0; fi
            kind=F; [ ! -d "$name" ] || kind=D
            printf '%s\\000%s\\000' "$kind" "$name"
            count=$((count + 1))
        done
        printf 'E\\000'
        """
        return "/bin/sh -c " + quote(script)
    }
    static func parse(_ data: Data) throws -> RemoteDirectoryListing {
        // A remote shell reporting a bad directory proves the SSH transport
        // worked. Do not classify it as a connection failure and reconnect.
        if data == Data("DUCKPADDIRERROR1\0".utf8) { throw FileObservationError.directoryUnavailable }
        guard data.count <= 2 * 1_024 * 1_024, data.last == 0 else { throw FileObservationError.invalidResponse }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 4, String(data: fields[0], encoding: .utf8) == "DUCKPADDIR1",
              let path = String(data: fields[1], encoding: .utf8), RemoteFileLocation(host: "fixture", path: path) != nil else { throw FileObservationError.invalidResponse }
        var entries = [RemoteDirectoryEntry](), index = 2
        while index < fields.count - 2 {
            guard fields[index] == Data("D".utf8) || fields[index] == Data("F".utf8), index + 1 < fields.count - 2 else { throw FileObservationError.invalidResponse }
            if let name = String(data: fields[index + 1], encoding: .utf8), !name.isEmpty, name != ".", name != "..",
               !name.contains("/"), RemoteFileLocation(host: "fixture", path: "/" + name) != nil {
                entries.append(.init(name: name, isDirectory: fields[index] == Data("D".utf8)))
            }
            index += 2
        }
        guard index == fields.count - 2, fields[index] == Data("E".utf8) || fields[index] == Data("T".utf8), entries.count <= 5_000 else { throw FileObservationError.invalidResponse }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return .init(path: path, entries: entries, isTruncated: fields[index] == Data("T".utf8))
    }
}
