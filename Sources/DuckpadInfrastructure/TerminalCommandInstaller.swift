import Foundation

public struct TerminalCommandInstaller: Sendable {
    private let home: URL
    private let app: URL

    public init(home: URL, app: URL) {
        self.home = home
        self.app = app
    }

    public func install() throws {
        let files = FileManager.default
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let command = bin.appendingPathComponent("duckpad")
        let header = "#!/bin/sh\n# Duckpad managed terminal command\n"
        if let attributes = try? files.attributesOfItem(atPath: command.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  try String(contentsOf: command, encoding: .utf8).hasPrefix(header) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let quotedApp = "'" + app.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = Data((header + "exec /usr/bin/open -a \(quotedApp) -- \"$@\"\n").utf8)
        if (try? Data(contentsOf: command)) != script {
            try script.write(to: command, options: .atomic)
        }
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)

        let pathBlock = """
        # Duckpad terminal command
        case ":$PATH:" in
            *":$HOME/.local/bin:"*) ;;
            *) export PATH="$PATH:$HOME/.local/bin" ;;
        esac

        """
        for name in [".zprofile", ".bash_profile"] {
            let profile = home.appendingPathComponent(name)
            let existing: String
            if files.fileExists(atPath: profile.path) {
                existing = try String(contentsOf: profile, encoding: .utf8)
            } else {
                existing = name == ".bash_profile" ? """
                if [ -f "$HOME/.bash_login" ]; then
                    . "$HOME/.bash_login"
                elif [ -f "$HOME/.profile" ]; then
                    . "$HOME/.profile"
                fi

                """ : ""
            }
            guard !existing.contains(pathBlock) else { continue }
            let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + pathBlock
            if files.fileExists(atPath: profile.path) {
                let handle = try FileHandle(forWritingTo: profile)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(addition.utf8))
            } else {
                try Data((existing + addition).utf8).write(to: profile, options: .withoutOverwriting)
            }
        }
    }
}
