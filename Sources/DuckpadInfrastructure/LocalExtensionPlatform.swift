import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadPluginSupport
import Foundation

public actor LocalExtensionPackageLoader: ExtensionPackageLoaderPort {
    public struct TrustedPublisherKey: Sendable {
        public let publisherID: String
        public let keyID: String
        public let publicKey: Data
        public let source: LoadedExtensionPackage.TrustSource
        public init(publisherID: String, keyID: String, publicKey: Data, source: LoadedExtensionPackage.TrustSource) {
            self.publisherID = publisherID; self.keyID = keyID; self.publicKey = publicKey; self.source = source
        }
    }

    public static let bundledTextToolsKey = TrustedPublisherKey(
        publisherID: "com.duckpad", keyID: "release-sample-1",
        publicKey: Data(base64Encoded: "4pf5NP1voP8k8NDDZEQ58lGM5D1xJlHh15QUO0jFSos=")!, source: .bundled
    )

    /// Clipboard releases have their own persistent publisher key. The bundled
    /// text-tools identity and digest allowlist remain unchanged.
    public static let clipboardPublisherKey = TrustedPublisherKey(
        publisherID: "com.duckpad", keyID: "clipboard-release-1",
        publicKey: Data(base64Encoded: "WlOI4aUUE1yhCuLzGBpcklFSUDTxp+Smn07d2RQ2idE=")!, source: .userImported
    )

    private var installGenerations: [ExtensionID: UInt64] = [:]
    private var removing: Set<ExtensionID> = []
    private let root: URL
    private let bundledPackages: [URL]
    private let trustedKeys: [String: TrustedPublisherKey]
    private let bundledDigestAllowlist: [ExtensionID: String]
    private let limits: ExtensionHostLimits
    private let snapshotInterposition: (@Sendable (URL) -> Void)?

    public init(root: URL, bundledPackages: [URL]? = nil, trustedKeys: [TrustedPublisherKey] = [bundledTextToolsKey, clipboardPublisherKey], bundledDigestAllowlist: [ExtensionID: String] = [ExtensionID(rawValue: "com.duckpad.text-tools"): "ce54eed65c4707a705fb246a2bcf304be77366376147a5a17d4f1be3ad984390"], limits: ExtensionHostLimits = ExtensionHostLimits(), snapshotInterposition: (@Sendable (URL) -> Void)? = nil) {
        self.root = root.standardizedFileURL
        if let bundledPackages { self.bundledPackages = bundledPackages }
        else {
            self.bundledPackages = DuckpadInfrastructureResources.bundle.url(
                forResource: "BundledExtensions",
                withExtension: nil
            ).map { root in
                [root.appendingPathComponent("com.duckpad.text-tools.duckpad-plugin", isDirectory: true)]
            } ?? []
        }
        self.trustedKeys = Dictionary(uniqueKeysWithValues: trustedKeys.map { ("\($0.publisherID)#\($0.keyID)", $0) })
        self.bundledDigestAllowlist = bundledDigestAllowlist
        self.limits = limits
        self.snapshotInterposition = snapshotInterposition
    }

    public nonisolated static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duckpad/Extensions", isDirectory: true)
    }

    public func install(from source: URL) throws {
        guard source.pathExtension == "duckpad-plugin" else { throw ExtensionFailure.invalidPackagePath }
        let package = try load(source)
        _ = try installationGeneration(for: package.manifest.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard try regularDirectory(root) else { throw ExtensionFailure.invalidPackagePath }
        let staging = root.appendingPathComponent(".install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("package.duckpad-plugin")
        try FileManager.default.copyItem(at: source, to: temporary)
        guard try load(temporary).packageDigest == package.packageDigest else { throw ExtensionFailure.signatureMismatch }
        let destination = root.appendingPathComponent("\(package.manifest.id.rawValue)@\(package.manifest.version).duckpad-plugin")
        // An existing version is immutable. New versions install alongside it.
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ExtensionFailure.hostUnavailable("plugin version is already installed or destination is unavailable")
        }
    }

    public func installationGeneration(for id: ExtensionID) throws -> UInt64 {
        guard !removing.contains(id) else { throw ExtensionFailure.staleContext }
        return installGenerations[id, default: 0]
    }
    public func beginRemoval(_ id: ExtensionID) throws {
        guard !removing.contains(id), installGenerations[id, default: 0] < UInt64.max else { throw ExtensionFailure.staleContext }
        installGenerations[id, default: 0] += 1
        removing.insert(id)
    }
    public func endRemoval(_ id: ExtensionID) { removing.remove(id) }

    /// Runs without suspension so publication cannot interleave with removal.
    /// Only verified packages inside the user installation root are removed.
    public func uninstall(_ id: ExtensionID, publisherFingerprint: String) throws -> Set<String> {
        guard removing.contains(id), id.rawValue.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9-]+)+$"#, options: .regularExpression) != nil else { throw ExtensionFailure.invalidPackagePath }
        for url in bundledPackages {
            if try load(url).manifest.id == id { throw ExtensionFailure.invalidPackagePath }
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard try regularDirectory(root), root.resolvingSymlinksInPath().path == root.path else { throw ExtensionFailure.invalidPackagePath }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "duckpad-plugin" }
        var targets: [(URL, LoadedExtensionPackage)] = []
        for url in urls {
            let package: LoadedExtensionPackage
            do { package = try load(url) }
            catch {
                // Do not touch unrelated broken packages. A broken canonical
                // version of this plugin must not be reported as removed.
                if url.lastPathComponent.hasPrefix(id.rawValue + "@") { throw error }
                continue
            }
            guard package.manifest.id == id else { continue }
            guard package.publisherFingerprint == publisherFingerprint else { throw ExtensionFailure.signatureMismatch }
            targets.append((url, package))
        }
        let staging = root.appendingPathComponent(".uninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var moved: [(URL, URL)] = []
        do {
            for (source, package) in targets {
                let destination = staging.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                moved.append((source, destination))
                // Reverify the moved snapshot before deleting it, in case a
                // filesystem change raced the initial discovery.
                let movedPackage = try load(destination)
                guard movedPackage.packageDigest == package.packageDigest,
                      movedPackage.publisherFingerprint == package.publisherFingerprint else { throw ExtensionFailure.signatureMismatch }
            }
        } catch {
            for (source, destination) in moved.reversed() { try? FileManager.default.moveItem(at: destination, to: source) }
            throw error
        }
        try FileManager.default.removeItem(at: staging)
        return Set(targets.filter { $0.1.nativeFiles != nil }.map { $0.1.packageDigest })
    }

    public func discover() async -> ExtensionDiscoveryReport {
        var urls = bundledPackages
        var failures: [String: ExtensionFailure] = [:]
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                guard try regularDirectory(root) else { throw ExtensionFailure.invalidPackagePath }
                let values = try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                ).filter { $0.pathExtension == "duckpad-plugin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard values.count <= 64 else { throw ExtensionFailure.limitExceeded("extension package count") }
                urls.append(contentsOf: values)
            }
        } catch let failure as ExtensionFailure { failures[root.path] = failure }
        catch { failures[root.path] = .invalidPackagePath }

        var packages: [LoadedExtensionPackage] = []
        for url in urls {
            do { packages.append(try load(url)) }
            catch let failure as ExtensionFailure { failures[url.lastPathComponent] = failure }
            catch { failures[url.lastPathComponent] = .malformedManifest(String(describing: error)) }
        }
        return ExtensionDiscoveryReport(packages: packages, failures: failures)
    }

    private func load(_ packageURL: URL) throws -> LoadedExtensionPackage {
        guard packageURL.pathExtension == "duckpad-plugin", try regularDirectory(packageURL) else { throw ExtensionFailure.invalidPackagePath }
        let packageRoot = packageURL.resolvingSymlinksInPath().standardizedFileURL
        guard packageRoot.path == packageURL.standardizedFileURL.path else { throw ExtensionFailure.invalidPackagePath }
        let files = try snapshotPackage(packageRoot)
        return try verify(files: files, sourceURL: packageURL)
    }

    public func readPackage(at url: URL) throws -> (LoadedExtensionPackage, [String: Data]) {
        let files = try snapshotPackage(url)
        return (try verify(files: files), files)
    }

    public func verify(files: [String: Data]) throws -> LoadedExtensionPackage {
        try verify(files: files, sourceURL: nil)
    }

    private func verify(files: [String: Data], sourceURL: URL?) throws -> LoadedExtensionPackage {
        let nativeFiles = files["module.dylib"] != nil
        guard files.count <= 64,
              files.values.allSatisfy({ $0.count <= (nativeFiles ? 16 : 4) * 1_024 * 1_024 }),
              files.values.reduce(0, { $0 + $1.count }) <= (nativeFiles ? 32 : 16) * 1_024 * 1_024,
              files.keys.allSatisfy({ name in
                  !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && name.utf8.count <= 255 &&
                  !["so", "bundle", "exe", "sh", "command", "js"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
              }) else { throw ExtensionFailure.invalidPackagePath }
        guard let manifestData = files["plugin.json"],
              let sums = files["SHA256SUMS"], let signatureData = files["SIGNATURE.ed25519"] else {
            throw ExtensionFailure.malformedManifest("missing signed package files")
        }
        guard manifestData.count <= 64 * 1_024,
              sums.count <= 64 * 1_024, signatureData.count <= 256 else { throw ExtensionFailure.limitExceeded("package metadata") }
        try validateManifestKeys(manifestData)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        try validate(manifest)
        let native = manifest.runtime.kind == "native"
        guard let module = files[manifest.runtime.module] else { throw ExtensionFailure.invalidPackagePath }
        if native {
            guard module.count <= 16 * 1_024 * 1_024 else { throw ExtensionFailure.limitExceeded("native module") }
            // Mach-O signatures are also enforced by macOS at dlopen time.
            guard module.count >= 4, [[0xcf,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca]].contains(Array(module.prefix(4))) else {
                throw ExtensionFailure.malformedManifest("native module is not Mach-O")
            }
        } else {
            guard module.count <= limits.maximumModuleBytes else { throw ExtensionFailure.limitExceeded("WASM module") }
            guard !files.keys.contains(where: { $0.hasSuffix(".dylib") }) else { throw ExtensionFailure.invalidPackagePath }
            _ = try WasmModulePolicy.validate(module, limits: limits)
        }
        guard String(data: sums, encoding: .utf8) != nil else { throw ExtensionFailure.signatureMismatch }
        try validateChecksums(sums, files: files)
        let signatureText = String(decoding: signatureData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let key = trustedKeys["\(manifest.publisher.id)#\(manifest.publisher.keyID)"] else {
            throw ExtensionFailure.untrustedPublisher
        }
        var signed = Data("duckpad-extension-signature-v1\n".utf8); signed.append(sums)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
        guard publicKey.isValidSignature(signature, for: signed) else { throw ExtensionFailure.signatureMismatch }
        let fingerprint = SHA256.hash(data: key.publicKey).map { String(format: "%02x", $0) }.joined()
        let signatureDigest = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
        let packageDigest = SHA256.hash(data: sums).map { String(format: "%02x", $0) }.joined()
        let capabilitySchemaDigest = capabilityDigest(manifest.capabilities)
        let shippedURL = sourceURL.map { source in bundledPackages.contains { $0.standardizedFileURL.path == source.standardizedFileURL.path } } ?? false
        let source: LoadedExtensionPackage.TrustSource = shippedURL && bundledDigestAllowlist[manifest.id] == packageDigest
            ? .bundled : .userImported
        return LoadedExtensionPackage(manifest: manifest, module: module, packageDigest: packageDigest,
                                      publisherFingerprint: fingerprint, signatureDigest: signatureDigest,
                                      capabilitySchemaDigest: capabilitySchemaDigest, trustSource: source, nativeFiles: native ? files : nil)
    }

    /// Publishes a verified snapshot, preserving every existing version.
    public func install(files: [String: Data], expectedGeneration: UInt64? = nil) throws -> LoadedExtensionPackage {
        let package = try verify(files: files)
        let generation = try installationGeneration(for: package.manifest.id)
        guard expectedGeneration == nil || expectedGeneration == generation else { throw ExtensionFailure.staleContext }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try regularDirectory(root) else { throw ExtensionFailure.invalidPackagePath }
        let destination = root.appendingPathComponent("\(package.manifest.id.rawValue)@\(package.manifest.version).duckpad-plugin")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try load(destination).packageDigest == package.packageDigest else { throw ExtensionFailure.signatureMismatch }
            return package
        }
        let staging = root.appendingPathComponent(".install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        for (name, data) in files { try data.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting) }
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw ExtensionFailure.hostUnavailable("could not publish plugin version") }
        return package
    }

    private func validate(_ manifest: ExtensionManifest) throws {
        let wasm = manifest.runtime.kind == "wasm-core" && manifest.runtime.abi == "duckpad-wasm-1" && manifest.runtime.module == "module.wasm"
        let native = manifest.runtime.kind == "native" && manifest.runtime.abi == "duckpad-native-1" && manifest.runtime.module == "module.dylib"
            && manifest.capabilities.contains(.init(id: .nativeCode, scope: .application))
            && manifest.contributes.commands.allSatisfy { $0.inputScope == .service }
        guard manifest.schemaVersion == 1, wasm || native,
              manifest.id.rawValue.utf8.count <= 128, manifest.name.utf8.count <= 128,
              manifest.publisher.id.utf8.count <= 128, manifest.publisher.keyID.utf8.count <= 128,
              manifest.id.rawValue.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9-]+)+$"#, options: .regularExpression) != nil,
              manifest.capabilities.count <= 16, manifest.contributes.commands.count <= 128,
              manifest.contributes.keybindings.count <= 128, manifest.contributes.snippets.count <= 256,
              manifest.contributes.themes.count <= 32, manifest.contributes.languages.count <= 64,
              Set(manifest.capabilities).count == manifest.capabilities.count,
              Set(manifest.contributes.commands.map(\.id)).count == manifest.contributes.commands.count else {
            throw ExtensionFailure.malformedManifest("invalid manifest identity, runtime, or limits")
        }
        let prefix = manifest.id.rawValue + "."
        guard manifest.contributes.commands.allSatisfy({ $0.id.rawValue.hasPrefix(prefix) && $0.id.rawValue.utf8.count <= 192 && !$0.title.isEmpty && $0.title.utf8.count <= 128 }),
              manifest.contributes.keybindings.allSatisfy({ binding in binding.key.utf8.count <= 64 && manifest.contributes.commands.contains(where: { $0.id == binding.command }) }),
              manifest.contributes.snippets.allSatisfy({ $0.language.utf8.count <= 64 && $0.prefix.utf8.count <= 128 && $0.body.utf8.count <= 16 * 1_024 }),
              manifest.contributes.themes.allSatisfy({ $0.id.utf8.count <= 128 && $0.label.utf8.count <= 128 }),
              manifest.contributes.languages.allSatisfy({ $0.id.utf8.count <= 128 && $0.extensions.count <= 128 && $0.extensions.allSatisfy { $0.utf8.count <= 32 } }) else {
            throw ExtensionFailure.malformedManifest("unowned command or keybinding")
        }
    }

    private func validateManifestKeys(_ data: Data) throws {
        try rejectDuplicateJSONKeys(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ExtensionFailure.malformedManifest("manifest is not an object") }
        try exactKeys(object, ["schemaVersion", "id", "name", "version", "api", "publisher", "runtime", "capabilities", "contributes"])
        try exactKeys(object["version"] as? [String: Any], ["major", "minor", "patch"])
        try exactKeys(object["api"] as? [String: Any], ["minimum", "maximumExclusive"])
        if let api = object["api"] as? [String: Any] {
            try exactKeys(api["minimum"] as? [String: Any], ["major", "minor", "patch"])
            try exactKeys(api["maximumExclusive"] as? [String: Any], ["major", "minor", "patch"])
        }
        try exactKeys(object["publisher"] as? [String: Any], ["id", "keyID"])
        try exactKeys(object["runtime"] as? [String: Any], ["kind", "module", "abi"])
        for value in object["capabilities"] as? [[String: Any]] ?? [] { try exactKeys(value, ["id", "scope"]) }
        guard let contributions = object["contributes"] as? [String: Any] else { throw ExtensionFailure.malformedManifest("invalid contributions") }
        try exactKeys(contributions, ["commands", "keybindings", "snippets", "themes", "languages"])
        for value in contributions["commands"] as? [[String: Any]] ?? [] { try exactKeys(value, ["id", "title", "operation", "inputScope"]) }
        for value in contributions["keybindings"] as? [[String: Any]] ?? [] { try exactKeys(value, ["command", "key"]) }
        for value in contributions["snippets"] as? [[String: Any]] ?? [] { try exactKeys(value, ["language", "prefix", "body"]) }
        for value in contributions["themes"] as? [[String: Any]] ?? [] { try exactKeys(value, ["id", "label"]) }
        for value in contributions["languages"] as? [[String: Any]] ?? [] { try exactKeys(value, ["id", "extensions"]) }
    }

    private func exactKeys(_ object: [String: Any]?, _ expected: Set<String>) throws {
        guard let object, Set(object.keys) == expected else { throw ExtensionFailure.malformedManifest("unknown or missing nested manifest keys") }
    }

    private func rejectDuplicateJSONKeys(_ data: Data) throws {
        enum Container { case object(Set<String>), array }
        let bytes = [UInt8](data); var stack: [Container] = []; var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: stack.append(.object([])); index += 1
            case 0x5B: stack.append(.array); index += 1
            case 0x7D, 0x5D: guard !stack.isEmpty else { throw ExtensionFailure.malformedManifest("invalid JSON nesting") }; stack.removeLast(); index += 1
            case 0x22:
                let start = index; index += 1; var escaped = false
                while index < bytes.count {
                    let byte = bytes[index]
                    if escaped { escaped = false; index += 1; continue }
                    if byte == 0x5C { escaped = true; index += 1; continue }
                    if byte == 0x22 { index += 1; break }
                    index += 1
                }
                guard index <= bytes.count else { throw ExtensionFailure.malformedManifest("unterminated JSON string") }
                var lookahead = index
                while lookahead < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[lookahead]) { lookahead += 1 }
                if lookahead < bytes.count, bytes[lookahead] == 0x3A, case .object(var keys)? = stack.last {
                    let encoded = Data(bytes[start..<index]); let decoded = try JSONDecoder().decode(String.self, from: encoded)
                    guard keys.insert(decoded).inserted else { throw ExtensionFailure.malformedManifest("duplicate JSON key: \(decoded)") }
                    stack[stack.count - 1] = .object(keys)
                }
            default: index += 1
            }
        }
        guard stack.isEmpty else { throw ExtensionFailure.malformedManifest("invalid JSON nesting") }
    }

    private func validateChecksums(_ data: Data, files: [String: Data]) throws {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let expectedNames = files.keys.filter { $0 != "SHA256SUMS" && $0 != "SIGNATURE.ed25519" }.sorted()
        guard lines.count == expectedNames.count else { throw ExtensionFailure.signatureMismatch }
        var seen: [String] = []
        for line in lines {
            let pieces = line.split(separator: " ", omittingEmptySubsequences: true)
            guard pieces.count == 2, pieces[0].count == 64 else { throw ExtensionFailure.signatureMismatch }
            let name = String(pieces[1]); guard let bytes = files[name] else { throw ExtensionFailure.signatureMismatch }
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard actual == pieces[0].lowercased() else { throw ExtensionFailure.signatureMismatch }
            seen.append(name)
        }
        guard seen == expectedNames else { throw ExtensionFailure.signatureMismatch }
    }

    private func capabilityDigest(_ requests: [ExtensionCapabilityRequest]) -> String {
        var data = Data()
        for value in requests.map({ "\($0.id.rawValue)\u{0}\($0.scope.rawValue)" }).sorted() {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            data.append(Data(bytes: &count, count: 4)); data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func regularDirectory(_ url: URL) throws -> Bool {
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw ExtensionFailure.invalidPackagePath }
        return (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & S_IFLNK) == 0
    }

    private func snapshotPackage(_ root: URL) throws -> [String: Data] {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ExtensionFailure.invalidPackagePath }
        defer { close(directory) }
        var before = stat(); guard fstat(directory, &before) == 0, (before.st_mode & S_IFMT) == S_IFDIR else { throw ExtensionFailure.invalidPackagePath }
        let names = try directoryNames(descriptor: directory)
        snapshotInterposition?(root)
        guard names.count <= 64 else { throw ExtensionFailure.limitExceeded("package file count") }
        let nativePackage = names.contains("module.dylib")
        let fileLimit = (nativePackage ? 16 : 4) * 1_024 * 1_024
        let aggregateLimit = (nativePackage ? 32 : 16) * 1_024 * 1_024
        var result: [String: Data] = [:]
        var aggregateBytes = 0
        for name in names {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw ExtensionFailure.invalidPackagePath }
            let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard !["so", "bundle", "exe", "sh", "command", "js"].contains(suffix) else { throw ExtensionFailure.invalidPackagePath }
            // Reject special files without waiting for a FIFO writer before fstat.
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw ExtensionFailure.invalidPackagePath }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= fileLimit else { throw ExtensionFailure.invalidPackagePath }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size)); var offset = 0
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let count = bytes.withUnsafeMutableBytes { raw in read(descriptor, raw.baseAddress!.advanced(by: offset), remaining) }
                guard count > 0 else { throw ExtensionFailure.invalidPackagePath }
                offset += count
            }
            var after = stat(); guard fstat(descriptor, &after) == 0,
                  after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                  after.st_size == info.st_size else { throw ExtensionFailure.invalidPackagePath }
            guard aggregateBytes <= aggregateLimit - bytes.count else { throw ExtensionFailure.limitExceeded("package aggregate bytes") }
            aggregateBytes += bytes.count
            result[name] = Data(bytes)
        }
        var pathInfo = stat(); var afterDirectory = stat()
        guard lstat(root.path, &pathInfo) == 0, fstat(directory, &afterDirectory) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFDIR,
              pathInfo.st_dev == before.st_dev, pathInfo.st_ino == before.st_ino,
              afterDirectory.st_dev == before.st_dev, afterDirectory.st_ino == before.st_ino else {
            throw ExtensionFailure.invalidPackagePath
        }
        return result
    }

    private func directoryNames(descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw ExtensionFailure.invalidPackagePath }
        defer { closedir(stream) }
        var names: [String] = []
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }
}
