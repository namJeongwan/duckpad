import Foundation
import DuckpadApplication
import DuckpadDomain

public actor ExtensionUpdateInstaller {
    private var removalEpoch: UInt64 = 0
    private let loader: LocalExtensionPackageLoader
    private let catalog = ExtensionUpdateCatalogClient()
    private let downloader = ExtensionPackageDownloader()
    private let nativeStore: ManagedNativePackageStore
    private let nativeInstaller: @Sendable ([String: Data]) async throws -> Void
    public init(loader: LocalExtensionPackageLoader, nativeStore: ManagedNativePackageStore = ManagedNativePackageStore(root: ManagedNativePackageStore.appRoot()), nativeInstaller: @escaping @Sendable ([String: Data]) async throws -> Void = { try await NativeInstallerClient().install(files: $0) }) {
        self.loader = loader; self.nativeStore = nativeStore; self.nativeInstaller = nativeInstaller
    }
    public func availablePlugins() async throws -> ExtensionCatalogSnapshot {
        try await catalog.availablePlugins(hostAPI: ExtensionWorkspaceUseCase.apiVersion)
    }
    public func check(_ items: [ExtensionRegistryItem]) async throws -> [ExtensionID: ExtensionUpdate] {
        var updates: [ExtensionID: ExtensionUpdate] = [:]
        guard items.contains(where: { $0.issue == nil }) else { return updates }
        let indexed = Set(try await catalog.pluginIDs())
        for item in items where item.issue == nil && indexed.contains(item.manifest.id) {
            try Task.checkCancellation()
            if let update = try await catalog.latestUpdate(id: item.manifest.id, installedVersion: item.pendingVersion ?? item.manifest.version,
                hostAPI: ExtensionWorkspaceUseCase.apiVersion, publisherID: item.manifest.publisher.id, publisherFingerprint: item.publisherFingerprint) {
                updates[item.manifest.id] = update
            }
        }
        return updates
    }
    public func prepare(_ update: ExtensionUpdate, publisherFingerprint: String) async throws -> PreparedExtensionUpdate {
        let generation = try await loader.installationGeneration(for: update.extensionID)
        let files = try await downloader.download(update)
        return try await prepare(update, files: files, publisherFingerprint: publisherFingerprint, generation: generation)
    }
    public func prepare(_ update: ExtensionUpdate, files: [String: Data], publisherFingerprint: String) async throws -> PreparedExtensionUpdate {
        let generation = try await loader.installationGeneration(for: update.extensionID)
        return try await prepare(update, files: files, publisherFingerprint: publisherFingerprint, generation: generation)
    }
    private func prepare(_ update: ExtensionUpdate, files: [String: Data], publisherFingerprint: String, generation: UInt64) async throws -> PreparedExtensionUpdate {
        let package = try await loader.verify(files: files)
        if package.nativeFiles != nil, !NativeModuleCompatibility.supportsCurrentProcess(package.module) { throw ExtensionFailure.hostUnavailable("native module architecture mismatch") }
        guard package.manifest.id == update.extensionID, package.manifest.version == update.version,
              package.manifest.publisher.id == update.publisherID, package.manifest.publisher.keyID == update.keyID,
              package.publisherFingerprint == publisherFingerprint,
              package.manifest.api.contains(ExtensionWorkspaceUseCase.apiVersion) else { throw ExtensionFailure.signatureMismatch }
        return PreparedExtensionUpdate(release: update, package: package, files: files, installationGeneration: generation)
    }
    public func install(_ prepared: PreparedExtensionUpdate) async throws {
        let verified = try await loader.verify(files: prepared.files)
        guard verified == prepared.package else { throw ExtensionFailure.signatureMismatch }
        try await install(files: prepared.files, package: verified, generation: prepared.installationGeneration)
    }
    @discardableResult public func installPackage(at source: URL) async throws -> ExtensionID {
        let epoch = removalEpoch
        let (package, files) = try await loader.readPackage(at: source)
        guard removalEpoch == epoch else { throw ExtensionFailure.staleContext }
        let generation = try await loader.installationGeneration(for: package.manifest.id)
        guard removalEpoch == epoch else { throw ExtensionFailure.staleContext }
        try await install(files: files, package: package, generation: generation)
        return package.manifest.id
    }
    public func uninstall(_ item: ExtensionRegistryItem, stop: @Sendable () async throws -> Void) async throws {
        guard !item.isBundled else { throw ExtensionFailure.invalidPackagePath }
        removalEpoch &+= 1
        try await loader.beginRemoval(item.manifest.id)
        do {
            try await stop()
            let digests = try await loader.uninstall(item.manifest.id, publisherFingerprint: item.publisherFingerprint)
            try await nativeStore.remove(digests: digests)
            await loader.endRemoval(item.manifest.id)
        } catch {
            await loader.endRemoval(item.manifest.id)
            throw error
        }
    }
    private func install(files: [String: Data], package: LoadedExtensionPackage, generation: UInt64) async throws {
        guard try await loader.installationGeneration(for: package.manifest.id) == generation else { throw ExtensionFailure.staleContext }
        guard package.manifest.api.contains(ExtensionWorkspaceUseCase.apiVersion) else { throw ExtensionFailure.unsupportedAPI }
        if package.manifest.runtime.kind == "native" {
            guard NativeModuleCompatibility.supportsCurrentProcess(package.module) else { throw ExtensionFailure.hostUnavailable("native module architecture mismatch") }
            try await nativeInstaller(files)
        }
        try Task.checkCancellation()
        _ = try await loader.install(files: files, expectedGeneration: generation)
    }
}
