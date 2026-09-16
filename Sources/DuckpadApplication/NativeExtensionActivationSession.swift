import DuckpadDomain

/// Shared by all windows for one app process. Native images can outlive their
/// instances, so disabling a plugin must not admit another version in that process.
@MainActor
public final class NativeExtensionActivationSession {
    private struct Identity: Equatable {
        let digest: String
        let publisher: String
        let version: SemanticVersion
        let trust: LoadedExtensionPackage.TrustSource

        init(_ package: LoadedExtensionPackage) {
            digest = package.packageDigest
            publisher = package.publisherFingerprint
            version = package.manifest.version
            trust = package.trustSource
        }
    }

    private var removing: Set<ExtensionID> = []
    func beginRemoval(_ id: ExtensionID) -> Bool { removing.insert(id).inserted }
    func endRemoval(_ id: ExtensionID) { removing.remove(id) }
    func isRemoving(_ id: ExtensionID) -> Bool { removing.contains(id) }

    private var selected: [ExtensionID: Identity] = [:]

    public init() {}

    func select(latest: LoadedExtensionPackage, verifiedCandidates: [LoadedExtensionPackage]) -> LoadedExtensionPackage? {
        let id = latest.manifest.id
        if let identity = selected[id] {
            // Do not keep serving a cached snapshot after its installed package
            // disappears or fails verification, and do not substitute new code.
            return verifiedCandidates.first {
                $0.manifest.id == id && Identity($0) == identity
            }
        }
        if latest.manifest.runtime.kind == "native" {
            selected[id] = Identity(latest)
        }
        return latest
    }
}
