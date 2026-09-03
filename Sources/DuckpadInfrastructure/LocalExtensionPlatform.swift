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

    private let root: URL
    private let bundledPackages: [URL]
    private let trustedKeys: [String: TrustedPublisherKey]
    private let bundledDigestAllowlist: [ExtensionID: String]
    private let limits: ExtensionHostLimits
    private let snapshotInterposition: (@Sendable (URL) -> Void)?

    public init(root: URL, bundledPackages: [URL]? = nil, trustedKeys: [TrustedPublisherKey] = [bundledTextToolsKey], bundledDigestAllowlist: [ExtensionID: String] = [ExtensionID(rawValue: "com.duckpad.text-tools"): "ce54eed65c4707a705fb246a2bcf304be77366376147a5a17d4f1be3ad984390"], limits: ExtensionHostLimits = ExtensionHostLimits(), snapshotInterposition: (@Sendable (URL) -> Void)? = nil) {
        self.root = root.standardizedFileURL
        if let bundledPackages { self.bundledPackages = bundledPackages }
        else {
            self.bundledPackages = Bundle.module.url(forResource: "BundledExtensions", withExtension: nil).map { root in
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
        guard let manifestData = files["plugin.json"], let module = files["module.wasm"],
              let sums = files["SHA256SUMS"], let signatureData = files["SIGNATURE.ed25519"] else {
            throw ExtensionFailure.malformedManifest("missing signed package files")
        }
        guard manifestData.count <= 64 * 1_024, module.count <= limits.maximumModuleBytes,
              sums.count <= 64 * 1_024, signatureData.count <= 256 else { throw ExtensionFailure.limitExceeded("package metadata") }
        try validateManifestKeys(manifestData)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        try validate(manifest)
        guard manifest.runtime.module == "module.wasm" else { throw ExtensionFailure.invalidPackagePath }
        _ = try WasmModulePolicy.validate(module, limits: limits)
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
        let shippedURL = bundledPackages.contains { $0.standardizedFileURL.path == packageURL.standardizedFileURL.path }
        let source: LoadedExtensionPackage.TrustSource = shippedURL && bundledDigestAllowlist[manifest.id] == packageDigest
            ? .bundled : .userImported
        return LoadedExtensionPackage(manifest: manifest, module: module, packageDigest: packageDigest,
                                      publisherFingerprint: fingerprint, signatureDigest: signatureDigest,
                                      capabilitySchemaDigest: capabilitySchemaDigest, trustSource: source)
    }

    private func validate(_ manifest: ExtensionManifest) throws {
        guard manifest.schemaVersion == 1, manifest.runtime.kind == "wasm-core", manifest.runtime.abi == "duckpad-wasm-1",
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
        var result: [String: Data] = [:]
        var aggregateBytes = 0
        for name in names {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw ExtensionFailure.invalidPackagePath }
            let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard !["dylib", "so", "bundle", "exe", "sh", "command", "js"].contains(suffix) else { throw ExtensionFailure.invalidPackagePath }
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ExtensionFailure.invalidPackagePath }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= 4 * 1_024 * 1_024 else { throw ExtensionFailure.invalidPackagePath }
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
            guard aggregateBytes <= 16 * 1_024 * 1_024 - bytes.count else { throw ExtensionFailure.limitExceeded("package aggregate bytes") }
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

public actor LocalExtensionPreferenceStore: ExtensionGrantStorePort {
    private let root: URL
    private let syncDirectory: @Sendable (Int32) -> Int32
    private var lastGeneration: UInt64 = 0
    public init(root: URL, syncDirectory: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) {
        self.root = root.standardizedFileURL
        self.syncDirectory = syncDirectory
    }
    public nonisolated static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duckpad/ExtensionPolicy", isDirectory: true)
    }

    public func loadPolicy() async throws -> ExtensionPolicySnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else { return ExtensionPolicySnapshot() }
        let directory = try openRoot(create: false); defer { close(directory) }
        let descriptor = openat(directory, "policy-v1.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return ExtensionPolicySnapshot() }
        guard descriptor >= 0 else { throw ExtensionFailure.hostUnavailable("extension policy unavailable") }
        defer { close(descriptor) }
        var info = stat(); guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= 1_024 * 1_024 else {
            throw ExtensionFailure.hostUnavailable("unsafe extension policy")
        }
        let data = try readAll(descriptor, count: Int(info.st_size))
        let policy = try JSONDecoder().decode(ExtensionPolicySnapshot.self, from: data)
        guard valid(policy) else { throw ExtensionFailure.hostUnavailable("corrupt extension policy") }
        lastGeneration = policy.generation
        return policy
    }

    public func savePolicy(_ policy: ExtensionPolicySnapshot) async throws -> ExtensionPolicyCommit {
        guard valid(policy), policy.generation > lastGeneration else { throw ExtensionFailure.hostUnavailable("stale or invalid extension policy") }
        let data = try JSONEncoder().encode(policy)
        guard data.count <= 1_024 * 1_024 else { throw ExtensionFailure.limitExceeded("extension policy bytes") }
        let directory = try openRoot(create: true)
        defer { close(directory) }
        let temporary = ".policy-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ExtensionFailure.hostUnavailable("policy create failed") }
        var published = false
        defer { close(descriptor); if !published { unlinkat(directory, temporary, 0) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw ExtensionFailure.hostUnavailable("policy write failed") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ExtensionFailure.hostUnavailable("policy sync failed") }
        guard renameat(directory, temporary, directory, "policy-v1.json") == 0 else { throw ExtensionFailure.hostUnavailable("policy rename failed") }
        published = true
        // rename already published this generation. Advance the monotonic
        // guard even when directory durability cannot be proven so an
        // immediate retry cannot re-authorize the same snapshot.
        lastGeneration = policy.generation
        guard syncDirectory(directory) == 0 else { return .durabilityUncertain }
        return .committed
    }

    private func valid(_ policy: ExtensionPolicySnapshot) -> Bool {
        policy.schemaVersion == 1 && policy.enabled.count <= 64 && policy.grants.count <= 1_024 &&
        policy.revokedPublisherFingerprints.count <= 256 && policy.disabledPackageDigests.count <= 256 &&
        policy.enabled.allSatisfy { $0.rawValue.utf8.count <= 128 } &&
        policy.revokedPublisherFingerprints.allSatisfy { $0.utf8.count == 64 } &&
        policy.disabledPackageDigests.allSatisfy { $0.utf8.count == 64 } &&
        policy.grants.allSatisfy {
            $0.extensionID.rawValue.utf8.count <= 128 && $0.packageDigest.utf8.count == 64 &&
            $0.publisherFingerprint.utf8.count == 64 && $0.capabilitySchemaDigest.utf8.count == 64
        }
    }

    private func openRoot(create: Bool) throws -> Int32 {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard create, errno == ENOENT else { throw ExtensionFailure.hostUnavailable("extension preference root unavailable") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(root.path, &info) == 0 else { throw ExtensionFailure.hostUnavailable("extension preference root unavailable") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & S_IFLNK) == 0, info.st_uid == geteuid() else {
            throw ExtensionFailure.hostUnavailable("unsafe extension preference root")
        }
        guard chmod(root.path, 0o700) == 0 else { throw ExtensionFailure.hostUnavailable("extension preference permissions") }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExtensionFailure.hostUnavailable("extension preference root unavailable") }
        return descriptor
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count); var offset = 0
        while offset < count {
            let readCount = bytes.withUnsafeMutableBytes { raw in Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset) }
            guard readCount > 0 else { throw ExtensionFailure.hostUnavailable("truncated extension policy") }
            offset += readCount
        }
        return Data(bytes)
    }
}

public actor ProcessPluginHostTransport: PluginHostTransport {
    private final class TerminalArbiter: @unchecked Sendable {
        enum Cause { case completed, failed, cancelled, timedOut }
        private let lock = NSLock(); private var cause: Cause?
        func claim(_ candidate: Cause) -> Bool { lock.lock(); defer { lock.unlock() }; guard cause == nil else { return false }; cause = candidate; return true }
        func current() -> Cause? { lock.lock(); defer { lock.unlock() }; return cause }
    }
    private final class ProcessExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var exited = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markExited() {
            lock.lock()
            guard !exited else { lock.unlock(); return }
            exited = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if exited {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }
    private let executableURL: URL
    private let requestedExecutableURL: URL
    private let permitsInjectedDevelopmentHelper: Bool
    private struct ActiveHost {
        let id: UUID
        let process: Process
        let input: Pipe
        let output: Pipe
        let errors: Pipe
        let terminal: TerminalArbiter
        let exit: ProcessExitSignal
    }
    private var active: ActiveHost?

    public init(executableURL: URL, permitsInjectedDevelopmentHelper: Bool = false) {
        self.requestedExecutableURL = executableURL.standardizedFileURL
        self.executableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        self.permitsInjectedDevelopmentHelper = permitsInjectedDevelopmentHelper
    }

    public nonisolated static func siblingOfCurrentExecutable() -> URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: "/nonexistent/duckpad-app"))
            .deletingLastPathComponent().appendingPathComponent("DuckpadPluginHost")
            .resolvingSymlinksInPath().standardizedFileURL
    }

    public func invoke(_ request: ExtensionHostRequest) async throws -> ExtensionHostResponse {
        guard active == nil else { throw ExtensionFailure.hostUnavailable("plugin host is busy") }
        try validateExecutable()
        let process = Process(); let input = Pipe(); let output = Pipe(); let errors = Pipe()
        let exit = ProcessExitSignal()
        process.executableURL = executableURL; process.arguments = []
        process.environment = [:]; process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in exit.markExited() }
        do { try process.run() } catch { throw ExtensionFailure.hostUnavailable("plugin host launch failed") }
        let terminal = TerminalArbiter()
        active = ActiveHost(id: request.requestID, process: process, input: input, output: output, errors: errors, terminal: terminal, exit: exit)
        defer { if active?.id == request.requestID { active = nil } }
        let timeout = request.limits.timeoutMilliseconds
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: ExtensionHostResponse.self) { group in
                    group.addTask {
                        try input.fileHandleForWriting.write(contentsOf: PluginFrameCodec.encode(request))
                        try input.fileHandleForWriting.close()
                        async let stderr = Self.readCapped(errors.fileHandleForReading, maximum: 8 * 1_024)
                        let response = try Self.readResponse(output.fileHandleForReading)
                        await exit.wait()
                        let diagnostic = try await stderr
                        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
                            throw ExtensionFailure.hostUnavailable("plugin host exit \(process.terminationStatus): \(String(decoding: diagnostic, as: UTF8.self))")
                        }
                        guard terminal.claim(.completed) else {
                            switch terminal.current() { case .timedOut: throw ExtensionFailure.timedOut; default: throw ExtensionFailure.cancelled }
                        }
                        return response
                    }
                    group.addTask {
                        try await Task.sleep(for: .milliseconds(timeout))
                        guard terminal.claim(.timedOut) else { throw CancellationError() }
                        await Self.terminateAndReap(process: process, input: input, output: output, errors: errors, exit: exit)
                        throw ExtensionFailure.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else { throw ExtensionFailure.hostUnavailable("plugin host ended") }
                    return first
                }
            } catch let failure as ExtensionFailure {
                await Self.terminateAndReap(process: process, input: input, output: output, errors: errors, exit: exit)
                switch terminal.current() {
                case .cancelled: throw ExtensionFailure.cancelled
                case .timedOut: throw ExtensionFailure.timedOut
                default: _ = terminal.claim(.failed); throw failure
                }
            } catch {
                await Self.terminateAndReap(process: process, input: input, output: output, errors: errors, exit: exit)
                switch terminal.current() {
                case .cancelled: throw ExtensionFailure.cancelled
                case .timedOut: throw ExtensionFailure.timedOut
                default: _ = terminal.claim(.failed); throw ExtensionFailure.hostUnavailable(String(describing: error))
                }
            }
        } onCancel: {
            _ = terminal.claim(.cancelled)
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    public func cancel(requestID: UUID) async {
        guard let active, active.id == requestID else { return }
        _ = active.terminal.claim(.cancelled)
        await Self.terminateAndReap(process: active.process, input: active.input, output: active.output, errors: active.errors, exit: active.exit)
    }

    private nonisolated static func readResponse(_ handle: FileHandle) throws -> ExtensionHostResponse {
        let prefix = try readExactly(4, handle)
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= PluginFrameCodec.maximumFrameBytes else { throw ExtensionFailure.limitExceeded("IPC response") }
        var frame = prefix; frame.append(try readExactly(Int(length), handle))
        if let trailing = try handle.read(upToCount: 1), !trailing.isEmpty {
            throw ExtensionFailure.hostUnavailable("plugin host emitted trailing bytes")
        }
        return try PluginFrameCodec.decode(ExtensionHostResponse.self, from: frame)
    }

    private nonisolated static func readExactly(_ count: Int, _ handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { throw ExtensionFailure.hostUnavailable("truncated IPC response") }
            data.append(chunk)
        }
        return data
    }

    private nonisolated static func readCapped(_ handle: FileHandle, maximum: Int) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: min(4_096, maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw ExtensionFailure.limitExceeded("plugin host stderr") }
        }
        return data
    }

    private func validateExecutable() throws {
        var info = stat()
        guard lstat(requestedExecutableURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              requestedExecutableURL.resolvingSymlinksInPath().standardizedFileURL.path == executableURL.path,
              executableURL.resolvingSymlinksInPath().standardizedFileURL.path == executableURL.path else {
            throw ExtensionFailure.hostUnavailable("plugin host identity invalid")
        }
        guard permitsInjectedDevelopmentHelper || executableURL.path == Self.siblingOfCurrentExecutable().standardizedFileURL.path else {
            throw ExtensionFailure.hostUnavailable("plugin host is not the app-owned sibling")
        }
    }

    private nonisolated static func terminateAndReap(process: Process, input: Pipe, output: Pipe, errors: Pipe, exit: ProcessExitSignal) async {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        await exit.wait()
    }
}
