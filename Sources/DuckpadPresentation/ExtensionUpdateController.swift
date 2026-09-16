import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

@MainActor final class ExtensionUpdateController {
    typealias Check = @Sendable ([ExtensionRegistryItem]) async throws -> [ExtensionID: ExtensionUpdate]
    typealias Prepare = @Sendable (ExtensionUpdate, String) async throws -> PreparedExtensionUpdate
    typealias Install = @Sendable (PreparedExtensionUpdate) async throws -> Void
    private let useCase: ExtensionWorkspaceUseCase
    private let panel: ExtensionsManagerPanel
    private let check: Check
    private let prepare: Prepare
    private let install: Install
    private let onError: (Error) -> Void
    private var updates: [ExtensionID: ExtensionUpdate] = [:]
    private var lastCheck = Date.distantPast
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var statusKey = ""
    private var checkGeneration = UUID()

    init(useCase: ExtensionWorkspaceUseCase, panel: ExtensionsManagerPanel, check: @escaping Check,
         prepare: @escaping Prepare, install: @escaping Install, onError: @escaping (Error) -> Void) {
        self.useCase = useCase; self.panel = panel; self.check = check; self.prepare = prepare; self.install = install; self.onError = onError
        panel.onCheckUpdates = { [weak self] in self?.checkNow() }
        panel.onUpdate = { [weak self] item, release in self?.update(item, release: release) }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6 * 60 * 60)) } catch { return }
                self?.checkNow()
            }
        }
        registryChanged(useCase.state())
    }
    deinit { checkTask?.cancel(); installTask?.cancel(); timer?.cancel() }

    func registryChanged(_ state: ExtensionRegistryState) {
        updates = updates.filter { id, update in state.items.contains { $0.manifest.id == id && $0.issue == nil && ($0.pendingVersion ?? $0.manifest.version) < update.version } }
        render()
        if !state.items.isEmpty, Date().timeIntervalSince(lastCheck) >= 6 * 60 * 60 { checkNow() }
    }
    private func render() { panel.renderUpdates(updates, checking: checkTask != nil, installing: installTask != nil, statusKey: statusKey) }

    func checkNow() {
        guard checkTask == nil, installTask == nil else { return }
        lastCheck = Date(); statusKey = "Checking for Plugin Updates…"
        let items = useCase.state().items
        let generation = UUID(); checkGeneration = generation
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let found = try await self.check(items)
                guard self.checkGeneration == generation, !Task.isCancelled else { return }
                self.updates = found
                self.statusKey = self.updates.isEmpty ? "No Plugin Updates Available" : "Plugin Updates Available"
            } catch {
                guard self.checkGeneration == generation, !Task.isCancelled else { return }
                self.statusKey = "Could Not Check for Plugin Updates"
            }
            self.checkTask = nil; self.render()
        }
        render()
    }

    private func update(_ item: ExtensionRegistryItem, release: ExtensionUpdate) {
        guard installTask == nil else { return }
        checkTask?.cancel(); checkTask = nil
        checkGeneration = UUID()
        statusKey = "Downloading and Verifying Plugin…"
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = item.enabled ? try self.useCase.consentReviewToken(for: item.manifest.id) : nil
                let prepared = try await self.prepare(release, item.publisherFingerprint)
                try Task.checkCancellation()
                if let token {
                    let choices = Set(prepared.package.manifest.capabilities)
                    try await self.useCase.approveUpdate(from: token, to: prepared.package, choices: choices)
                } else {
                    guard self.useCase.state().items.contains(where: { $0.packageDigest == item.packageDigest && !$0.enabled }) else { throw ExtensionFailure.staleContext }
                }
                self.statusKey = "Installing Plugin…"; self.render()
                try await self.install(prepared)
                self.updates.removeValue(forKey: item.manifest.id)
                await self.useCase.refresh()
                self.statusKey = self.useCase.state().items.contains(where: { $0.manifest.id == item.manifest.id && $0.pendingVersion != nil }) ? "Plugin Update Will Apply Next Launch" : "Plugin Update Installed"
            } catch is CancellationError { self.statusKey = "Plugin Update Cancelled" }
            catch { self.statusKey = "Plugin Update Failed"; self.onError(error) }
            self.installTask = nil; self.render()
        }
        render()
    }
}
