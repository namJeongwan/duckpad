import DuckpadInfrastructure
import Foundation
import Testing

@Test func terminalCommandInstallationIsExecutableIdempotentAndPreservesShellSettings() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-cli-\(UUID())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let profile = home.appendingPathComponent(".zprofile")
    try Data("export EDITOR=vim".utf8).write(to: profile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.path)
    try Data("export DUCKPAD_PREVIOUS_PROFILE=preserved\n".utf8).write(to: home.appendingPathComponent(".profile"))
    let app = home.appendingPathComponent("Duck's Pad.app")
    let installer = TerminalCommandInstaller(home: home, app: app)
    try installer.install()
    let command = home.appendingPathComponent(".local/bin/duckpad")
    #expect(FileManager.default.isExecutableFile(atPath: command.path))
    guard FileManager.default.fileExists(atPath: command.path) else { return }
    let originalProfile = try Data(contentsOf: profile)
    #expect(String(decoding: originalProfile, as: UTF8.self).hasPrefix("export EDITOR=vim\n"))
    try installer.install()
    #expect(try Data(contentsOf: profile) == originalProfile)
    #expect((try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    for shell in ["/bin/zsh", "/bin/bash"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "export PATH=/usr/bin:/bin; . \"$HOME/" + (shell.hasSuffix("zsh") ? ".zprofile" : ".bash_profile") + "\"; " + (shell.hasSuffix("bash") ? "test \"$DUCKPAD_PREVIOUS_PROFILE\" = preserved || exit 1; " : "") + "command -v duckpad"]
        process.environment = ["HOME": home.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == command.path + "\n")
    }

    let syntax = Process()
    syntax.executableURL = URL(fileURLWithPath: "/bin/sh")
    syntax.arguments = ["-n", command.path]
    try syntax.run()
    syntax.waitUntilExit()
    #expect(syntax.terminationStatus == 0)

    let movedApp = home.appendingPathComponent("Moved Duckpad.app")
    try TerminalCommandInstaller(home: home, app: movedApp).install()
    let launch = Process()
    launch.executableURL = command
    let errors = Pipe()
    launch.standardError = errors
    try launch.run()
    launch.waitUntilExit()
    #expect(launch.terminationStatus != 0)
    #expect(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(movedApp.path))
    #expect(try Data(contentsOf: profile) == originalProfile)
}

@Test func terminalCommandInstallationDoesNotOverwriteAnExistingCommandOrSymlink() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-cli-conflict-\(UUID())")
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let command = bin.appendingPathComponent("duckpad")
    let existing = Data("#!/bin/sh\necho custom\n".utf8)
    try existing.write(to: command)
    let installer = TerminalCommandInstaller(home: home, app: home.appendingPathComponent("Duckpad.app"))
    #expect(throws: (any Error).self) { try installer.install() }
    #expect(try Data(contentsOf: command) == existing)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zprofile").path))

    try FileManager.default.removeItem(at: command)
    let target = home.appendingPathComponent("custom-command")
    try existing.write(to: target)
    try FileManager.default.createSymbolicLink(at: command, withDestinationURL: target)
    #expect(throws: (any Error).self) { try installer.install() }
    #expect(try Data(contentsOf: target) == existing)
}

@Test func terminalCommandRegistrationKeepsAnExistingCommandOnPATH() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-cli-path-\(UUID())")
    let bin = home.appendingPathComponent("previous-bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let previous = bin.appendingPathComponent("duckpad")
    try Data("#!/bin/sh\nprintf 'previous command\\n'\n".utf8).write(to: previous)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: previous.path)
    try TerminalCommandInstaller(home: home, app: home.appendingPathComponent("Duckpad.app")).install()
    for (shell, profile) in [("/bin/zsh", ".zprofile"), ("/bin/bash", ".bash_profile")] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", ". \"$HOME/\(profile)\"; duckpad"]
        process.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "previous command\n")
    }
}
