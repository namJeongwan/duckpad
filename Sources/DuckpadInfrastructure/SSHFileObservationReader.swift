import DuckpadApplication
import DuckpadDomain
import Foundation

public struct SSHFileObservationReader: FileObservationReading {
    private let executable: URL
    private let configuration: URL?
    private let pool: SSHConnectionPool?
    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), configuration: URL? = nil, pool: SSHConnectionPool? = nil) {
        self.executable = executable; self.configuration = configuration; self.pool = pool
    }

    public func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        guard case .ssh(let remote) = source,
              RemoteFileLocation(host: remote.host, path: remote.path) != nil,
              maximumBytes > 0, maximumBytes <= 4 * 1_024 * 1_024 else { throw FileObservationError.invalidResponse }
        if let pool {
            let bytes = try await pool.execute(host: remote.host, configuration: configuration,
                command: Self.shellCommand(remote: remote, cursor: cursor, maximumBytes: maximumBytes), maximumOutput: maximumBytes + 512)
            return try Self.parse(bytes, maximumBytes: maximumBytes)
        }
        let process = SSHReadProcess()
        let arguments = (configuration.map { ["-F", $0.path] } ?? []) + ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                         "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                         "--", remote.host, Self.shellCommand(remote: remote, cursor: cursor, maximumBytes: maximumBytes)]
        let executable = executable
        let worker = Task.detached(priority: .utility) {
            try process.run(executable: executable, arguments: arguments, maximumOutput: maximumBytes + 512)
        }
        let bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: { process.cancel(); worker.cancel() }
        try Task.checkCancellation()
        return try Self.parse(bytes, maximumBytes: maximumBytes)
    }

    static func shellCommand(remote: RemoteFileLocation, cursor: FileObservationCursor?, maximumBytes: Int) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // Open once and stat/read that descriptor, so replacement of the path
        // cannot pair bytes from a new inode with metadata from the old inode.
        let script = """
        LC_ALL=C; export LC_ALL
        exec 3< \(quote(remote.path)) || exit 1
        [ -f /dev/fd/3 ] || exit 1
        m=$(stat -Lc '%d:%i %s' /dev/fd/3 2>/dev/null) || m=$(stat -Lf '%d:%i %z' /dev/fd/3 2>/dev/null) || exit 1
        set -- $m
        id=$1; size=$2; offset=\(cursor?.offset ?? 0); reset=0
        if [ \(cursor == nil ? "0" : "1") = 1 ] && { [ "$id" != \(quote(cursor?.identity ?? "")) ] || [ "$offset" -gt "$size" ]; }; then offset=0; reset=1; fi
        printf 'DUCKPAD1 %s %s %s %s\\n' "$id" "$size" "$offset" "$reset"
        count=$((size - offset)); [ "$count" -le \(maximumBytes) ] || count=\(maximumBytes)
        [ "$count" -gt 0 ] || exit 0
        tail -c +$((offset + 1)) <&3 | head -c "$count"
        """
        // sshd invokes the account's login shell. In zsh, `$m` does not
        // undergo POSIX word splitting; run the protocol explicitly in sh.
        return "/bin/sh -c " + quote(script)
    }

    static func parse(_ data: Data, maximumBytes: Int) throws -> FileObservationRead {
        guard let newline = data.firstIndex(of: 10), newline < 256,
              let header = String(data: data.prefix(upTo: newline), encoding: .ascii) else { throw FileObservationError.invalidResponse }
        let fields = header.split(separator: " ")
        guard fields.count == 5, fields[0] == "DUCKPAD1", fields[1].split(separator: ":").count == 2,
              fields[1].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":") }),
              let size = UInt64(fields[2]), let offset = UInt64(fields[3]), offset <= size,
              fields[4] == "0" || fields[4] == "1" else { throw FileObservationError.invalidResponse }
        let payload = Data(data.suffix(from: data.index(after: newline)))
        guard payload.count <= maximumBytes, UInt64(payload.count) <= size - offset else { throw FileObservationError.invalidResponse }
        return .init(data: payload, cursor: .init(identity: String(fields[1]), offset: offset + UInt64(payload.count)),
                     sourceSize: size, reset: fields[4] == "1")
    }
}
