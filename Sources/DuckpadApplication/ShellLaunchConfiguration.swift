import Foundation

/// Session launch metadata. The terminal host currently supports /bin/zsh -l.
public struct ShellLaunchConfiguration: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL

    public init(workingDirectory: URL) {
        self.executable = URL(fileURLWithPath: "/bin/zsh")
        self.arguments = ["-l"]
        self.workingDirectory = workingDirectory
    }
}
