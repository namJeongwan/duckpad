import DuckpadDomain
import Foundation

public struct ExtensionDiscoveryReport: Sendable {
    public let packages: [LoadedExtensionPackage]
    public let failures: [String: ExtensionFailure]
    public init(packages: [LoadedExtensionPackage], failures: [String: ExtensionFailure] = [:]) {
        self.packages = packages; self.failures = failures
    }
}

public protocol ExtensionPackageLoaderPort: Sendable {
    func discover() async -> ExtensionDiscoveryReport
}

public protocol ExtensionGrantStorePort: Sendable {
    func loadPolicy() async throws -> ExtensionPolicySnapshot
    func savePolicy(_ policy: ExtensionPolicySnapshot) async throws -> ExtensionPolicyCommit
}

public enum ExtensionPolicyCommit: Equatable, Sendable {
    case committed
    /// The rename completed, but directory durability could not be proven. The
    /// caller must discard its in-memory authority and reload fail-closed.
    case durabilityUncertain
}

public struct ExtensionHostLimits: Codable, Equatable, Sendable {
    public let maximumModuleBytes: Int
    public let maximumInputBytes: Int
    public let maximumOutputBytes: Int
    public let maximumMemoryPages: UInt32
    public let maximumTableElements: UInt32
    public let stackBytes: UInt32
    public let heapBytes: UInt32
    public let timeoutMilliseconds: UInt32

    public init(
        maximumModuleBytes: Int = 2 * 1_024 * 1_024,
        maximumInputBytes: Int = 1 * 1_024 * 1_024,
        maximumOutputBytes: Int = 2 * 1_024 * 1_024,
        maximumMemoryPages: UInt32 = 128,
        maximumTableElements: UInt32 = 1_024,
        stackBytes: UInt32 = 64 * 1_024,
        heapBytes: UInt32 = 2 * 1_024 * 1_024,
        timeoutMilliseconds: UInt32 = 1_000
    ) {
        self.maximumModuleBytes = maximumModuleBytes; self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes; self.maximumMemoryPages = maximumMemoryPages
        self.maximumTableElements = maximumTableElements; self.stackBytes = stackBytes
        self.heapBytes = heapBytes; self.timeoutMilliseconds = timeoutMilliseconds
    }

    public var isValid: Bool {
        maximumModuleBytes > 0 && maximumModuleBytes <= 16 * 1_024 * 1_024 &&
        maximumInputBytes > 0 && maximumInputBytes <= 8 * 1_024 * 1_024 &&
        maximumOutputBytes > 0 && maximumOutputBytes <= 8 * 1_024 * 1_024 &&
        maximumMemoryPages > 0 && maximumMemoryPages <= 256 &&
        maximumTableElements <= 4_096 && stackBytes >= 4_096 && stackBytes <= 1_024 * 1_024 &&
        heapBytes >= 4_096 && heapBytes <= 8 * 1_024 * 1_024 &&
        timeoutMilliseconds > 0 && timeoutMilliseconds <= 10_000
    }
}

public struct ExtensionHostRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let protocolVersion: Int
    public let module: Data
    public let context: ExtensionInvocationContext
    public let limits: ExtensionHostLimits
    public init(requestID: UUID = UUID(), protocolVersion: Int = 1, module: Data, context: ExtensionInvocationContext, limits: ExtensionHostLimits) {
        self.requestID = requestID; self.protocolVersion = protocolVersion; self.module = module; self.context = context; self.limits = limits
    }
}

public struct ExtensionHostResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let result: ExtensionCommandResult?
    public let failure: String?
    public init(protocolVersion: Int = 1, result: ExtensionCommandResult? = nil, failure: String? = nil) {
        self.protocolVersion = protocolVersion; self.result = result; self.failure = failure
    }
}

public protocol PluginHostTransport: Sendable {
    func invoke(_ request: ExtensionHostRequest) async throws -> ExtensionHostResponse
    func cancel(requestID: UUID) async
}

public struct ExtensionEditorCapture: Equatable, Sendable {
    public let tabID: TabID
    public let buffer: EditorBufferDescriptor
    public let documentByteLength: Int
    public let selection: SearchUTF8Range
    public let scopedUTF8: Data

    public init(tabID: TabID, buffer: EditorBufferDescriptor, documentByteLength: Int, selection: SearchUTF8Range, scopedUTF8: Data) {
        self.tabID = tabID; self.buffer = buffer; self.documentByteLength = documentByteLength
        self.selection = selection; self.scopedUTF8 = scopedUTF8
    }
}

@MainActor
public protocol ExtensionEditorPort: SearchEditorPort {
    /// Captures identity and only the authorized input bytes synchronously on
    /// the editor actor. Implementations must reject oversized documents before
    /// materializing a document snapshot.
    func captureExtensionInput(
        tabID: TabID,
        expectedBuffer: EditorBufferDescriptor,
        scope: ExtensionCommandContribution.InputScope,
        maximumBytes: Int
    ) throws(ExtensionFailure) -> ExtensionEditorCapture
}

public struct ExtensionRegistryItem: Equatable, Sendable {
    public let manifest: ExtensionManifest
    public let publisherFingerprint: String
    public let packageDigest: String
    public let capabilitySchemaDigest: String
    public let enabled: Bool
    public let granted: Set<ExtensionCapabilityRequest>
    public let issue: ExtensionFailure?
}

/// Immutable authority presented to a human. Consent is accepted only when
/// every package identity and capability field still matches current discovery.
public struct ExtensionConsentReviewToken: Equatable, Sendable {
    public let extensionID: ExtensionID
    public let publisherID: String
    public let publisherFingerprint: String
    public let version: SemanticVersion
    public let packageDigest: String
    public let capabilitySchemaDigest: String
    public let requests: Set<ExtensionCapabilityRequest>
    public let policyGeneration: UInt64
}

public struct ExtensionRevocationReviewToken: Equatable, Sendable {
    public let publisherID: String
    public let publisherFingerprint: String
    public let affectedPackageIdentities: [String]
    public let policyGeneration: UInt64
}

public struct ExtensionRegistryState: Equatable, Sendable {
    public let items: [ExtensionRegistryItem]
    public let discoveryFailures: [String: ExtensionFailure]
    public let operationStatus: String?
    public init(items: [ExtensionRegistryItem], discoveryFailures: [String: ExtensionFailure] = [:], operationStatus: String? = nil) {
        self.items = items; self.discoveryFailures = discoveryFailures; self.operationStatus = operationStatus
    }
}

@MainActor
public final class ExtensionWorkspaceUseCase {
    public static let apiVersion = SemanticVersion(major: 1, minor: 0, patch: 0)

    private let loader: any ExtensionPackageLoaderPort
    private let grants: any ExtensionGrantStorePort
    private let transport: any PluginHostTransport
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any ExtensionEditorPort
    private let limits: ExtensionHostLimits
    private let allowsUserExtensions: Bool
    private var packages: [ExtensionID: LoadedExtensionPackage] = [:]
    private var enabled: Set<ExtensionID> = []
    private var granted: Set<ExtensionGrant> = []
    private var policyGeneration: UInt64 = 0
    private var revokedPublisherFingerprints: Set<String> = []
    private var disabledPackageDigests: Set<String> = []
    private var discoveryFailures: [String: ExtensionFailure] = [:]
    private var invocationGeneration: UInt64 = 0
    private var invocationsSuspended = false
    private var activeRequest: (id: UUID, extensionID: ExtensionID)?
    private var invocationIdleWaiters: [CheckedContinuation<Void, Never>] = []
    /// A rename may have published authority that the process could not prove
    /// durable. Once that happens, no refresh or retry may restore user
    /// authority in this process; only a new process may load the policy.
    private var policyAuthorityRequiresRestart = false
    private var commandIndex: [ExtensionCommandID: ExtensionID] = [:]

    public var onStateChange: ((ExtensionRegistryState) -> Void)?

    public init(loader: any ExtensionPackageLoaderPort, grants: any ExtensionGrantStorePort, transport: any PluginHostTransport, workspace: ScratchWorkspaceUseCase, editor: any ExtensionEditorPort, limits: ExtensionHostLimits = ExtensionHostLimits(), allowsUserExtensions: Bool = false) {
        self.loader = loader; self.grants = grants; self.transport = transport
        self.workspace = workspace; self.editor = editor; self.limits = limits; self.allowsUserExtensions = allowsUserExtensions
    }

    public func refresh() async {
        let report = await loader.discover()
        discoveryFailures = report.failures
        var resolved: [ExtensionID: LoadedExtensionPackage] = [:]
        let permittedPackages = report.packages.filter { package in
            if package.trustSource == .bundled || allowsUserExtensions { return true }
            discoveryFailures[package.manifest.id.rawValue] = .disabled(package.manifest.id)
            return false
        }
        for (id, group) in Dictionary(grouping: permittedPackages, by: { $0.manifest.id }) {
            let compatibleAll = group.filter { $0.manifest.api.contains(Self.apiVersion) }
            let bundled = compatibleAll.filter { $0.trustSource == .bundled }
            let candidates = bundled.isEmpty ? compatibleAll : bundled
            guard Set(candidates.map(\.publisherFingerprint)).count <= 1 else {
                discoveryFailures[id.rawValue] = .duplicateIdentifier(id); continue
            }
            let compatible = candidates.sorted(by: packageOrder)
            guard let highest = compatible.first else { discoveryFailures[id.rawValue] = .unsupportedAPI; continue }
            let peers = compatible.filter { $0.manifest.version == highest.manifest.version }
            guard Set(peers.map(\.packageDigest)).count == 1 else {
                discoveryFailures[id.rawValue] = .duplicateIdentifier(id); continue
            }
            resolved[id] = highest
        }
        var malformedOwners: Set<ExtensionID> = []
        for package in resolved.values {
            let prefix = package.manifest.id.rawValue + "."
            var localCommands: Set<ExtensionCommandID> = []
            for command in package.manifest.contributes.commands {
                guard command.id.rawValue.hasPrefix(prefix), localCommands.insert(command.id).inserted else {
                    discoveryFailures[package.manifest.id.rawValue] = .malformedManifest("unowned or duplicate command ID")
                    malformedOwners.insert(package.manifest.id)
                    break
                }
            }
            guard !malformedOwners.contains(package.manifest.id) else { continue }
            var boundCommands: Set<ExtensionCommandID> = []
            var declaredKeys: Set<String> = []
            for binding in package.manifest.contributes.keybindings {
                let normalizedKey = binding.key
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard localCommands.contains(binding.command),
                      !normalizedKey.isEmpty,
                      normalizedKey == binding.key.lowercased(),
                      boundCommands.insert(binding.command).inserted,
                      declaredKeys.insert(normalizedKey).inserted else {
                    discoveryFailures[package.manifest.id.rawValue] = .malformedManifest(
                        "duplicate, unowned, or non-canonical keybinding"
                    )
                    malformedOwners.insert(package.manifest.id)
                    break
                }
            }
        }
        for owner in malformedOwners { resolved.removeValue(forKey: owner) }
        var commandOwners: [ExtensionCommandID: [ExtensionID]] = [:]
        for package in resolved.values {
            for command in package.manifest.contributes.commands { commandOwners[command.id, default: []].append(package.manifest.id) }
        }
        for (command, owners) in commandOwners where Set(owners).count > 1 {
            for owner in owners { resolved.removeValue(forKey: owner); discoveryFailures[owner.rawValue] = .malformedManifest("command collision: \(command.rawValue)") }
        }
        commandIndex = [:]
        for package in resolved.values {
            for command in package.manifest.contributes.commands { commandIndex[command.id] = package.manifest.id }
        }
        packages = resolved
        do {
            let policy = try await grants.loadPolicy()
            guard policy.schemaVersion == 1 else { throw ExtensionFailure.hostUnavailable("unsupported extension policy") }
            policyGeneration = policy.generation
            enabled = policyAuthorityRequiresRestart ? [] : policy.enabled
            granted = policyAuthorityRequiresRestart ? [] : policy.grants
            revokedPublisherFingerprints = policy.revokedPublisherFingerprints
            disabledPackageDigests = policy.disabledPackageDigests
        } catch {
            policyGeneration = 0; enabled = []; granted = []; revokedPublisherFingerprints = []; disabledPackageDigests = []
            discoveryFailures["preferences"] = .hostUnavailable("extension policy unavailable; all user extensions disabled")
        }
        if policyAuthorityRequiresRestart {
            enabled = []
            granted = []
            discoveryFailures["preferences"] = .hostUnavailable("policy durability uncertain; user extensions disabled until restart")
        }
        for package in resolved.values where package.trustSource == .bundled &&
            !revokedPublisherFingerprints.contains(package.publisherFingerprint) &&
            !disabledPackageDigests.contains(package.packageDigest) {
            enabled.insert(package.manifest.id)
            for request in package.manifest.capabilities {
                granted.insert(boundGrant(package: package, capability: request.id, scope: request.scope, generation: policyGeneration))
            }
        }
        enabled.formIntersection(resolved.keys)
        granted = granted.filter { grant in
            guard let package = resolved[grant.extensionID] else { return false }
            return grantMatchesPackage(grant, package: package) && !revokedPublisherFingerprints.contains(package.publisherFingerprint)
        }
        publish()
    }

    public func state() -> ExtensionRegistryState { makeState(status: nil) }

    public func setEnabled(_ id: ExtensionID, enabled shouldEnable: Bool) async throws(ExtensionFailure) {
        try requirePolicyAuthority()
        guard let package = packages[id] else { throw .disabled(id) }
        guard !revokedPublisherFingerprints.contains(package.publisherFingerprint) else { throw .untrustedPublisher }
        var candidateEnabled = enabled
        var candidateGrants = granted
        var candidateDisabledDigests = disabledPackageDigests
        if shouldEnable { candidateEnabled.insert(id); candidateDisabledDigests.remove(package.packageDigest) }
        else { candidateEnabled.remove(id); candidateDisabledDigests.insert(package.packageDigest); candidateGrants = candidateGrants.filter { $0.extensionID != id } }
        guard policyGeneration < .max else { throw .limitExceeded("policy generation") }
        let candidateGeneration = policyGeneration + 1
        do {
            try await persist(ExtensionPolicySnapshot(
                generation: candidateGeneration, enabled: candidateEnabled, grants: candidateGrants,
                revokedPublisherFingerprints: revokedPublisherFingerprints, disabledPackageDigests: candidateDisabledDigests
            ))
        } catch let failure as ExtensionFailure { throw failure }
        catch { throw .hostUnavailable("could not persist extension preference") }
        enabled = candidateEnabled; granted = candidateGrants; disabledPackageDigests = candidateDisabledDigests; policyGeneration = candidateGeneration
        if !shouldEnable { await cancelActiveRequest(ifOwnedBy: [id]) }
        publish()
    }

    public func consentReviewToken(for extensionID: ExtensionID) throws(ExtensionFailure) -> ExtensionConsentReviewToken {
        try requirePolicyAuthority()
        guard let package = packages[extensionID], enabled.contains(extensionID) else { throw .disabled(extensionID) }
        guard !revokedPublisherFingerprints.contains(package.publisherFingerprint) else { throw .untrustedPublisher }
        return ExtensionConsentReviewToken(
            extensionID: extensionID, publisherID: package.manifest.publisher.id,
            publisherFingerprint: package.publisherFingerprint, version: package.manifest.version,
            packageDigest: package.packageDigest, capabilitySchemaDigest: package.capabilitySchemaDigest,
            requests: Set(package.manifest.capabilities), policyGeneration: policyGeneration
        )
    }

    public func grantReviewed(_ token: ExtensionConsentReviewToken, choices: Set<ExtensionCapabilityRequest>) async throws(ExtensionFailure) {
        try requirePolicyAuthority()
        guard let package = packages[token.extensionID], enabled.contains(token.extensionID),
              !revokedPublisherFingerprints.contains(package.publisherFingerprint),
              token.publisherID == package.manifest.publisher.id,
              token.publisherFingerprint == package.publisherFingerprint,
              token.version == package.manifest.version,
              token.packageDigest == package.packageDigest,
              token.capabilitySchemaDigest == package.capabilitySchemaDigest,
              token.requests == Set(package.manifest.capabilities), token.policyGeneration == policyGeneration,
              choices.isSubset(of: token.requests) else { throw .staleContext }
        guard policyGeneration < .max else { throw .limitExceeded("policy generation") }
        let next = policyGeneration + 1
        var candidate = granted.filter { $0.extensionID != token.extensionID }
        for choice in choices {
            candidate.insert(boundGrant(package: package, capability: choice.id, scope: choice.scope, generation: next))
        }
        do { try await persist(ExtensionPolicySnapshot(generation: next, enabled: enabled, grants: candidate, revokedPublisherFingerprints: revokedPublisherFingerprints, disabledPackageDigests: disabledPackageDigests)) }
        catch let failure as ExtensionFailure { throw failure }
        catch { throw .hostUnavailable("could not persist reviewed grants") }
        granted = candidate; policyGeneration = next
        await cancelActiveRequest(ifOwnedBy: [token.extensionID])
        publish()
    }

    /// Publisher revocation is a durable tombstone. It cannot be undone through
    /// the grant UI and also cancels an invocation from that publisher.
    public func revocationReviewToken(for extensionID: ExtensionID) throws(ExtensionFailure) -> ExtensionRevocationReviewToken {
        try requirePolicyAuthority()
        guard let package = packages[extensionID] else { throw .disabled(extensionID) }
        return ExtensionRevocationReviewToken(
            publisherID: package.manifest.publisher.id, publisherFingerprint: package.publisherFingerprint,
            affectedPackageIdentities: packageIdentities(for: package.publisherFingerprint), policyGeneration: policyGeneration
        )
    }

    public func revokePublisher(_ token: ExtensionRevocationReviewToken) async throws(ExtensionFailure) {
        try requirePolicyAuthority()
        guard token.policyGeneration == policyGeneration,
              token.affectedPackageIdentities == packageIdentities(for: token.publisherFingerprint),
              packages.values.contains(where: { $0.publisherFingerprint == token.publisherFingerprint && $0.manifest.publisher.id == token.publisherID }) else {
            throw .staleContext
        }
        guard policyGeneration < .max else { throw .limitExceeded("policy generation") }
        let next = policyGeneration + 1
        var revoked = revokedPublisherFingerprints; revoked.insert(token.publisherFingerprint)
        let publisherIDs = Set(packages.values.filter { $0.publisherFingerprint == token.publisherFingerprint }.map(\.manifest.id))
        var candidateEnabled = enabled; candidateEnabled.subtract(publisherIDs)
        let candidateGrants = granted.filter { $0.publisherFingerprint != token.publisherFingerprint }
        do { try await persist(ExtensionPolicySnapshot(generation: next, enabled: candidateEnabled, grants: candidateGrants, revokedPublisherFingerprints: revoked, disabledPackageDigests: disabledPackageDigests)) }
        catch let failure as ExtensionFailure { throw failure }
        catch { throw .hostUnavailable("could not persist publisher revocation") }
        revokedPublisherFingerprints = revoked; enabled = candidateEnabled; granted = candidateGrants; policyGeneration = next
        await cancelActiveRequest(ifOwnedBy: publisherIDs)
        publish()
    }

    public func resetPublisherRevocation(for extensionID: ExtensionID) async throws(ExtensionFailure) {
        try requirePolicyAuthority()
        guard let package = packages[extensionID], revokedPublisherFingerprints.contains(package.publisherFingerprint) else { throw .staleContext }
        guard policyGeneration < .max else { throw .limitExceeded("policy generation") }
        let next = policyGeneration + 1
        var revoked = revokedPublisherFingerprints; revoked.remove(package.publisherFingerprint)
        var disabled = disabledPackageDigests
        for value in packages.values where value.publisherFingerprint == package.publisherFingerprint { disabled.insert(value.packageDigest) }
        do { try await persist(ExtensionPolicySnapshot(generation: next, enabled: enabled, grants: granted, revokedPublisherFingerprints: revoked, disabledPackageDigests: disabled)) }
        catch let failure as ExtensionFailure { throw failure }
        catch { throw .hostUnavailable("could not persist revocation reset") }
        revokedPublisherFingerprints = revoked; disabledPackageDigests = disabled; policyGeneration = next
        publish(status: "Publisher revocation reset. Extension remains disabled; enable and review capabilities again.")
    }

    public func invoke(_ commandID: ExtensionCommandID) async throws(ExtensionFailure) -> ExtensionCommandResult {
        guard !invocationsSuspended else { throw .cancelled }
        guard activeRequest == nil else { throw .busy }
        guard invocationGeneration < .max else { throw .limitExceeded("invocation generation") }
        invocationGeneration += 1
        let generation = invocationGeneration
        guard limits.isValid else { throw .limitExceeded("invalid host limits") }
        guard let (package, command) = command(commandID) else { throw .unknownCommand(commandID) }
        if policyAuthorityRequiresRestart, package.trustSource != .bundled { throw policyRestartFailure }
        guard enabled.contains(package.manifest.id) else { throw .disabled(package.manifest.id) }
        guard !revokedPublisherFingerprints.contains(package.publisherFingerprint) else { throw .untrustedPublisher }
        let requiredScope: ExtensionCapabilityScope = command.inputScope == .selection ? .selection : .activeDocument
        try require(.documentsRead, scope: requiredScope, package: package)
        guard let tab = workspace.snapshot().tabs.first(where: \.isActive) else { throw .staleContext }
        let capture = try editor.captureExtensionInput(
            tabID: tab.id, expectedBuffer: tab.buffer,
            scope: command.inputScope, maximumBytes: limits.maximumInputBytes
        )
        guard capture.tabID == tab.id, capture.buffer == tab.buffer,
              workspace.snapshot().tabs.first(where: \.isActive)?.buffer == tab.buffer else { throw .staleContext }
        let context = ExtensionInvocationContext(
            extensionID: package.manifest.id, commandID: command.id, operation: command.operation,
            inputScope: command.inputScope,
            tabID: tab.id, bufferID: tab.buffer.bufferID, revision: tab.buffer.revision,
            selection: ExtensionUTF8Range(location: capture.selection.location, length: capture.selection.length),
            utf8: capture.scopedUTF8
        )
        let request = ExtensionHostRequest(module: package.module, context: context, limits: limits)
        activeRequest = (request.requestID, package.manifest.id)
        defer { finishInvocation(requestID: request.requestID) }
        let response: ExtensionHostResponse
        do { response = try await transport.invoke(request) }
        catch let failure as ExtensionFailure {
            if generation != invocationGeneration || Task.isCancelled { throw .cancelled }
            throw failure
        }
        catch is CancellationError { throw .cancelled }
        catch {
            if generation != invocationGeneration || Task.isCancelled { throw .cancelled }
            throw .hostUnavailable(String(describing: error))
        }
        guard !Task.isCancelled else { throw .cancelled }
        guard generation == invocationGeneration else { throw .cancelled }
        guard response.protocolVersion == 1, response.failure == nil, let result = response.result else {
            throw .hostUnavailable(response.failure ?? "invalid host protocol")
        }
        if !result.edits.isEmpty { try require(.documentsWrite, scope: requiredScope, package: package) }
        try validate(result: result, context: context, capture: capture)
        guard !result.edits.isEmpty else { publish(status: result.status); return result }
        guard let reservation = await workspace.reserveEditorBatch(
            bufferID: context.bufferID, expectedRevision: context.revision, editCount: result.edits.count
        ) else { throw .staleContext }
        var reservationOutstanding = true
        defer { if reservationOutstanding { workspace.cancelEditorBatch(reservation) } }
        guard !Task.isCancelled, generation == invocationGeneration,
              activeRequest?.id == request.requestID,
              enabled.contains(package.manifest.id),
              !revokedPublisherFingerprints.contains(package.publisherFingerprint),
              packages[package.manifest.id] == package else { throw .cancelled }
        try require(.documentsRead, scope: requiredScope, package: package)
        try require(.documentsWrite, scope: requiredScope, package: package)
        let replacements = result.edits.sorted {
            if $0.range.location != $1.range.location { return $0.range.location > $1.range.location }
            return $0.range.length > $1.range.length
        }.map {
            SearchReplacementEdit(range: SearchUTF8Range(location: $0.range.location, length: $0.range.length), replacementUTF8: $0.replacementUTF8)
        }
        let outcome = editor.replaceActiveBatch(replacements, expectedRevision: context.revision) { [workspace] edits in
            workspace.commitEditorBatch(reservation, edits: edits)
        }
        guard case .accepted = outcome else {
            throw .staleContext
        }
        reservationOutstanding = false
        publish(status: result.status)
        return result
    }

    public func cancelInvocation() async {
        if invocationGeneration < .max { invocationGeneration += 1 }
        if let activeRequest { await transport.cancel(requestID: activeRequest.id) }
    }

    /// Atomically closes the admission gate before joining an active request.
    /// Termination callers must keep it closed through their final flush.
    public func suspendInvocationsAndWait() async {
        invocationsSuspended = true
        await cancelInvocationAndWait()
    }

    public func resumeInvocations() {
        invocationsSuspended = false
    }

    /// Prevents any late host response from crossing a termination/recovery
    /// boundary. The method returns only after transport teardown and the
    /// invocation's defer path have both completed.
    public func cancelInvocationAndWait() async {
        if invocationGeneration < .max { invocationGeneration += 1 }
        guard let requestID = activeRequest?.id else { return }
        await transport.cancel(requestID: requestID)
        guard activeRequest?.id == requestID else { return }
        await withCheckedContinuation { continuation in
            invocationIdleWaiters.append(continuation)
        }
    }

    private func command(_ id: ExtensionCommandID) -> (LoadedExtensionPackage, ExtensionCommandContribution)? {
        guard let owner = commandIndex[id], let package = packages[owner],
              let command = package.manifest.contributes.commands.first(where: { $0.id == id }) else { return nil }
        return (package, command)
    }

    private func require(_ capability: ExtensionCapability, scope: ExtensionCapabilityScope, package: LoadedExtensionPackage) throws(ExtensionFailure) {
        guard !revokedPublisherFingerprints.contains(package.publisherFingerprint),
              package.manifest.capabilities.contains(where: { $0.id == capability && $0.scope == scope }),
              granted.contains(where: { $0.extensionID == package.manifest.id && $0.capability == capability && $0.scope == scope && grantMatchesPackage($0, package: package) }) else {
            throw .permissionDenied(capability)
        }
    }

    private func validate(result: ExtensionCommandResult, context: ExtensionInvocationContext, capture: ExtensionEditorCapture) throws(ExtensionFailure) {
        guard result.edits.count <= 10_000, (result.status?.utf8.count ?? 0) <= 4_096 else { throw .limitExceeded("result") }
        if context.inputScope == .selection, !result.edits.isEmpty {
            guard result.edits.count == 1, result.edits[0].range == context.selection else {
                throw .invalidResult("selection transform must return exactly one edit equal to the captured selection")
            }
        }
        var priorEnd = -1
        var priorStart: Int?
        var replacementBytes = 0
        for edit in result.edits.sorted(by: { $0.range.location < $1.range.location }) {
            let range = SearchUTF8Range(location: edit.range.location, length: edit.range.length)
            let validRange: Bool
            switch context.inputScope {
            case .selection:
                validRange = range == SearchUTF8Range(location: capture.selection.location, length: capture.selection.length)
            case .document:
                validRange = valid(range: range, in: capture.scopedUTF8)
            }
            guard validRange, edit.range.location >= priorEnd,
                  edit.range.location != priorStart,
                  String(data: edit.replacementUTF8, encoding: .utf8) != nil else { throw .invalidResult("overlapping or invalid UTF-8 edit") }
            priorEnd = edit.range.location + edit.range.length
            priorStart = edit.range.location
            replacementBytes += edit.replacementUTF8.count
            guard replacementBytes <= limits.maximumOutputBytes else { throw .limitExceeded("replacement output") }
        }
        let active = workspace.snapshot().tabs.first(where: \.isActive)
        guard active?.id == context.tabID, active?.buffer == EditorBufferDescriptor(bufferID: context.bufferID, revision: context.revision) else { throw .staleContext }
    }

    private func valid(range: SearchUTF8Range, in bytes: Data) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location <= bytes.count,
              range.length <= bytes.count - range.location else { return false }
        return isBoundary(range.location, bytes) && isBoundary(range.location + range.length, bytes)
    }

    private func isBoundary(_ offset: Int, _ bytes: Data) -> Bool {
        offset == 0 || offset == bytes.count || (bytes[offset] & 0xC0) != 0x80
    }

    private func packageOrder(_ lhs: LoadedExtensionPackage, _ rhs: LoadedExtensionPackage) -> Bool {
        if lhs.manifest.id != rhs.manifest.id { return lhs.manifest.id < rhs.manifest.id }
        if lhs.manifest.version != rhs.manifest.version { return lhs.manifest.version > rhs.manifest.version }
        return lhs.packageDigest < rhs.packageDigest
    }

    private func boundGrant(package: LoadedExtensionPackage, capability: ExtensionCapability, scope: ExtensionCapabilityScope, generation: UInt64) -> ExtensionGrant {
        ExtensionGrant(extensionID: package.manifest.id, capability: capability, scope: scope,
                       packageDigest: package.packageDigest, publisherFingerprint: package.publisherFingerprint,
                       version: package.manifest.version, capabilitySchemaDigest: package.capabilitySchemaDigest, generation: generation)
    }

    private func grantMatchesPackage(_ grant: ExtensionGrant, package: LoadedExtensionPackage) -> Bool {
        grant.packageDigest == package.packageDigest && grant.publisherFingerprint == package.publisherFingerprint &&
        grant.version == package.manifest.version && grant.capabilitySchemaDigest == package.capabilitySchemaDigest
    }

    private func packageIdentities(for fingerprint: String) -> [String] {
        packages.values.filter { $0.publisherFingerprint == fingerprint }.map {
            "\($0.manifest.id.rawValue)@\($0.manifest.version)#\($0.packageDigest)"
        }.sorted()
    }

    private func cancelActiveRequest(ifOwnedBy owners: Set<ExtensionID>) async {
        guard let activeRequest, owners.contains(activeRequest.extensionID) else { return }
        if invocationGeneration < .max { invocationGeneration += 1 }
        await transport.cancel(requestID: activeRequest.id)
    }

    private func finishInvocation(requestID: UUID) {
        guard activeRequest?.id == requestID else { return }
        activeRequest = nil
        let waiters = invocationIdleWaiters
        invocationIdleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    private var policyRestartFailure: ExtensionFailure {
        .hostUnavailable("extension policy durability uncertain; restart required")
    }

    private func requirePolicyAuthority() throws(ExtensionFailure) {
        guard !policyAuthorityRequiresRestart else { throw policyRestartFailure }
    }

    private func makeState(status: String?) -> ExtensionRegistryState {
        let items = packages.values.sorted(by: packageOrder).map { package in
            ExtensionRegistryItem(
                manifest: package.manifest, publisherFingerprint: package.publisherFingerprint,
                packageDigest: package.packageDigest, capabilitySchemaDigest: package.capabilitySchemaDigest,
                enabled: enabled.contains(package.manifest.id),
                granted: Set(granted.filter { $0.extensionID == package.manifest.id }.map { ExtensionCapabilityRequest(id: $0.capability, scope: $0.scope) }),
                issue: revokedPublisherFingerprints.contains(package.publisherFingerprint) ? .untrustedPublisher : nil
            )
        }
        return ExtensionRegistryState(items: items, discoveryFailures: discoveryFailures, operationStatus: status)
    }

    private func publish(status: String? = nil) { onStateChange?(makeState(status: status)) }

    private func persist(_ snapshot: ExtensionPolicySnapshot) async throws {
        switch try await grants.savePolicy(snapshot) {
        case .committed: return
        case .durabilityUncertain:
            policyAuthorityRequiresRestart = true
            enabled = packages.values.filter { $0.trustSource == .bundled }.map(\.manifest.id).reduce(into: Set<ExtensionID>()) { $0.insert($1) }
            granted = []; discoveryFailures["preferences"] = .hostUnavailable("policy durability uncertain; user extensions disabled until restart")
            publish()
            throw ExtensionFailure.hostUnavailable("extension policy durability uncertain")
        }
    }
}
