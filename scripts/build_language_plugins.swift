#!/usr/bin/env swift
import Foundation
import CryptoKit
import Darwin

// Verify by default. Signing explicitly requires an external 0600 seed.
let args = Array(CommandLine.arguments.dropFirst())
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let keyIndex = args.firstIndex(of: "--signing-seed")
let signingURL = keyIndex.flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
let publicURL = root.appendingPathComponent("LanguagePlugins/publisher.public")
let privateKey: Curve25519.Signing.PrivateKey?
if let signingURL {
    guard !signingURL.path.hasPrefix(root.path + "/") else { fatalError("Private signing seed must be outside the worktree") }
    if args.contains("--create-key"), !FileManager.default.fileExists(atPath: signingURL.path) {
        try FileManager.default.createDirectory(at: signingURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        let descriptor = open(signingURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { fatalError("Cannot create signing seed") }
        let written = seed.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor); close(descriptor)
        guard written == seed.count, synced == 0 else { fatalError("Cannot persist signing seed") }
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: signingURL.path)
    guard (attributes[.posixPermissions] as? Int) == 0o600 else { fatalError("Signing seed must be mode 0600") }
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: signingURL))
    if FileManager.default.fileExists(atPath: publicURL.path) {
        let previous = try String(contentsOf: publicURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard previous == privateKey!.publicKey.rawRepresentation.base64EncodedString() else { fatalError("Publisher identity must not change") }
    } else { try (privateKey!.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: publicURL, atomically: true, encoding: .utf8) }
} else { privateKey = nil }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: String(contentsOf: publicURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!)
for package in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("LanguagePlugins"), includingPropertiesForKeys: nil).filter({ $0.pathExtension == "duckpad-plugin" }).sorted(by: { $0.path < $1.path }) {
    let entries = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: [.isSymbolicLinkKey])
    let allowed: Set<String> = ["plugin.json", "SHA256SUMS", "SIGNATURE.ed25519"]
    guard Set(entries.map(\.lastPathComponent)).isSubset(of: allowed),
          try entries.allSatisfy({ try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true }) else { fatalError("Unexpected package payload") }
    let manifest = try Data(contentsOf: package.appendingPathComponent("plugin.json"))
    let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
    let sums = Data("\(digest)  plugin.json\n".utf8)
    var signed = Data("duckpad-extension-signature-v1\n".utf8); signed.append(sums)
    if let privateKey {
        try sums.write(to: package.appendingPathComponent("SHA256SUMS"))
        try (privateKey.signature(for: signed).base64EncodedString() + "\n").write(to: package.appendingPathComponent("SIGNATURE.ed25519"), atomically: true, encoding: .utf8)
    }
    guard try Data(contentsOf: package.appendingPathComponent("SHA256SUMS")) == sums,
          publicKey.isValidSignature(Data(base64Encoded: try String(contentsOf: package.appendingPathComponent("SIGNATURE.ed25519"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!, for: signed) else { fatalError("Language package integrity failed") }
    print("Verified \(package.lastPathComponent)")
}
print("Publisher public key: \(publicKey.rawRepresentation.base64EncodedString())")
